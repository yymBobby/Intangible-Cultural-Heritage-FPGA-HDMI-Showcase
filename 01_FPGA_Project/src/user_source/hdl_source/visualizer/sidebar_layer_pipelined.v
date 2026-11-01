`timescale 1ns/1ps
// Five PIX-clock stages from sampled x/y/de to valid/rgb.
// 1: region decode + synchronous font/quadrant ROM; present bar/phase read.
// 2: monitor synchronous display reads complete; delay metadata.
// 3: register signed adjacent-band deltas, interpolation weight and metadata.
// 4: multiply registered deltas, add base/round and maintain raster history.
// 5: register palette RGB and valid. Each cut preserves every input pixel.
// Interpolation changes presentation, never the original FFT resolution.
module sidebar_layer(
    input wire clk,rst_n,de,
    input wire [10:0] x,input wire [9:0] y,
    input wire auto_enabled,running,
    input wire [7:0] bar_height,bar_peak,bar_height_next,bar_peak_next,
    output wire [4:0] bar_address,output wire bar_read,
    input wire [7:0] level_l,level_r,peak_l,peak_r,
    input wire clip_l,clip_r,phase_dot,
    input wire signed [1:0] phase_trend,
    output wire [11:0] phase_address,output wire phase_read,
    output reg valid,output wire [23:0] rgb
);
    localparam [23:0] BACKGROUND=24'h101c30;
    // All fixed UI colors travel as five-bit palette selectors. This keeps
    // the same three pixel cuts while avoiding three 24-bit color banks and
    // repeatedly expanded RGB muxes; gradient RGB is decoded only at output.
    localparam [4:0] C_BLACK=0,C_BG=1,C_DIAGONAL=2,C_AXIS=3,C_RED=4,
        C_NEUTRAL=5,C_GREEN=6,C_TRACK=7,C_AMBER=8,C_WHITE=9,C_CLIP=10,
        C_GRID=11,C_PEAK=12,C_GUIDE=13,C_RING_AMBER=14,C_RING_GREEN=15,
        C_RING_BLUE=16,C_DIM=17,C_LABEL=18,C_PHASE=19,C_GRADIENT=20,C_FILL=21;
    wire field=x>=1056&&x<1184&&y>=152&&y<280;
    wire ring_region=x>=992&&x<1248&&y>=88&&y<344;
    wire frequency=x>=992&&x<1248&&y>=496&&y<=688;
    wire meter=x>=976&&x<1264&&((y>=380&&y<404)||(y>=420&&y<444));
    wire clip=x>=1268&&x<1276&&((y>=380&&y<404)||(y>=420&&y<444));
    wire led=x>=1256&&x<1264&&y>=20&&y<28;
    wire [7:0] abs_x=x<1120 ? 11'd1120-x:x-11'd1120;
    wire [7:0] abs_y=y<216 ? 10'd216-y:y-10'd216;
    wire [6:0] fx=x-1056,fy=y-152;
    wire [7:0] spectrum_x=x-992,distance_y=688-y;
    wire [8:0] meter_x=x-976;
    wire right_meter=y>=420;
    wire [7:0] meter_level=right_meter ? level_r:level_l;
    wire [7:0] meter_peak=right_meter ? peak_r:peak_l;
    wire [8:0] filled={1'b0,meter_level}+{2'b0,meter_level[7:1]};
    wire [8:0] marker={1'b0,meter_peak}+{2'b0,meter_peak[7:1]};
    wire [7:0] text_x=x-984;
    // Latin:8 columns scaled2x (16px pitch,32px box); repeat:16x16 scaled2x.
    reg glyph_hit,glyph_repeat,glyph_transport;
    reg [1:0] tone_1,tone_2,tone_3,tone_4;
    reg [4:0] glyph;
    reg [3:0] row,col;reg [4:0] character;
    always @* begin
        glyph_hit=0;glyph_repeat=0;glyph_transport=0;glyph=0;row=0;col=0;character=0;
        if(x>=984&&x<1016&&y>=12&&y<44) begin
            glyph_hit=1;glyph_repeat=1;glyph=5'd16;
            row=(y-12)>>1;col=(x-984)>>1;
        end else if(x>=1216&&x<1248&&y>=12&&y<44) begin
            glyph_hit=1;glyph_transport=1;glyph=running ? 5'd24:5'd23;
            row=(y-12)>>1;col=(x-1216)>>1;
        end else if(x>=984&&x<1080&&y>=52&&y<84) begin
            glyph_hit=1;row=(y-52)>>1;col={1'b0,text_x[3:1]};character=text_x[7:4];
            case(character)
                0:glyph=0;1:glyph=1;2:glyph=2;3:glyph=3;4:glyph=4;default:glyph=5;
            endcase
        end else if(x>=984&&x<1064&&y>=348&&y<380) begin
            glyph_hit=1;row=(y-348)>>1;col={1'b0,text_x[3:1]};character=text_x[7:4];
            case(character)
                0:glyph=6;1:glyph=4;2:glyph=7;3:glyph=4;default:glyph=6;
            endcase
        end else if(x>=984&&x<1128&&y>=464&&y<496) begin
            glyph_hit=1;row=(y-464)>>1;col={1'b0,text_x[3:1]};character=text_x[7:4];
            case(character)
                0:glyph=8;1:glyph=5;2:glyph=4;3:glyph=9;4:glyph=10;
                5:glyph=4;6:glyph=11;7:glyph=12;default:glyph=13;
            endcase
        end else if(x>=960&&x<976&&((y>=384&&y<400)||(y>=424&&y<440))) begin
            glyph_hit=1;row=y-(right_meter ? 424:384);col=x-960;glyph=right_meter ? 5'd15:5'd14;
        end
    end
    // [7:4] radial code1..15 covers half-radii34..63 in 2-unit bins.
    // Sector/gap metadata and quadrant sampling retain all32 FFT bands.
    wire [7:0] geometry_q;
    wire geometry_active=|geometry_q[7:4];
    wire [6:0] geometry_radius={3'd0,geometry_q[7:4]};
    // In inactive inner cells, bit3 stores the circular scope mask instead
    // of a ring angular-gap flag. The same 4096x8 ROM serves both shapes;
    // active ring cells and their sector/radial metadata are unchanged.
    // Explicit4096x8 SP implementation fits ONE physical BRAM32K; inferred
    // ROM may consume scarce9K blocks. NOREG retains the same sync read.
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(8),.ADDR_WIDTH_A(12),.DATA_DEPTH_A(4096),
        .DATA_WIDTH_B(8),.ADDR_WIDTH_B(12),.DATA_DEPTH_B(4096),.MODE("SP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"),.IMPLEMENT("32K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
        .INIT_FILE("sidebar_ring_geometry.mif"),.FILL_ALL("NONE")) geometry_rom(
        .dia(8'd0),.dib(8'd0),.addra({abs_y[6:1],abs_x[6:1]}),.addrb(12'd0),
        .cea(1'b1),.ceb(1'b0),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(clk),
        .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),
        .doa(geometry_q),.dob());
    reg [15:0] font[0:511]; /* fehdl force_ram=1, ram_style="bram" */
    reg [15:0] font_q;
    initial begin
        $readmemh("sidebar_font.hex",font);
    end
    always @(posedge clk) begin
        font_q<=font[{glyph,row}];
    end
    reg de_1,side_1,field_1,ring_1,frequency_1,meter_1,clip_1,led_1;
    reg [1:0] quadrant_1,field_code_1;
    reg [2:0] meter_code_1;
    reg clip_code_1,led_code_1,glyph_1,repeat_1,automatic_1;
    reg [11:0] phase_1;
    wire round_field=field_1&&!geometry_active&&geometry_q[3];
    reg [4:0] band_1;
    reg [7:0] distance_1;
    reg [2:0] fraction_1;
    reg [3:0] col_1;
    reg transport_1,transport_2,transport_3,transport_4;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            de_1<=0;side_1<=0;field_1<=0;ring_1<=0;frequency_1<=0;meter_1<=0;clip_1<=0;led_1<=0;
            quadrant_1<=0;field_code_1<=0;meter_code_1<=0;clip_code_1<=0;led_code_1<=0;
            tone_1<=0;transport_1<=0;glyph_1<=0;repeat_1<=0;automatic_1<=0;phase_1<=0;band_1<=0;distance_1<=0;fraction_1<=0;col_1<=0;
        end else begin
            de_1<=de;side_1<=x>=960;field_1<=field;ring_1<=ring_region&&abs_x<128&&abs_y<128;
            frequency_1<=frequency;meter_1<=meter;clip_1<=clip;led_1<=led;
            quadrant_1<=x>=1120 ? y<216 ? 2'd0:2'd1:y>=216 ? 2'd2:2'd3;
            field_code_1<=fx==fy||fx==127-fy ? 2'd1:x==1120||y==216 ? 2'd2:2'd0;
            meter_code_1<=meter_peak!=0&&meter_x==marker ? 3'd4:
                meter_x<filled ? meter_x>=264 ? 3'd3:meter_x>=228 ? 3'd2:3'd1:3'd0;
            clip_code_1<=right_meter ? clip_r:clip_l;led_code_1<=running;
            phase_1<={fy[6:1],fx[6:1]};band_1<=spectrum_x[7:3];distance_1<=distance_y;fraction_1<=spectrum_x[2:0];
            tone_1<=phase_trend==2'sb10 ? 2'd2:phase_trend[1] ? 2'd1:2'd0;transport_1<=glyph_transport;glyph_1<=glyph_hit;repeat_1<=glyph_repeat;automatic_1<=auto_enabled;col_1<=col;
        end
    end
    wire [4:0] ring_band={quadrant_1,geometry_q[2:0]^{3{quadrant_1[0]}}};
    assign phase_address=phase_1;
    assign phase_read=de_1&&field_1;
    assign bar_address=frequency_1 ? band_1:ring_band;
    assign bar_read=de_1&&(frequency_1||(ring_1&&geometry_active));
    reg [5:0] eased_weight;
    // Rounded smoothstep(t)*32 for t=0/8..7/8; no waveform overshoot.
    always @* case(fraction_1)
        0:eased_weight=0;1:eased_weight=1;2:eased_weight=5;3:eased_weight=10;
        4:eased_weight=16;5:eased_weight=22;6:eased_weight=27;default:eased_weight=31;
    endcase
    reg de_2,side_2,field_2,ring_2,frequency_2,glyph_2,repeat_2,automatic_2;
    reg [7:0] distance_2,spectrum_x_2;
    reg [5:0] weight_2;
    reg [6:0] radius_2;
    reg angular_2;
    reg [4:0] color_2,selected_color;
    always @* begin
        selected_color=C_BG;
        if(round_field) selected_color=field_code_1==1 ? C_DIAGONAL:field_code_1==2 ? C_AXIS:C_BG;
        if(meter_1) case(meter_code_1)
            1:selected_color=C_GREEN;2:selected_color=C_AMBER;3:selected_color=C_RED;4:selected_color=C_WHITE;
            default:selected_color=C_TRACK;
        endcase
        if(clip_1) selected_color=clip_code_1 ? C_CLIP:C_TRACK;
        if(led_1) selected_color=led_code_1 ? C_GREEN:C_AMBER;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            de_2<=0;side_2<=0;field_2<=0;ring_2<=0;frequency_2<=0;glyph_2<=0;repeat_2<=0;automatic_2<=0;
            tone_2<=0;transport_2<=0;distance_2<=0;spectrum_x_2<=0;weight_2<=0;radius_2<=0;angular_2<=0;color_2<=0;
        end else begin
            tone_2<=tone_1;transport_2<=transport_1;de_2<=de_1;side_2<=side_1;field_2<=round_field;ring_2<=ring_1&&geometry_active;frequency_2<=frequency_1;
            glyph_2<=glyph_1&&font_q[15-col_1];repeat_2<=repeat_1;automatic_2<=automatic_1;
            distance_2<=distance_1;spectrum_x_2<={band_1,fraction_1};weight_2<=eased_weight;radius_2<=geometry_radius;angular_2<=geometry_q[3];color_2<=selected_color;
        end
    end
    reg de_3,side_3,field_3,phase_3,ring_3,frequency_3,glyph_3,repeat_3,automatic_3,angular_3;
    reg [7:0] distance_3,height_3,peak_3,spectrum_x_3;
    reg signed [8:0] height_delta_3,peak_delta_3;
    reg [5:0] weight_3;
    reg [6:0] radius_3;
    reg [4:0] color_3;
    wire signed [8:0] height_delta=$signed({1'b0,bar_height_next})-$signed({1'b0,bar_height});
    wire signed [8:0] peak_delta=$signed({1'b0,bar_peak_next})-$signed({1'b0,bar_peak});
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            de_3<=0;side_3<=0;field_3<=0;phase_3<=0;ring_3<=0;frequency_3<=0;glyph_3<=0;repeat_3<=0;automatic_3<=0;angular_3<=0;
            tone_3<=0;transport_3<=0;distance_3<=0;height_3<=0;peak_3<=0;spectrum_x_3<=0;height_delta_3<=0;peak_delta_3<=0;weight_3<=0;
            radius_3<=0;color_3<=0;
        end else begin
            tone_3<=tone_2;transport_3<=transport_2;de_3<=de_2;side_3<=side_2;field_3<=field_2;phase_3<=phase_dot;ring_3<=ring_2;frequency_3<=frequency_2;
            glyph_3<=glyph_2;repeat_3<=repeat_2;automatic_3<=automatic_2;angular_3<=angular_2;
            distance_3<=distance_2;height_3<=bar_height;peak_3<=bar_peak;spectrum_x_3<=spectrum_x_2;radius_3<=radius_2;color_3<=color_2;
            height_delta_3<=height_delta;peak_delta_3<=peak_delta;weight_3<=weight_2;
        end
    end
    // Two signed9x7 products share one physical dual9x9 DSP. Their inputs
    // are now registered, so BRAM read/subtract is not in the multiplier path.
    wire signed [15:0] height_product=height_delta_3*$signed({1'b0,weight_3});
    wire signed [15:0] peak_product=peak_delta_3*$signed({1'b0,weight_3});
    reg valid_4,field_4,phase_4,ring_4,frequency_4,glyph_4,repeat_4,automatic_4,angular_4;
    reg [7:0] distance_4,height_4,peak_4,spectrum_x_4;
    reg [7:0] previous_height_4,previous_peak_4;
    reg connect_curve_4;
    reg [6:0] radius_4;
    reg [4:0] color_4;
    reg signed [14:0] height_blend_4,peak_blend_4;
    wire [7:0] curve_height=height_blend_4[12:5];
    wire [7:0] curve_peak=peak_blend_4[12:5];
    reg [7:0] gradient_r,gradient_g,gradient_b;
    reg [7:0] gradient_r_next,gradient_g_next,gradient_b_next;
    reg [7:0] distance_plus_one,distance_minus_one;
    wire [7:0] doubled_distance={distance_3[6:0],1'b0};
    always @* begin
        // Exact modulo-256 identities for the original three segments:
        // middle/high red = 2*d-156; low/middle green = 136+floor(d/2).
        gradient_r_next=distance_3>96 ? doubled_distance-8'd156:8'd36;
        gradient_g_next=distance_3>160 ? 8'd24-doubled_distance:8'd136+{1'b0,distance_3[7:1]};
        gradient_b_next=distance_3>160 ? 8'd56:distance_3>96 ? 8'd120-doubled_distance:8'd208+~{2'b00,distance_3[7:2]}+8'd1;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            valid_4<=0;field_4<=0;phase_4<=0;ring_4<=0;frequency_4<=0;glyph_4<=0;repeat_4<=0;automatic_4<=0;angular_4<=0;
            tone_4<=0;transport_4<=0;distance_4<=0;height_4<=0;peak_4<=0;spectrum_x_4<=0;previous_height_4<=0;previous_peak_4<=0;connect_curve_4<=0;
            radius_4<=0;color_4<=0;height_blend_4<=0;peak_blend_4<=0;
            gradient_r<=36;gradient_g<=136;gradient_b<=208;distance_plus_one<=1;distance_minus_one<=255;
        end else begin
            gradient_r<=gradient_r_next;gradient_g<=gradient_g_next;gradient_b<=gradient_b_next;
            distance_plus_one<=distance_3+8'd1;distance_minus_one<=distance_3-8'd1;
            tone_4<=tone_3;transport_4<=transport_3;valid_4<=de_3&&side_3;field_4<=field_3;phase_4<=phase_3;ring_4<=ring_3;frequency_4<=frequency_3;
            glyph_4<=glyph_3;repeat_4<=repeat_3;automatic_4<=automatic_3;angular_4<=angular_3;
            distance_4<=distance_3;height_4<=height_3;peak_4<=peak_3;spectrum_x_4<=spectrum_x_3;radius_4<=radius_3;color_4<=color_3;
            // Stage-4 raster history belongs to the preceding pixel of the
            // same row; arbitrary jumps, blanking and row boundaries reset it.
            previous_height_4<=curve_height;previous_peak_4<=curve_peak;
            connect_curve_4<=frequency_3&&frequency_4&&valid_4&&de_3&&spectrum_x_3!=0&&
                spectrum_x_3==spectrum_x_4+8'd1&&distance_3==distance_4;
            height_blend_4<=$signed({2'b00,height_3,5'b00000})+height_product+15'sd16;
            peak_blend_4<=$signed({2'b00,peak_3,5'b00000})+peak_product+15'sd16;
        end
    end
    wire [23:0] gradient={gradient_r,gradient_g,gradient_b};
    wire [23:0] fill_gradient={1'b0,gradient_r[7:1],1'b0,gradient_g[7:1],1'b0,gradient_b[7:1]};
    // A point lies in an unordered inclusive endpoint interval exactly when
    // its two strict-less relations differ, or it equals either endpoint.
    // The current-height strict comparison also supplies the filled region.
    // This avoids duplicate greater/equal comparator chains and min/max muxes.
    wire curve_nonzero=curve_height!=0||(connect_curve_4&&previous_height_4!=0);
    wire peak_nonzero=curve_peak!=0||(connect_curve_4&&previous_peak_4!=0);
    wire below_height=distance_4<curve_height;
    wire below_peak=distance_4<curve_peak;
    wire curve_edge=distance_4==curve_height||
        (connect_curve_4&&((below_height^(distance_4<previous_height_4))||distance_4==previous_height_4));
    wire peak_edge=distance_4==curve_peak||
        (connect_curve_4&&((below_peak^(distance_4<previous_peak_4))||distance_4==previous_peak_4));
    // Endpoint halos lying inside the interval already receive the edge
    // color. Outside it, these are exactly min-1 and max+1, without a mux.
    wire curve_glow=(distance_4!=255&&distance_plus_one==curve_height)||
        (distance_4!=0&&distance_minus_one==curve_height)||
        (connect_curve_4&&((distance_4!=255&&distance_plus_one==previous_height_4)||
                          (distance_4!=0&&distance_minus_one==previous_height_4)));
    // Display-only knee: scale160 is approximately -12dBFS for a Hann-
    // compensated individual FFT band, not the overall stereo level.
    function [3:0] radial_length(input [7:0] h);
        begin
            if(h<160) radial_length={2'b00,h[7:6]};
            else if(h>=192) radial_length=4'd12;
            else radial_length=4'd2+{1'b0,h[4:2]}+{3'b000,h[4]};
        end
    endfunction
    wire [4:0] ring_tip=5'd3+{1'b0,radial_length(height_4)};
    wire [4:0] peak_tip=5'd3+{1'b0,radial_length(peak_4)};
    // Decode frequency RGB directly. Encoding a palette index and decoding
    // it again put the curve comparators through two cascaded priority muxes.
    // These mutually exclusive masks preserve peak/edge/fill/grid priority.
    wire frequency_peak=peak_nonzero&&peak_edge;
    wire frequency_curve=!frequency_peak&&curve_nonzero&&curve_edge;
    wire frequency_fill=!frequency_peak&&!frequency_curve&&
        ((curve_height!=0&&below_height)||(curve_nonzero&&curve_glow));
    wire frequency_grid=!frequency_peak&&!frequency_curve&&!frequency_fill&&
        (distance_4==0||distance_4==48||distance_4==96||distance_4==144||distance_4==192);
    wire frequency_background=!(frequency_peak||frequency_curve||frequency_fill||frequency_grid);
    wire [23:0] frequency_rgb=({24{frequency_peak}}&24'hf5e6a8)|
        ({24{frequency_curve}}&gradient)|({24{frequency_fill}}&fill_gradient)|
        ({24{frequency_grid}}&24'h27354a)|({24{frequency_background}}&BACKGROUND);
    reg [4:0] ring_color;
    always @* begin
        ring_color=C_BG;
        if(radius_4==2||radius_4==15) ring_color=C_GUIDE;
        if(angular_4&&height_4!=0&&radius_4>=3&&radius_4<=ring_tip)
            ring_color=radius_4>=11 ? C_RING_AMBER:radius_4>=7 ? C_RING_GREEN:C_RING_BLUE;
        if(angular_4&&peak_4!=0&&radius_4==peak_tip) ring_color=C_PEAK;
    end
    // Color metadata follows the same PIX stages as the scope dot and mask.
    wire [4:0] phase_color=tone_4==2 ? C_RED:tone_4==1 ? C_AMBER:C_PHASE;
    wire [4:0] palette_color=glyph_4 ? (repeat_4 ? automatic_4 ? C_GREEN:C_DIM:C_LABEL):
        field_4&&phase_4 ? phase_color:ring_4&&!field_4 ? ring_color:color_4;
    reg [23:0] palette_rgb;
    always @* case(palette_color)
        C_BLACK:palette_rgb=24'h000000;C_BG:palette_rgb=BACKGROUND;
        C_DIAGONAL:palette_rgb=24'h20354a;C_AXIS:palette_rgb=24'h30475e;
        C_RED:palette_rgb=24'hff647c;C_NEUTRAL:palette_rgb=24'hb8cadd;
        C_GREEN:palette_rgb=24'h47ddb0;C_TRACK:palette_rgb=24'h263349;
        C_AMBER:palette_rgb=24'hffcc63;C_WHITE:palette_rgb=24'hffffff;
        C_CLIP:palette_rgb=24'hff425e;C_GRID:palette_rgb=24'h27354a;
        C_PEAK:palette_rgb=24'hf5e6a8;C_GUIDE:palette_rgb=24'h263e54;
        C_RING_AMBER:palette_rgb=24'hffac55;C_RING_GREEN:palette_rgb=24'h51e3b5;
        C_RING_BLUE:palette_rgb=24'h36b7e8;C_DIM:palette_rgb=24'h465467;
        C_LABEL:palette_rgb=24'hd9e9f2;C_PHASE:palette_rgb=24'h64e5d1;
        C_GRADIENT:palette_rgb=gradient;C_FILL:palette_rgb=fill_gradient;
        default:palette_rgb=24'h000000;
    endcase
    reg [23:0] color_5;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin valid<=0;color_5<=0;end
        else begin valid<=valid_4;color_5<=frequency_4&&!glyph_4&&!(field_4&&phase_4) ? frequency_rgb:palette_rgb;end
    end
    assign rgb=color_5;
endmodule
