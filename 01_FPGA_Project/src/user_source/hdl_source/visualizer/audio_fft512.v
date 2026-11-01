// 512-point Hann-windowed DIT FFT. One shared signed multiplier.
// Natural input is copied to bit-reversed addresses; natural output bins.
// Both channels are processed independently. Spectrum uses max(|Re|+|Im|)
// across channels and bins in each band, so antiphase audio remains visible.
module audio_fft512(
    input wire clk, rst_n, clear, sample_valid,
    input wire signed [15:0] sample_l, sample_r,
    output reg result_valid,
    output reg [511:0] band_magnitude,
    output wire busy, output reg [31:0] skipped_samples
);
    reg [31:0] samples[0:511];
    reg signed [15:0] re_mem[0:511], im_mem[0:511];
    reg [31:0] twiddle[0:255];
    reg [15:0] window_rom[0:511];
    reg [7:0] band_rom[0:255];
    initial begin
        $readmemh("fft_twiddle.hex",twiddle);
        $readmemh("fft_window.hex",window_rom);
        $readmemh("fft_band.hex",band_rom);
    end
    localparam CAPTURE=0, LOAD_READ=1, LOAD_START=2, LOAD_WAIT=3,
        LOAD_WRITE=4, READ_A=5, READ_B=6, GET_B=7,
        MUL_START=8, MUL_WAIT=9, MUL_SAVE=10, ROTATE=11,
        WRITE_A=12, WRITE_B=13, BIN_READ=14, BIN_SAVE=15,
        PUBLISH=16;
    reg [4:0] state;
    reg [8:0] index, a_addr, b_addr, j;
    reg [9:0] base;
    reg [3:0] stage;
    wire [9:0] half_size=10'd1 << (stage-1);
    wire [9:0] full_size=10'd1 << stage;
    reg channel;
    reg [31:0] sample_q, twiddle_q;
    reg [15:0] window_q;
    reg signed [15:0] ar, ai, br, bi;
    reg signed [15:0] re_q,im_q;
    wire [8:0] read_address=(state==READ_A) ? a_addr : (state==READ_B) ? b_addr : index;
    reg signed [17:0] mult_a, mult_b;
    reg signed [35:0] product, p0, p1, p2;
    reg signed [18:0] tr, ti;
    reg [1:0] multiply;
    reg [4:0] bin_band;
    reg [15:0] bands[0:31];
    integer k;
    assign busy=state!=CAPTURE;
    function [8:0] reverse9;
        input [8:0] v;
        integer n;
        begin for(n=0;n<9;n=n+1) reverse9[n]=v[8-n]; end
    endfunction
    function [15:0] absolute16;
        input signed [15:0] v;
        begin absolute16=v[15] ? (~v+16'd1) : v; end
    endfunction
    function signed [15:0] clamp;
        input signed [19:0] v;
        begin
            if(v>32767) clamp=32767;
            else if(v< -32768) clamp=-32768;
            else clamp=v[15:0];
        end
    endfunction
    wire [16:0] magnitude={1'b0,absolute16(re_q)}+{1'b0,absolute16(im_q)};
    always @(posedge clk) product<=mult_a*mult_b;
    // RAM ports deliberately have no asynchronous reset. Clear invalidates
    // control state, then the next capture/transform overwrites every word.
    always @(posedge clk) begin
        if(rst_n&&!clear&&state==CAPTURE&&sample_valid) samples[index]<={sample_l,sample_r};
        if(state==LOAD_READ) begin sample_q<=samples[index];window_q<=window_rom[index];end
        if(state==READ_A) twiddle_q<=twiddle[j << (9-stage)];
        if(state==READ_A||state==READ_B||state==BIN_READ) begin
            re_q<=re_mem[read_address];im_q<=im_mem[read_address];
        end
        if(rst_n&&!clear) begin
            if(state==LOAD_WRITE) begin
                re_mem[reverse9(index)]<=product >>> 15;im_mem[reverse9(index)]<=0;
            end else if(state==WRITE_A) begin
                re_mem[a_addr]<=clamp(($signed(ar)+$signed(tr)) >>> 1);
                im_mem[a_addr]<=clamp(($signed(ai)+$signed(ti)) >>> 1);
            end else if(state==WRITE_B) begin
                re_mem[b_addr]<=clamp(($signed(ar)-$signed(tr)) >>> 1);
                im_mem[b_addr]<=clamp(($signed(ai)-$signed(ti)) >>> 1);
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=CAPTURE; index<=0; result_valid<=0;
            band_magnitude<=0; skipped_samples<=0; channel<=0;
            stage<=1; base<=0; j<=0; a_addr<=0; b_addr<=1;
            mult_a<=0;mult_b<=0;multiply<=0;
            for(k=0;k<32;k=k+1) bands[k]<=0;
        end else if(clear) begin
            state<=CAPTURE;index<=0;result_valid<=0;band_magnitude<=0;
            skipped_samples<=0;channel<=0;
            for(k=0;k<32;k=k+1) bands[k]<=0;
        end else begin
            result_valid<=0;
            if(sample_valid && busy) skipped_samples<=skipped_samples+1;
            case(state)
            CAPTURE: if(sample_valid) begin
                if(index==511) begin
                    index<=0;channel<=0;state<=LOAD_READ;
                    for(k=0;k<32;k=k+1) bands[k]<=0;
                end else index<=index+1;
            end
            LOAD_READ: begin
                state<=LOAD_START;
            end
            LOAD_START: begin
                mult_a<=channel ? $signed(sample_q[15:0]) : $signed(sample_q[31:16]);
                mult_b<=$signed({1'b0,window_q});state<=LOAD_WAIT;
            end
            LOAD_WAIT: state<=LOAD_WRITE;
            LOAD_WRITE: begin
                if(index==511) begin
                    stage<=1;base<=0;j<=0;a_addr<=0;b_addr<=1;state<=READ_A;
                end else begin index<=index+1;state<=LOAD_READ;end
            end
            READ_A: begin
                state<=READ_B;
            end
            READ_B: begin ar<=re_q;ai<=im_q;state<=GET_B;end
            GET_B: begin br<=re_q;bi<=im_q;multiply<=0;state<=MUL_START;end
            MUL_START: begin
                case(multiply)
                0: begin mult_a<=br;mult_b<=$signed(twiddle_q[31:16]);end
                1: begin mult_a<=bi;mult_b<=$signed(twiddle_q[15:0]);end
                2: begin mult_a<=br;mult_b<=$signed(twiddle_q[15:0]);end
                3: begin mult_a<=bi;mult_b<=$signed(twiddle_q[31:16]);end
                endcase
                state<=MUL_WAIT;
            end
            MUL_WAIT: state<=MUL_SAVE;
            MUL_SAVE: begin
                case(multiply)
                0:p0<=product;
                1:p1<=product;
                2:p2<=product;
                3:ti<=($signed({p2[35],p2})+$signed({product[35],product})) >>> 15;
                endcase
                if(multiply==3) state<=ROTATE;
                else begin multiply<=multiply+1;state<=MUL_START;end
            end
            ROTATE: begin tr<=($signed({p0[35],p0})-$signed({p1[35],p1})) >>> 15;state<=WRITE_A;end
            WRITE_A: begin
                state<=WRITE_B;
            end
            WRITE_B: begin
                if(j+1<half_size) begin
                    j<=j+1;a_addr<=a_addr+1;b_addr<=b_addr+1;state<=READ_A;
                end else if(base+full_size<512) begin
                    base<=base+full_size;j<=0;
                    a_addr<=base+full_size;b_addr<=base+full_size+half_size;state<=READ_A;
                end else if(stage<9) begin
                    stage<=stage+1;base<=0;j<=0;a_addr<=0;b_addr<=full_size;state<=READ_A;
                end else begin index<=1;state<=BIN_READ;end
            end
            BIN_READ: begin
                bin_band<=band_rom[index][4:0];state<=BIN_SAVE;
            end
            BIN_SAVE: begin
                if(magnitude>bands[bin_band]) bands[bin_band]<=magnitude[16] ? 16'hffff : magnitude[15:0];
                if(index==255) begin
                    if(!channel) begin channel<=1;index<=0;state<=LOAD_READ;end
                    else state<=PUBLISH;
                end else begin index<=index+1;state<=BIN_READ;end
            end
            PUBLISH: begin
                for(k=0;k<32;k=k+1) band_magnitude[k*16+:16]<=bands[k];
                result_valid<=1;state<=CAPTURE;index<=0;
            end
            default:state<=CAPTURE;
            endcase
        end
    end
endmodule

// Scalar-band production variant. Original audio_fft512 above remains
// unchanged for positional callers and numerical/cycle reference tests.
// band_read_data is one synchronous read stage without added output gating.
// Its values are valid only after result_valid and before the next transform;
// reset/clear invalidate the bank until the next completed result.
// 512-point Hann-windowed DIT FFT. One shared signed multiplier.
// Natural input is copied to bit-reversed addresses; natural output bins.
// Both channels are processed independently. Spectrum uses max(|Re|+|Im|)
// across channels and bins in each band, so antiphase audio remains visible.
module audio_fft512_ram(
    input wire clk, rst_n, clear, sample_valid,
    input wire signed [15:0] sample_l, sample_r,
    output reg result_valid,
    output wire busy, output reg [31:0] skipped_samples,
    input wire band_read_enable,
    input wire [4:0] band_read_address,
    output wire [15:0] band_read_data
);
    reg [31:0] samples[0:511];
    reg signed [15:0] re_mem[0:511], im_mem[0:511];
    reg [15:0] window_rom[0:511];
    reg [7:0] band_rom[0:255];
    initial begin
        $readmemh("fft_window.hex",window_rom);
        $readmemh("fft_band.hex",band_rom);
    end
    localparam CAPTURE=0, LOAD_READ=1, LOAD_START=2, LOAD_WAIT=3,
        LOAD_WRITE=4, READ_A=5, READ_B=6, GET_B=7,
        MUL_START=8, MUL_WAIT=9, MUL_SAVE=10, ROTATE=11,
        WRITE_A=12, WRITE_B=13, BIN_READ=14, BIN_SAVE=15,
        PUBLISH=16;
    reg [4:0] state;
    reg [8:0] index, a_addr, b_addr, j;
    reg [9:0] base;
    reg [3:0] stage;
    // Within a butterfly group the twiddle address advances by
    // 2^(9-stage). Keep that stride and address as simple fixed shifts /
    // increments instead of a variable barrel shifter on the ROM address.
    reg [8:0] twiddle_step;
    reg [7:0] twiddle_address;
    wire [9:0] half_size=10'd1 << (stage-1);
    wire [9:0] full_size={half_size[8:0],1'b0};
    reg channel;
    reg [31:0] sample_q, twiddle_q;
    reg [15:0] window_q;
    reg signed [15:0] ar, ai, br, bi;
    reg signed [15:0] re_q,im_q;
    wire [8:0] read_address=(state==READ_A) ? a_addr : (state==READ_B) ? b_addr : index;
    // The sample/butterfly operand is always signed 16-bit. The other
    // operand is signed 17-bit because the unsigned 16-bit Hann coefficient
    // must stay nonnegative. Preserve its full domain with a 33-bit product.
    reg signed [15:0] mult_a;
    reg signed [16:0] mult_b;
    reg signed [32:0] product, p0, p1, p2;
    reg signed [18:0] tr, ti;
    reg [1:0] multiply;
    reg [4:0] bin_band;
    assign busy=state!=CAPTURE;
    function [8:0] reverse9;
        input [8:0] v;
        integer n;
        begin for(n=0;n<9;n=n+1) reverse9[n]=v[8-n]; end
    endfunction
    function [15:0] absolute16;
        input signed [15:0] v;
        begin absolute16=v[15] ? (~v+16'd1) : v; end
    endfunction
    function signed [15:0] clamp;
        input signed [19:0] v;
        begin
            if(v>32767) clamp=32767;
            else if(v< -32768) clamp=-32768;
            else clamp=v[15:0];
        end
    endfunction
    wire [16:0] magnitude={1'b0,absolute16(re_q)}+{1'b0,absolute16(im_q)};
    // The work bank is published in place. The consumer reads its 32 words
    // after result_valid and finishes before the next 512-sample capture.
    // There is no asynchronous RAM reset and no second 512-bit result vector.
    // Port A reads the old maximum alongside re/im in BIN_READ, then updates
    // it in the existing BIN_SAVE cycle. This preserves the legacy schedule.
    // Clearing the first 32 left LOAD_READ cycles costs no additional state.
    wire [4:0] lookup_band=band_rom[index[7:0]][4:0];
    wire [15:0] band_work_q;
    wire twiddle_re_read=rst_n&&!clear&&state==READ_A;
    wire twiddle_im_read=rst_n&&!clear&&state==READ_B;
    wire band_clear=rst_n&&!clear&&!channel&&state==LOAD_READ&&index<32;
    wire band_work_read=rst_n&&!clear&&state==BIN_READ;
    wire band_update=rst_n&&!clear&&state==BIN_SAVE&&magnitude>{1'b0,band_work_q};
    // Use the otherwise idle maximum-RAM A port for twiddle Re/Im in
    // READ_A/READ_B. GET_B is still one cycle before MUL_START, so both
    // synchronous halves are available on the original multiply schedule.
    // Constants occupy untouched addresses 256..511 and 512..767; all
    // maximum clear/update writes remain confined to addresses 0..31.
    wire [9:0] band_work_address=twiddle_re_read ? {2'b01,twiddle_address}:
        twiddle_im_read ? {2'b10,twiddle_address}:
        {5'd0,band_clear ? index[4:0]:state==BIN_READ ? lookup_band:bin_band};
    wire [15:0] band_work_data=band_clear ? 16'd0:
        magnitude[16] ? 16'hffff:magnitude[15:0];
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
        .DATA_WIDTH_B(16),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),
        .WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),.IMPLEMENT("32K"),
        .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("fft_work_bank.mif"),.FILL_ALL("NONE")) band_ram(
        .dia(band_work_data),.dib(16'd0),.addra(band_work_address),.addrb({5'd0,band_read_address}),
        .cea(band_clear||band_work_read||band_update||twiddle_re_read||twiddle_im_read),.ceb(band_read_enable),
        .ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(clk),
        .wea(band_clear||band_update),.web(1'b0),.bea(1'b0),.beb(1'b0),
        .rsta(1'b0),.rstb(1'b0),.doa(band_work_q),.dob(band_read_data));
    // Shared20-bit signed add/sub preserves the legacy clamp context.
    wire butterfly_subtract=state==WRITE_B;
    wire [8:0] butterfly_address=butterfly_subtract ? b_addr:a_addr;
    wire signed [19:0] butterfly_re_operand=$signed({tr[18],tr}^{20{butterfly_subtract}});
    wire signed [19:0] butterfly_im_operand=$signed({ti[18],ti}^{20{butterfly_subtract}});
    wire signed [19:0] butterfly_carry=$signed({19'd0,butterfly_subtract});
    wire signed [19:0] butterfly_re_total=$signed({{4{ar[15]}},ar})+butterfly_re_operand+butterfly_carry;
    wire signed [19:0] butterfly_im_total=$signed({{4{ai[15]}},ai})+butterfly_im_operand+butterfly_carry;
    wire signed [15:0] butterfly_re_clamped=clamp(butterfly_re_total >>> 1);
    wire signed [15:0] butterfly_im_clamped=clamp(butterfly_im_total >>> 1);
    always @(posedge clk) product<=mult_a*mult_b;
    // RAM ports deliberately have no asynchronous reset. Clear invalidates
    // control state, then the next capture/transform overwrites every word.
    always @(posedge clk) begin
        if(rst_n&&!clear&&state==CAPTURE&&sample_valid) samples[index]<={sample_l,sample_r};
        if(state==LOAD_READ) begin sample_q<=samples[index];window_q<=window_rom[index];end
        if(rst_n&&!clear&&state==READ_B) twiddle_q[31:16]<=band_work_q;
        if(rst_n&&!clear&&state==GET_B) twiddle_q[15:0]<=band_work_q;
        if(state==READ_A||state==READ_B||state==BIN_READ) begin
            re_q<=re_mem[read_address];im_q<=im_mem[read_address];
        end
        if(rst_n&&!clear) begin
            if(state==LOAD_WRITE) begin
                re_mem[reverse9(index)]<=product >>> 15;im_mem[reverse9(index)]<=0;
            end else if(state==WRITE_A||state==WRITE_B) begin
                re_mem[butterfly_address]<=butterfly_re_clamped;
                im_mem[butterfly_address]<=butterfly_im_clamped;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=CAPTURE; index<=0; result_valid<=0;
            skipped_samples<=0; channel<=0;
            stage<=1; base<=0; j<=0; a_addr<=0; b_addr<=1;
            twiddle_step<=9'd256;twiddle_address<=0;
            mult_a<=0;mult_b<=0;multiply<=0;
        end else if(clear) begin
            state<=CAPTURE;index<=0;result_valid<=0;
            skipped_samples<=0;channel<=0;twiddle_step<=9'd256;twiddle_address<=0;
        end else begin
            result_valid<=0;
            if(sample_valid && busy) skipped_samples<=skipped_samples+1;
            case(state)
            CAPTURE: if(sample_valid) begin
                if(index==511) begin
                    index<=0;channel<=0;state<=LOAD_READ;
                        end else index<=index+1;
            end
            LOAD_READ: begin
                state<=LOAD_START;
            end
            LOAD_START: begin
                mult_a<=channel ? $signed(sample_q[15:0]) : $signed(sample_q[31:16]);
                mult_b<=$signed({1'b0,window_q});state<=LOAD_WAIT;
            end
            LOAD_WAIT: state<=LOAD_WRITE;
            LOAD_WRITE: begin
                if(index==511) begin
                    stage<=1;base<=0;j<=0;a_addr<=0;b_addr<=1;state<=READ_A;
                    twiddle_step<=9'd256;twiddle_address<=0;
                end else begin index<=index+1;state<=LOAD_READ;end
            end
            READ_A: begin
                state<=READ_B;
            end
            READ_B: begin ar<=re_q;ai<=im_q;state<=GET_B;end
            GET_B: begin br<=re_q;bi<=im_q;multiply<=0;state<=MUL_START;end
            MUL_START: begin
                case(multiply)
                0: begin mult_a<=br;mult_b<=$signed(twiddle_q[31:16]);end
                1: begin mult_a<=bi;mult_b<=$signed(twiddle_q[15:0]);end
                2: begin mult_a<=br;mult_b<=$signed(twiddle_q[15:0]);end
                3: begin mult_a<=bi;mult_b<=$signed(twiddle_q[31:16]);end
                endcase
                state<=MUL_WAIT;
            end
            MUL_WAIT: state<=MUL_SAVE;
            MUL_SAVE: begin
                case(multiply)
                0:p0<=product;
                1:p1<=product;
                2:p2<=product;
                3:ti<=($signed({p2[32],p2})+$signed({product[32],product})) >>> 15;
                endcase
                if(multiply==3) state<=ROTATE;
                else begin multiply<=multiply+1;state<=MUL_START;end
            end
            ROTATE: begin tr<=($signed({p0[32],p0})-$signed({p1[32],p1})) >>> 15;state<=WRITE_A;end
            WRITE_A: begin
                state<=WRITE_B;
            end
            WRITE_B: begin
                if(j+1<half_size) begin
                    j<=j+1;a_addr<=a_addr+1;b_addr<=b_addr+1;state<=READ_A;
                    twiddle_address<=twiddle_address+twiddle_step[7:0];
                end else if(base+full_size<512) begin
                    base<=base+full_size;j<=0;twiddle_address<=0;
                    a_addr<=base+full_size;b_addr<=base+full_size+half_size;state<=READ_A;
                end else if(stage<9) begin
                    stage<=stage+1;base<=0;j<=0;a_addr<=0;b_addr<=full_size;state<=READ_A;
                    twiddle_address<=0;twiddle_step<=twiddle_step>>1;
                end else begin index<=1;state<=BIN_READ;end
            end
            BIN_READ: begin
                bin_band<=lookup_band;state<=BIN_SAVE;
            end
            BIN_SAVE: begin
                if(index==255) begin
                    if(!channel) begin channel<=1;index<=0;state<=LOAD_READ;end
                    else state<=PUBLISH;
                end else begin index<=index+1;state<=BIN_READ;end
            end
            PUBLISH: begin
                result_valid<=1;state<=CAPTURE;index<=0;
            end
            default:state<=CAPTURE;
            endcase
        end
    end
endmodule
