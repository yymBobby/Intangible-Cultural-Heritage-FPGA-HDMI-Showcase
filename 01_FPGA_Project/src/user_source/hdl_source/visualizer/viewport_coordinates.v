`timescale 1ns/1ps
// Edge-aligned mapping; exact rational coordinate, then FLOOR to Q8.
// 100% means the existing 960x720 viewport, not 640x480 native size.
module viewport_coordinates(
    input wire [21:0] transform,
    input wire [10:0] x,input wire [9:0] y,
    output wire [9:0] sx,output wire [8:0] sy,
    output wire [7:0] fx,fy,
    output wire [8:0] first_row,output wire [9:0] row_count
);
    // Keep existing encodings: 0=100%, 2=150%, 3=200%.
    // The removed code 1 defensively falls back to 100%.
    wire [1:0] level=transform[1:0]==2'd1 ? 2'd0:transform[1:0];
    wire signed [9:0] px=$signed(transform[11:2]),py=$signed(transform[21:12]);
    reg signed [10:0] mx,my,cx,cy;
    // Full input-port bounds, including invisible pixels: x<=2047,
    // y<=1023, mx-cx<=960, my+cy<=720. Thus ux<=3007 and
    // uy<=1743; 12 unsigned bits suffice even for out-of-view coordinates.
    reg [11:0] ux,uy,uy_end;
    reg [17:0] qx,qy,qend;
    reg [9:0] last_exclusive;
    function [17:0] coordinate_q8;
        input [11:0] distance;
        input [1:0] scale;
        reg [8:0] common_quotient;
        reg [3:0] remainder;
        reg [11:0] base,whole;
        reg [10:0] tail;
        begin
            // distance = 9*q+r. Retained inverse ratios are 2/3,
            // 4/9 and 1/3, so integer bases are respectively 6*q,
            // 4*q and 3*q. Tiny tables give exact FLOOR-to-Q8 tails.
            common_quotient=distance/12'd9;
            remainder=distance-({common_quotient,3'd0}+{3'd0,common_quotient});
            base=0;tail=0;
            case(scale)
                0:begin
                    base={1'b0,common_quotient,2'd0}+{2'd0,common_quotient,1'b0};
                    case(remainder)
                        0:tail=11'd0;
                        1:tail=11'd170;
                        2:tail=11'd341;
                        3:tail=11'd512;
                        4:tail=11'd682;
                        5:tail=11'd853;
                        6:tail=11'd1024;
                        7:tail=11'd1194;
                        default:tail=11'd1365;
                    endcase
                end
                2:begin
                    base={1'b0,common_quotient,2'd0};
                    case(remainder)
                        0:tail=11'd0;
                        1:tail=11'd113;
                        2:tail=11'd227;
                        3:tail=11'd341;
                        4:tail=11'd455;
                        5:tail=11'd568;
                        6:tail=11'd682;
                        7:tail=11'd796;
                        default:tail=11'd910;
                    endcase
                end
                default:begin
                    base={2'd0,common_quotient,1'b0}+{3'd0,common_quotient};
                    case(remainder)
                        0:tail=11'd0;
                        1:tail=11'd85;
                        2:tail=11'd170;
                        3:tail=11'd256;
                        4:tail=11'd341;
                        5:tail=11'd426;
                        6:tail=11'd512;
                        7:tail=11'd597;
                        default:tail=11'd682;
                    endcase
                end
            endcase
            whole=base+{9'd0,tail[10:8]};
            coordinate_q8={whole>1023 ? 10'h3ff:whole[9:0],tail[7:0]};
        end
    endfunction
    always @* begin
        case(level)
            0:begin mx=0;my=0;end
            1:begin mx=0;my=0;end
            2:begin mx=240;my=180;end
            default:begin mx=480;my=360;end
        endcase
        cx=px>mx ? mx:px< -mx ? -mx:{{1{px[9]}},px};
        cy=py>my ? my:py< -my ? -my:{{1{py[9]}},py};
        // Origin is (-mx+X,-my-Y): increasing user Y moves image UP.
        // Explicit sign extension before mixing with unsigned coordinates.
        // Otherwise a negative 11-bit pan becomes a large positive distance.
        ux={1'b0,x}+{mx[10],mx}-{cx[10],cx};
        uy={2'd0,y}+{my[10],my}+{cy[10],cy};
        uy_end=12'd719+{my[10],my}+{cy[10],cy};
        qx=coordinate_q8(ux,level);qy=coordinate_q8(uy,level);
        qend=coordinate_q8(uy_end,level);
        // Read complete EVEN row spans: every span is a multiple of 256
        // words, compatible with the physical fixed-burst SDRAM core.
        last_exclusive=qend[17:8]>=478 ? 10'd480:({1'b0,qend[16:8]}+10'd3)&10'h3fe;
    end
    wire [11:0] first_distance={my[10],my}+{cy[10],cy};
    wire [17:0] first_q=coordinate_q8(first_distance,level);
    assign first_row={first_q[16:9],1'b0};
    assign row_count=last_exclusive-{1'b0,first_row};
    assign sx=qx[17:8]>639 ? 10'd639:qx[17:8];
    assign sy=qy[17:8]>479 ? 9'd479:qy[16:8];
    assign fx=qx[17:8]>=639 ? 8'd0:qx[7:0];
    assign fy=qy[17:8]>=479 ? 8'd0:qy[7:0];
endmodule

// One coherent transform for both read paths. Capture once at preparation,
// before the adapters launch; animation pins it across all transition frames.
module viewport_frame_lock(
    input wire clk_pix,rst_pix_n,prepare_frame_pix,animation_live_pix,
    input wire [21:0] requested,
    output reg [21:0] frame_transform
);
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) frame_transform<=0;
        else if(prepare_frame_pix && !animation_live_pix) frame_transform<=requested;
    end
endmodule

// Exact restoring division shared by a pair of static coordinates. The
// numerator uses ninths of a source pixel (steps 6,4,3), never a rounded Q8
// step. Thirty clocks in blank replace the per-pixel constant dividers.
module viewport_pair_div9(
 input wire clk,rst_n,start,input wire [11:0] distance0,distance1,
 input wire [2:0] step,
 output reg done,output reg [11:0] quotient0,quotient1,
 output reg [3:0] remainder0,remainder1
);
 // One register holds the remaining dividend followed by quotient bits.
 // Divide the 12-bit distance first; reconstruct the retained rational ratio
 // only at completion, sharing the same arithmetic for both coordinates.
 reg busy,second,scale_phase;reg [3:0] count;
 reg [11:0] work_bits,second_distance;reg [3:0] remainder;reg [2:0] increment;
 wire [4:0] trial={remainder,work_bits[11]};
 wire subtract_nine=trial>=9;
 wire [3:0] next_remainder=subtract_nine ? trial-5'd9:trial[3:0];
 wire [11:0] next_work={work_bits[10:0],subtract_nine};
 wire [8:0] q=work_bits[8:0]; // floor(4095/9)=455
 wire [10:0] triple={1'b0,q,1'b0}+{2'd0,q};
 wire [11:0] base=increment==4 ? {1'b0,q,2'd0}:increment==6 ? {triple,1'b0}:{1'b0,triple};
 reg [6:0] tail; // integer carry [6:4], remainder in ninths [3:0]
 always @* begin
  tail=0;
  case(increment)
   6:case(remainder)
    0:tail={3'd0,4'd0};1:tail={3'd0,4'd6};2:tail={3'd1,4'd3};
    3:tail={3'd2,4'd0};4:tail={3'd2,4'd6};5:tail={3'd3,4'd3};
    6:tail={3'd4,4'd0};7:tail={3'd4,4'd6};default:tail={3'd5,4'd3};
   endcase
   4:case(remainder)
    0:tail={3'd0,4'd0};1:tail={3'd0,4'd4};2:tail={3'd0,4'd8};
    3:tail={3'd1,4'd3};4:tail={3'd1,4'd7};5:tail={3'd2,4'd2};
    6:tail={3'd2,4'd6};7:tail={3'd3,4'd1};default:tail={3'd3,4'd5};
   endcase
   default:case(remainder)
    0:tail={3'd0,4'd0};1:tail={3'd0,4'd3};2:tail={3'd0,4'd6};
    3:tail={3'd1,4'd0};4:tail={3'd1,4'd3};5:tail={3'd1,4'd6};
    6:tail={3'd2,4'd0};7:tail={3'd2,4'd3};default:tail={3'd2,4'd6};
   endcase
  endcase
 end
 wire [11:0] scaled_quotient=base+{9'd0,tail[6:4]};
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin busy<=0;second<=0;scale_phase<=0;count<=0;done<=0;
   work_bits<=0;second_distance<=0;remainder<=0;increment<=6;
   quotient0<=0;quotient1<=0;remainder0<=0;remainder1<=0;
  end else begin
   done<=0;
   if(start && !busy) begin
    work_bits<=distance0;second_distance<=distance1;increment<=step;
    remainder<=0;count<=11;second<=0;scale_phase<=0;busy<=1;
   end else if(busy && !scale_phase) begin
    work_bits<=next_work;remainder<=next_remainder;
    if(count!=0)count<=count-1'b1;else scale_phase<=1;
   end else if(busy) begin
    if(!second) begin
     quotient0<=scaled_quotient;remainder0<=tail[3:0];
     work_bits<=second_distance;remainder<=0;count<=11;second<=1;scale_phase<=0;
    end else begin
     quotient1<=scaled_quotient;remainder1<=tail[3:0];done<=1;busy<=0;
    end
   end
  end
 end
endmodule

// Static frame transform -> source distances. Explicit unsigned wrap of the
// slide coordinate agrees with the existing 11-bit viewport input contract.
module viewport_origin_distances(
 input wire [21:0] transform,input wire [10:0] sample_x,
 output wire [11:0] dx,dy,output wire [2:0] step
);
 wire [1:0] level=transform[1:0]==1 ? 2'd0:transform[1:0];
 wire signed [9:0] px=$signed(transform[11:2]),py=$signed(transform[21:12]);
 reg signed [10:0] mx,my,cx,cy;
 always @* begin
  case(level) 0:begin mx=0;my=0;end
   2:begin mx=240;my=180;end default:begin mx=480;my=360;end endcase
  cx=px>mx ? mx:px< -mx ? -mx:{{1{px[9]}},px};
  cy=py>my ? my:py< -my ? -my:{{1{py[9]}},py};
 end
 assign dx={1'b0,sample_x}+{mx[10],mx}-{cx[10],cx};
 assign dy={my[10],my}+{cy[10],cy};
 assign step=level==0 ? 3'd6:level==2 ? 3'd4:3'd3;
endmodule

module viewport_descriptor_geometry(
 input wire clk,rst_n,start,input wire [21:0] transform,
 output wire done,output wire [8:0] first_row,output wire [9:0] row_count
);
 wire [11:0] distance;wire [2:0] step;wire [11:0] q0,q1;
 viewport_origin_distances origin(.transform(transform),.sample_x(11'd0),.dx(),.dy(distance),.step(step));
 viewport_pair_div9 divide(.clk(clk),.rst_n(rst_n),.start(start),.step(step),
  .distance0(distance),.distance1(distance+12'd719),.done(done),
  .quotient0(q0),.quotient1(q1),.remainder0(),.remainder1());
 wire [9:0] last_exclusive=q1>=478 ? 10'd480:(q1[9:0]+10'd3)&10'h3fe;
 assign first_row={q0[8:1],1'b0};
 assign row_count=last_exclusive-{1'b0,first_row};
endmodule

// Raster-only mapper: initialize in blank, then exact rational recurrence.
// Horizontal state advances once per shown pixel; vertical state advances
// at DE falling edges, including hidden/empty image slices. No Q8 drift.
module viewport_raster_coordinates(
 input wire clk,rst_n,input wire [21:0] transform,
 input wire [10:0] show_begin,view_shift,input wire subtract_shift,
 input wire show,de,vblank,
 output wire [9:0] sx,output wire [8:0] sy,output wire [7:0] fx,fy,
 output reg seed_valid,output wire [1:0] row_bank
);
 wire [44:0] requested={transform,show_begin,view_shift,subtract_shift};
 reg [44:0] target;reg have_target;reg [1:0] state;
 wire [10:0] origin_x=target[0] ? target[22:12]-target[11:1]:target[22:12]+target[11:1];
 wire [11:0] dx,dy;wire [2:0] step;
 viewport_origin_distances origin(.transform(target[44:23]),.sample_x(origin_x),.dx(dx),.dy(dy),.step(step));
 wire done;wire [11:0] qx,qy;wire [3:0] rx,ry;
 viewport_pair_div9 divide(.clk(clk),.rst_n(rst_n),.start(state==1),.distance0(dx),.distance1(dy),
  .step(step),.done(done),.quotient0(qx),.quotient1(qy),.remainder0(rx),.remainder1(ry));
 reg [11:0] seed_x,seed_y,current_x,current_y;
 reg [3:0] seed_rx,seed_ry,current_rx,current_ry;
 reg [2:0] increment;reg de_d;
    reg [1:0] seed_bank,current_bank;
 wire [4:0] next_rx={1'b0,current_rx}+{2'd0,increment};
 wire [4:0] next_ry={1'b0,current_ry}+{2'd0,increment};
 function [7:0] fraction;
  input [3:0] r;
  begin case(r)
   0:fraction=0;1:fraction=28;2:fraction=56;3:fraction=85;
   4:fraction=113;5:fraction=142;6:fraction=170;7:fraction=199;default:fraction=227;
  endcase end
 endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin target<=0;have_target<=0;state<=0;seed_valid<=0;
   seed_x<=0;seed_y<=0;seed_rx<=0;seed_ry<=0;increment<=6;seed_bank<=0;
  end else case(state)
   0:if(!have_target || target!=requested) begin target<=requested;have_target<=1;seed_valid<=0;state<=1;end
   1:state<=2;
   2:if(done) begin seed_x<=qx;seed_y<=qy;seed_rx<=rx;seed_ry<=ry;increment<=step;seed_bank<=qy[8:0]%3;seed_valid<=1;state<=0;end
   default:begin state<=0;seed_valid<=0;have_target<=0;end
  endcase
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin current_x<=0;current_y<=0;current_rx<=0;current_ry<=0;de_d<=0;current_bank<=0;end
  else begin
   de_d<=de;
   if(!seed_valid || !show) begin current_x<=seed_x;current_rx<=seed_rx;end
   else if(next_rx>=9) begin current_x<=current_x+1'b1;current_rx<=next_rx-5'd9;end
   else current_rx<=next_rx[3:0];
   if(!seed_valid || vblank) begin current_y<=seed_y;current_ry<=seed_ry;current_bank<=seed_bank;end
   else if(de_d && !de) begin
    if(next_ry>=9) begin current_y<=current_y+1'b1;current_ry<=next_ry-5'd9;current_bank<=current_bank==2 ? 0:current_bank+1'b1;end
    else current_ry<=next_ry[3:0];
   end
  end
 end
 // Bank follows the integer row carry; no priority tag scan in the pixel
 // data path. The final replicated border row remains physical bank 479%3.
 assign row_bank=current_y>=479 ? 2'd2:current_bank;
 assign sx=current_x>=639 ? 10'd639:current_x[9:0];
 assign sy=current_y>=479 ? 9'd479:current_y[8:0];
 assign fx=current_x>=639 ? 8'd0:fraction(current_rx);
 assign fy=current_y>=479 ? 8'd0:fraction(current_ry);
endmodule
