// Pixel-clock-domain passive monitor. No connection can stall the player.
module audio_visualizer(
    input wire clk,rst_n,clear,running,frame_start,sample_valid,
    input wire signed [15:0] sample_l,sample_r,
    input wire [11:0] phase_address,input wire phase_read_enable,
    output wire phase_dot,
    output reg [255:0] bar_heights,bar_peaks,
    output reg [7:0] level_l,level_r,peak_l,peak_r,
    output reg clip_l,clip_r,
    output reg signed [1:0] phase_trend,
    output wire fft_busy,output wire [31:0] skipped_samples
);
    wire fft_valid;wire [511:0] fft_bands;
    audio_fft512 fft(clk,rst_n,clear,sample_valid&&running,sample_l,sample_r,
        fft_valid,fft_bands,fft_busy,skipped_samples);
    reg [255:0] latest_heights,converted_heights;
    reg converting;reg [4:0] convert_index;
    reg [15:0] pending_l,pending_r;
    reg pending_clip_l,pending_clip_r;
    reg [5:0] clip_hold_l,clip_hold_r;
    reg [5:0] hold_l,hold_r;
    // One time-shared peak/release unit instead of 32 parallel subtractors.
    reg [23:0] bar_state_ram[0:31];
    reg [23:0] bar_word_q;
    reg [255:0] pending_bars,pending_peaks,target_heights;
    reg pending_ready,bar_initialized;
    reg [1:0] bar_state;
    reg [4:0] bar_index;
    function [15:0] abs16;
        input signed [15:0] v;
        begin abs16=v[15] ? (~v+16'd1) : v;end
    endfunction
    // Approximate logarithmic scale: 0..192 represents about -72..0 dBFS.
    // Spectrum magnitudes get x4 compensation for Hann / real one-sided FFT.
    function [7:0] logarithmic;
        input [17:0] value;
        integer bitnum,highest;
        reg [17:0] shifted;
        integer scaled;
        begin
            highest=0;
            for(bitnum=0;bitnum<18;bitnum=bitnum+1)
                if(value[bitnum]) highest=bitnum;
            shifted=(highest>=4) ? (value >> (highest-4)) : (value << (4-highest));
            scaled=(highest-3)*16+shifted[3:0];
            if(value==0 || scaled<0) logarithmic=0;
            else if(scaled>192) logarithmic=192;
            else logarithmic=scaled;
        end
    endfunction
    function [7:0] release_value;
        input [7:0] old_value,new_value;
        begin
            if(new_value>old_value) release_value=new_value;
            else release_value=old_value>2 ? old_value-2 : 0;
        end
    endfunction
    wire [15:0] al=abs16(sample_l),ar=abs16(sample_r);
    wire signed [16:0] difference=$signed(sample_l)-$signed(sample_r);
    wire signed [16:0] sum=$signed(sample_l)+$signed(sample_r);
    wire [16:0] abs_sum=sum[16] ? (~sum+17'd1) : sum;
    wire [16:0] abs_difference=difference[16] ? (~difference+17'd1) : difference;
    wire signed [18:0] phase_delta=$signed({1'b0,abs_sum})-$signed({1'b0,abs_difference});
    reg signed [28:0] phase_accum;
    reg [28:0] phase_energy;
    reg [11:0] phase_count;
    wire [7:0] nl=logarithmic({2'b0,pending_l}),nr=logarithmic({2'b0,pending_r});
    wire [23:0] old_bar_word=bar_initialized ? bar_word_q : 24'd0;
    wire [7:0] incoming_height=target_heights[bar_index*8+:8];
    wire [7:0] next_bar_height=release_value(old_bar_word[23:16],incoming_height);
    wire [7:0] next_bar_peak=incoming_height>=old_bar_word[15:8] ? incoming_height :
        old_bar_word[7:0]!=0 ? old_bar_word[15:8] : old_bar_word[15:8]>1 ? old_bar_word[15:8]-8'd1 : 8'd0;
    wire [7:0] next_bar_hold=incoming_height>=old_bar_word[15:8] ? 8'd18 :
        old_bar_word[7:0]!=0 ? old_bar_word[7:0]-8'd1 : 8'd0;
    always @(posedge clk) begin
        if(bar_state==1) bar_word_q<=bar_state_ram[bar_index];
        if(rst_n&&!clear&&bar_state==2)
            bar_state_ram[bar_index]<={next_bar_height,next_bar_peak,next_bar_hold};
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            latest_heights<=0;converted_heights<=0;converting<=0;convert_index<=0;pending_l<=0;pending_r<=0;
            level_l<=0;level_r<=0;peak_l<=0;peak_r<=0;
            clip_l<=0;clip_r<=0;pending_clip_l<=0;pending_clip_r<=0;
            clip_hold_l<=0;clip_hold_r<=0;hold_l<=0;hold_r<=0;
            bar_heights<=0;bar_peaks<=0;pending_bars<=0;pending_peaks<=0;target_heights<=0;
            pending_ready<=0;bar_initialized<=0;bar_state<=0;bar_index<=0;
            phase_trend<=0;phase_accum<=0;phase_energy<=0;phase_count<=0;
        end else if(clear) begin
            latest_heights<=0;converted_heights<=0;converting<=0;convert_index<=0;pending_l<=0;pending_r<=0;
            level_l<=0;level_r<=0;peak_l<=0;peak_r<=0;
            clip_l<=0;clip_r<=0;pending_clip_l<=0;pending_clip_r<=0;
            clip_hold_l<=0;clip_hold_r<=0;hold_l<=0;hold_r<=0;
            bar_heights<=0;bar_peaks<=0;pending_bars<=0;pending_peaks<=0;target_heights<=0;
            pending_ready<=0;bar_initialized<=0;bar_state<=0;bar_index<=0;
            phase_trend<=0;phase_accum<=0;phase_energy<=0;phase_count<=0;
        end else begin
            if(bar_state==1) bar_state<=2;
            else if(bar_state==2) begin
                pending_bars[bar_index*8+:8]<=next_bar_height;
                pending_peaks[bar_index*8+:8]<=next_bar_peak;
                if(bar_index==31) begin bar_state<=0;pending_ready<=1;bar_initialized<=1;end
                else begin bar_index<=bar_index+1;bar_state<=1;end
            end
            if(fft_valid) begin converting<=1;convert_index<=0;end
            else if(converting) begin
                converted_heights[convert_index*8+:8]<=logarithmic({fft_bands[convert_index*16+:16],2'b0});
                if(convert_index==31) begin
                    latest_heights<={logarithmic({fft_bands[31*16+:16],2'b0}),converted_heights[247:0]};
                    converting<=0;
                end else convert_index<=convert_index+1;
            end
            if(sample_valid&&running) begin
                if(phase_count!=4095) begin
                    phase_accum<=phase_accum+phase_delta;
                    phase_energy<=phase_energy+abs_sum+abs_difference;
                    phase_count<=phase_count+1;
                end
                if(al>pending_l) pending_l<=al;
                if(ar>pending_r) pending_r<=ar;
                if(al>=32760) pending_clip_l<=1;
                if(ar>=32760) pending_clip_r<=1;
            end
            if(frame_start&&running) begin
                // Qualitative agreement indicator, not a calibrated numeric
                // correlation coefficient. Silence/one-sided audio is neutral.
                if(phase_energy<1024) phase_trend<=0;
                else if(phase_accum>$signed({1'b0,phase_energy[28:4]})) phase_trend<=1;
                else if(phase_accum< -$signed({1'b0,phase_energy[28:4]})) phase_trend<=-1;
                else phase_trend<=0;
                phase_accum<=sample_valid ? phase_delta : 0;
                phase_energy<=sample_valid ? abs_sum+abs_difference : 0;
                phase_count<=sample_valid ? 1 : 0;
                level_l<=release_value(level_l,nl);level_r<=release_value(level_r,nr);
                pending_l<=sample_valid ? al : 0;pending_r<=sample_valid ? ar : 0;
                pending_clip_l<=sample_valid&&(al>=32760);
                pending_clip_r<=sample_valid&&(ar>=32760);
                if(pending_clip_l) clip_hold_l<=30;
                else if(clip_hold_l!=0) clip_hold_l<=clip_hold_l-1;
                if(pending_clip_r) clip_hold_r<=30;
                else if(clip_hold_r!=0) clip_hold_r<=clip_hold_r-1;
                clip_l<=pending_clip_l || clip_hold_l!=0;clip_r<=pending_clip_r || clip_hold_r!=0;
                if(nl>=peak_l) begin peak_l<=nl;hold_l<=30;end
                else if(hold_l!=0) hold_l<=hold_l-1;
                else peak_l<=peak_l>1 ? peak_l-1 : 0;
                if(nr>=peak_r) begin peak_r<=nr;hold_r<=30;end
                else if(hold_r!=0) hold_r<=hold_r-1;
                else peak_r<=peak_r>1 ? peak_r-1 : 0;
                if(pending_ready) begin
                    bar_heights<=pending_bars;bar_peaks<=pending_peaks;pending_ready<=0;
                end
                if(bar_state==0) begin
                    target_heights<=latest_heights;bar_index<=0;bar_state<=1;
                end
            end
        end
    end
    // Compact double-buffered 64x64 goniometer. Each frame displays the
    // preceding frame's points; only the invisible bank is cleared/written.
    // EG4 9K true dual port supports 4096x2, not dual-port 8192x1.
    // Two independent 2-bit banks avoid LUT RAM and read/modify/write.
    reg [1:0] dots0[0:4095]; /* fehdl force_ram=1, ram_style="bram" */
    reg [1:0] dots1[0:4095]; /* fehdl force_ram=1, ram_style="bram" */
    reg [1:0] phase_q0,phase_q1;
    reg front_bank;
    reg [13:0] clear_index;
    reg [1:0] phase_state;
    reg phase_ready;
    wire [5:0] px=6'd32+(difference >>> 11);
    // Positive mono points upwards. Quantization maps +32767 to top row.
    wire [5:0] py=6'd31-(sum >>> 11);
    wire [11:0] point_address={py,px};
    always @(posedge clk) if(phase_read_enable) begin
        phase_q0<=dots0[phase_address];phase_q1<=dots1[phase_address];
    end
    assign phase_dot=phase_ready&&(front_bank ? phase_q1[0] : phase_q0[0]);
    always @(posedge clk) if(rst_n&&!clear) begin
        if(phase_state==0) begin dots0[clear_index[11:0]]<=0;dots1[clear_index[11:0]]<=0;end
        else if(phase_state==1) begin
            if(front_bank) dots0[clear_index[11:0]]<=0;
            else dots1[clear_index[11:0]]<=0;
        end else if(phase_state==2&&sample_valid&&running&&!frame_start) begin
            if(front_bank) dots0[point_address]<=1;
            else dots1[point_address]<=1;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin front_bank<=0;clear_index<=0;phase_state<=0;phase_ready<=0;end
        else if(clear) begin front_bank<=0;clear_index<=0;phase_state<=0;phase_ready<=0;end
        else case(phase_state)
            0:begin
                if(clear_index==4095) begin phase_state<=2;phase_ready<=1;end
                else clear_index<=clear_index+1;
            end
            1:begin
                if(clear_index==4095) phase_state<=2;
                else clear_index<=clear_index+1;
            end
            2:if(frame_start&&running) begin
                front_bank<=!front_bank;clear_index<=0;phase_state<=1;
            end
            default:phase_state<=0;
        endcase
    end
endmodule
