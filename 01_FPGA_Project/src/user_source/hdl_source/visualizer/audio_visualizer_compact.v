// Pixel-clock-domain passive monitor. No connection can stall the player.
module audio_visualizer_compact #(
    parameter USE_BAND_READ=0
)(
    input wire clk,rst_n,clear,running,frame_start,sample_valid,
    input wire clk_display,
    input wire [3:0] display_state_pix,
    output wire [3:0] display_state_calc,
    input wire signed [15:0] sample_l,sample_r,
    input wire [11:0] phase_address,input wire phase_read_enable,
    output wire phase_dot,
    input wire bar_read,input wire [4:0] bar_address,
    output wire [7:0] bar_height,bar_peak,
    output wire [7:0] bar_height_next,bar_peak_next,
    output reg [7:0] level_l,level_r,peak_l,peak_r,
    output reg clip_l,clip_r,
    output reg signed [1:0] phase_trend,
    output wire fft_busy,output wire [31:0] skipped_samples
);
    wire fft_valid;wire [511:0] fft_bands;
    wire [15:0] fft_band_q;
    // Declare before the generate scope: otherwise Verilog creates implicit
    // one-bit wires for the synchronous RAM address and conversion controls.
    reg converting,convert_phase,latest_bank,latest_ready,display_bank,pending_ready,initialized;
    reg [4:0] convert_index,bar_index;
    generate if(USE_BAND_READ) begin: scalar_fft
        audio_fft512_ram fft(.clk(clk),.rst_n(rst_n),.clear(clear),
            .sample_valid(sample_valid&&running),.sample_l(sample_l),.sample_r(sample_r),
            .result_valid(fft_valid),.busy(fft_busy),.skipped_samples(skipped_samples),
            .band_read_enable(converting&&!convert_phase),.band_read_address(convert_index),
            .band_read_data(fft_band_q));
        assign fft_bands=512'd0;
    end else begin: legacy_fft
        audio_fft512 fft(clk,rst_n,clear,sample_valid&&running,sample_l,sample_r,
            fft_valid,fft_bands,fft_busy,skipped_samples);
        assign fft_band_q=16'd0;
    end endgenerate
    // logarithmic() is monotonic: log(max(a,b))=max(log(a),log(b)).
    // Keep exactly the value consumed by the next frame instead of retaining
    // two 16-bit magnitudes and re-encoding them combinationally each frame.
    reg [7:0] pending_l,pending_r;
    reg pending_clip_l,pending_clip_r;
    reg [4:0] clip_hold_l,clip_hold_r;
    reg [4:0] hold_l,hold_r;
    function [15:0] abs16;
        input signed [15:0] v;
        begin abs16=v[15] ? (~v+16'd1) : v;end
    endfunction
    // Approximate logarithmic scale: 0..192 represents about -72..0 dBFS.
    // Spectrum magnitudes get x4 compensation for Hann / real one-sided FFT.
    function [7:0] logarithmic;
        input [17:0] value;
        begin
            // Exact original mapping, without an 18-bit variable shifter.
            if(|value[17:15]) logarithmic=8'd192;
            else if(value[14]) logarithmic={4'hb,value[13:10]};
            else if(value[13]) logarithmic={4'ha,value[12:9]};
            else if(value[12]) logarithmic={4'h9,value[11:8]};
            else if(value[11]) logarithmic={4'h8,value[10:7]};
            else if(value[10]) logarithmic={4'h7,value[9:6]};
            else if(value[9]) logarithmic={4'h6,value[8:5]};
            else if(value[8]) logarithmic={4'h5,value[7:4]};
            else if(value[7]) logarithmic={4'h4,value[6:3]};
            else if(value[6]) logarithmic={4'h3,value[5:2]};
            else if(value[5]) logarithmic={4'h2,value[4:1]};
            else if(value[4]) logarithmic={4'h1,value[3:0]};
            else if(value[3]) logarithmic={4'd0,value[2:0],1'b0};
            else logarithmic=8'd0;
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
    // Exact integer stereo identities; reuse the meter magnitudes:
    // |L+R|+|L-R| = 2*max(|L|,|R|), and their difference is
    // +/-2*min(|L|,|R|), positive for equal sample signs.
    wire left_larger=al>ar;
    wire [15:0] phase_min=left_larger ? ar:al;
    wire [15:0] phase_max=left_larger ? al:ar;
    wire signed [16:0] phase_delta_half=sample_l[15]^sample_r[15] ?
        -$signed({1'b0,phase_min}):$signed({1'b0,phase_min});
    wire signed [18:0] phase_delta={phase_delta_half[16],phase_delta_half,1'b0};
    // At most 4095 samples are accumulated. Half-energy is <=4095*32768
    // and fits 27 unsigned bits; half-delta fits 28 signed bits. The
    // original values are always even, so these storage widths lose no bit.
    reg signed [27:0] phase_accum_half;
    reg [26:0] phase_energy_half;
    wire signed [28:0] phase_accum={phase_accum_half,1'b0};
    wire [28:0] phase_energy={1'b0,phase_energy_half,1'b0};
    // Original comparison is 2*A against floor(2*E/16). For integer A,
    // both signed thresholds are exactly +/-floor(E/16). Complementing a
    // negative A produces |A|-1, so that branch includes equality; the
    // positive branch uses >. One unsigned comparison serves both signs.
    wire [26:0] phase_metric=phase_accum_half[26:0]^{27{phase_accum_half[27]}};
    wire [22:0] phase_threshold=phase_energy_half[26:4];
    wire phase_strong=phase_metric>phase_threshold||
        (phase_accum_half[27]&&phase_metric==phase_threshold);
    // A/E is a qualitative signed stereo-agreement measure, not Pearson correlation.
    // Negative beyond E/16 warns amber; beyond E/2 is strong opposition (red).
    // For negative A the complemented metric is abs(A)-1, so >= floor(E/2)
    // exactly implements A < -floor(E/2), including odd-energy boundaries.
    wire phase_out_strong=phase_accum_half[27]&&phase_metric>={1'b0,phase_energy_half[26:1]};
    reg [11:0] phase_count;
    wire [7:0] nl=pending_l,nr=pending_r;
    wire [7:0] sample_log_l=logarithmic({2'b0,al}),sample_log_r=logarithmic({2'b0,ar});
    // targets A/B [0..63], display A/B [64..127], hold counters [128..159].
    // Display reads have priority; all computation pauses between RAM grants.
    // One packed display word returns two adjacent bands in one pixel read.
    // The lower half remains the original height/peak; the upper half is its
    // right neighbor (last band repeats itself). Only the invisible bank is
    // written, including neighbor updates, before pending_ready permits swap.
    reg [3:0] bar_state;
    reg read_bank,write_bank,target_bank,target_ready,old_valid;
    reg [15:0] old_word;
    reg [15:0] previous_display_word;
    reg [4:0] old_hold;
    reg [7:0] target_value;
    reg [7:0] ram_address;
    reg [31:0] ram_data;
    reg ram_enable,ram_write;
    wire [15:0] ram_q,display_current_q,display_neighbor_q;
    wire [31:0] display_ram_q={display_neighbor_q,display_current_q};
    reg display_read_q;
    wire [7:0] height_next=release_value(old_word[15:8],target_value);
    wire [7:0] peak_next=target_value>=old_word[7:0] ? target_value:
        old_hold!=0 ? old_word[7:0]:old_word[7:0]>1 ? old_word[7:0]-8'd1:8'd0;
    wire [7:0] hold_next=target_value>=old_word[7:0] ? 8'd18:old_hold!=0 ? old_hold-8'd1:8'd0;
    wire engine_grant=!converting;
    always @* begin
        ram_address=0;ram_data=0;ram_enable=0;ram_write=0;
        if(converting) begin
            ram_address={2'b00,!latest_bank,convert_index};
            ram_enable=!USE_BAND_READ||convert_phase;ram_write=ram_enable;
            ram_data={8'd0,logarithmic({USE_BAND_READ ? fft_band_q:fft_bands[convert_index*16+:16],2'b0})};
        end else case(bar_state)
            1:begin ram_enable=1;ram_address={2'b01,read_bank,bar_index};end
            3:begin ram_enable=1;ram_address={3'b100,bar_index};end
            5:begin ram_enable=1;ram_address={2'b00,target_bank,bar_index};end
            7:begin
                ram_enable=1;ram_write=1;ram_address={2'b01,write_bank,bar_index};
                ram_data={bar_index==31 ? {height_next,peak_next}:16'd0,height_next,peak_next};
            end
            8:begin ram_enable=1;ram_write=1;ram_address={3'b100,bar_index};ram_data={8'd0,hold_next};end
            9:if(bar_index!=0) begin
                ram_enable=1;ram_write=1;ram_address={2'b01,write_bank,bar_index-5'd1};
                ram_data={height_next,peak_next,previous_display_word};
            end
            default:begin end
        endcase
    end
    // Current values, targets and hold counters need a true read/write port.
    // Adjacent display values need only a sys write and pix read. Splitting
    // these halves retains the same pixel read latency with fewer RAM blocks.
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(8),.DATA_DEPTH_A(256),
        .DATA_WIDTH_B(16),.ADDR_WIDTH_B(8),.DATA_DEPTH_B(256),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),
        .IMPLEMENT("32K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) bar_ram(
        .dia(ram_data[15:0]),.dib(16'd0),.addra(ram_address),.addrb({2'b01,display_state_pix[2],bar_address}),
        .cea(ram_enable&&rst_n&&!clear),.ceb(bar_read),.ocea(1'b0),.oceb(1'b0),
        .clka(clk),.clkb(clk_display),.wea(ram_write),.web(1'b0),.bea(1'b0),.beb(1'b0),
        .rsta(1'b0),.rstb(1'b0),.doa(ram_q),.dob(display_current_q));
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(6),.DATA_DEPTH_A(64),
        .DATA_WIDTH_B(16),.ADDR_WIDTH_B(6),.DATA_DEPTH_B(64),.MODE("PDPW"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),
        .IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) neighbor_ram(
        .dia(ram_data[31:16]),.dib(16'd0),.addra(ram_address[5:0]),.addrb({display_state_pix[2],bar_address}),
        .cea(ram_enable&&ram_write&&ram_address[7:6]==2'b01&&rst_n&&!clear),.ceb(bar_read),
        .ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(clk_display),.wea(1'b1),.web(1'b0),
        .bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(display_neighbor_q));
    assign bar_height=display_read_q&&display_state_pix[3] ? display_ram_q[15:8]:8'd0;
    assign bar_peak=display_read_q&&display_state_pix[3] ? display_ram_q[7:0]:8'd0;
    assign bar_height_next=display_read_q&&display_state_pix[3] ? display_ram_q[31:24]:8'd0;
    assign bar_peak_next=display_read_q&&display_state_pix[3] ? display_ram_q[23:16]:8'd0;
    always @(posedge clk_display) display_read_q<=bar_read;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            converting<=0;convert_phase<=0;latest_bank<=0;latest_ready<=0;display_bank<=0;pending_ready<=0;initialized<=0;
            convert_index<=0;bar_index<=0;bar_state<=0;read_bank<=0;write_bank<=1;target_bank<=0;
            target_ready<=0;old_valid<=0;old_word<=0;old_hold<=0;target_value<=0;previous_display_word<=0;
        end else if(clear) begin
            converting<=0;convert_phase<=0;latest_bank<=0;latest_ready<=0;display_bank<=0;pending_ready<=0;initialized<=0;
            convert_index<=0;bar_index<=0;bar_state<=0;read_bank<=0;write_bank<=1;target_bank<=0;
            target_ready<=0;old_valid<=0;old_word<=0;old_hold<=0;target_value<=0;previous_display_word<=0;
        end else begin
            if(fft_valid) begin converting<=1;convert_index<=0;convert_phase<=0;end
            else if(converting) begin
                if(USE_BAND_READ&&!convert_phase) convert_phase<=1;
                else begin
                    convert_phase<=0;
                    if(convert_index==31) begin converting<=0;latest_bank<=!latest_bank;latest_ready<=1;end
                    else convert_index<=convert_index+1'b1;
                end
            end
            case(bar_state)
                1:if(engine_grant) bar_state<=2;
                2:begin old_word<=old_valid ? ram_q[15:0]:16'd0;bar_state<=3;end
                3:if(engine_grant) bar_state<=4;
                4:begin old_hold<=old_valid ? ram_q[4:0]:5'd0;bar_state<=5;end
                5:if(engine_grant) bar_state<=6;
                6:begin target_value<=target_ready ? ram_q[7:0]:8'd0;bar_state<=7;end
                7:if(engine_grant) bar_state<=8;
                8:if(engine_grant) bar_state<=9;
                9:if(engine_grant) begin
                    previous_display_word<={height_next,peak_next};
                    if(bar_index==31) begin bar_state<=0;pending_ready<=1;end
                    else begin bar_index<=bar_index+1'b1;bar_state<=1;end
                end
                default:begin end
            endcase
            if(frame_start&&running) begin
                if(pending_ready) begin display_bank<=!display_bank;initialized<=1;pending_ready<=0;end
                if(bar_state==0) begin
                    read_bank<=pending_ready ? !display_bank:display_bank;
                    write_bank<=pending_ready ? display_bank:!display_bank;
                    target_bank<=latest_bank;target_ready<=latest_ready;old_valid<=initialized||pending_ready;
                    bar_index<=0;bar_state<=1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pending_l<=0;pending_r<=0;
            level_l<=0;level_r<=0;peak_l<=0;peak_r<=0;
            clip_l<=0;clip_r<=0;pending_clip_l<=0;pending_clip_r<=0;
            clip_hold_l<=0;clip_hold_r<=0;hold_l<=0;hold_r<=0;
            phase_trend<=0;phase_accum_half<=0;phase_energy_half<=0;phase_count<=0;
        end else if(clear) begin
            pending_l<=0;pending_r<=0;
            level_l<=0;level_r<=0;peak_l<=0;peak_r<=0;
            clip_l<=0;clip_r<=0;pending_clip_l<=0;pending_clip_r<=0;
            clip_hold_l<=0;clip_hold_r<=0;hold_l<=0;hold_r<=0;
            phase_trend<=0;phase_accum_half<=0;phase_energy_half<=0;phase_count<=0;
        end else begin
            if(sample_valid&&running) begin
                if(phase_count!=4095) begin
                    phase_accum_half<=phase_accum_half+phase_delta_half;
                    phase_energy_half<=phase_energy_half+phase_max;
                    phase_count<=phase_count+1;
                end
                if(sample_log_l>pending_l) pending_l<=sample_log_l;
                if(sample_log_r>pending_r) pending_r<=sample_log_r;
                if(al>=32760) pending_clip_l<=1;
                if(ar>=32760) pending_clip_r<=1;
            end
            if(frame_start&&running) begin
                // Qualitative agreement indicator, not a calibrated numeric
                // correlation coefficient. Silence/one-sided audio is neutral.
                if(phase_energy_half<512||!phase_strong) phase_trend<=0;
                else phase_trend<=phase_accum_half[27] ? (phase_out_strong ? 2'sb10:-2'sd1):2'sd1;
                phase_accum_half<=sample_valid ? phase_delta_half : 0;
                phase_energy_half<=sample_valid ? phase_max : 0;
                phase_count<=sample_valid ? 1 : 0;
                level_l<=release_value(level_l,nl);level_r<=release_value(level_r,nr);
                pending_l<=sample_valid ? sample_log_l : 0;pending_r<=sample_valid ? sample_log_r : 0;
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
    reg [11:0] clear_index;
    reg [1:0] phase_state;
    reg phase_ready;
    wire [5:0] px=6'd32+(difference >>> 11);
    // Positive mono points upwards. Quantization maps +32767 to top row.
    wire [5:0] py=6'd31-(sum >>> 11);
    wire [11:0] point_address={py,px};
    always @(posedge clk_display) if(phase_read_enable) begin
        phase_q0<=dots0[phase_address];phase_q1<=dots1[phase_address];
    end
    assign display_state_calc={initialized,display_bank,phase_ready,front_bank};
    assign phase_dot=display_state_pix[1]&&(display_state_pix[0] ? phase_q1[0] : phase_q0[0]);
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
