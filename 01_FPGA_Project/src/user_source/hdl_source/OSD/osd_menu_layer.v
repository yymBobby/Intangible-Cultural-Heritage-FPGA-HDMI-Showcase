`timescale 1ns/1ps
// 320x480 native-pixel menu. Five stages: geometry, layout, glyph, ROM, blend.
// Body/title use 32px glyphs; values/footer sample existing rows at 16px.
module osd_menu_layer #(parameter integer ENABLE_ALARM=0)(
    input wire alarm_active_pix,
    output wire alarm_cover_out,alarm_ink_out,
    input wire clk_pix,rst_pix_n,
    input wire [67:0] snapshot_pix,
    input wire [10:0] x_in,
    input wire [9:0] y_in,
    input wire [23:0] rgb_in,
    input wire de_in,hs_in,vs_in,
    output wire font_req,
    output wire [12:0] font_addr,
    input wire [31:0] font_row,
    output wire [23:0] rgb_out,
    output reg de_out,hs_out,vs_out,cover_out,
    output wire pipeline_idle
);
    // Split coordinate subtraction/row decoding from layout table selection.
    reg alarm_g;
    reg [10:0] x_work;
    reg [9:0] y_work,list_y_g;
    reg [2:0] slot_g,item_g;
    reg row_exists_g,row_selected_g;
    reg [8:0] text_zone_g;
    reg [23:0] rgb_work;
    reg de_work,hs_work,vs_work;
    wire [9:0] list_y_input=y_in-184;
    // Five visible rows; derive a 0/1/2 row offset from the selected item.
    // No extra snapshot bits or menu panel height are required for seven items.
    wire [2:0] scroll_input=snapshot_pix[1] && snapshot_pix[3:2]==0 && snapshot_pix[6:4]>4 ?
        snapshot_pix[6:4]-3'd4:3'd0;
    wire [2:0] item_input=list_y_input[8:6]+scroll_input;
    wire [2:0] count_input=snapshot_pix[3:2]==0 ? 3'd7:snapshot_pix[3:2]==1 ? 3'd5:3'd1;
    `include "menu_text_lut.vh"
    // Position changes only with the accepted frame snapshot. Convert the
    // two signed values together in blank, sharing one ten-step double-dabble
    // converter, and publish both atomically. No division in a pixel path.
    reg [19:0] position_target;
    reg decimal_busy,decimal_axis;
    reg [3:0] decimal_count;
    reg [9:0] binary_position;
    reg [11:0] decimal_digits,staged_x_digits,x_digits,y_digits;
    reg x_negative,y_negative;
    reg [11:0] decimal_adjusted;
    integer digit;
    always @* begin
        decimal_adjusted=decimal_digits;
        for(digit=0;digit<3;digit=digit+1)
            if(decimal_digits[digit*4+:4]>=5)
                decimal_adjusted[digit*4+:4]=decimal_digits[digit*4+:4]+4'd3;
    end
    wire [11:0] decimal_next={decimal_adjusted[10:0],binary_position[9]};
    function [9:0] absolute_position;
        input [9:0] value;
        begin absolute_position=value[9] ? (~value)+10'd1:value;end
    endfunction
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            position_target<=0;decimal_busy<=0;decimal_axis<=0;decimal_count<=0;
            binary_position<=0;decimal_digits<=0;staged_x_digits<=0;
            x_digits<=0;y_digits<=0;x_negative<=0;y_negative<=0;
        end else if(!decimal_busy) begin
            if(position_target!=snapshot_pix[67:48]) begin
                position_target<=snapshot_pix[67:48];decimal_busy<=1;decimal_axis<=0;
                binary_position<=absolute_position(snapshot_pix[57:48]);decimal_digits<=0;decimal_count<=9;
            end
        end else begin
            binary_position<={binary_position[8:0],1'b0};decimal_digits<=decimal_next;
            if(decimal_count!=0)decimal_count<=decimal_count-1'b1;
            else if(!decimal_axis) begin
                staged_x_digits<=decimal_next;decimal_axis<=1;decimal_digits<=0;decimal_count<=9;
                binary_position<=absolute_position(position_target[19:10]);
            end else begin
                x_digits<=staged_x_digits;y_digits<=decimal_next;
                x_negative<=position_target[9];y_negative<=position_target[19];decimal_busy<=0;
            end
        end
    end
    function [42:0] signed_decimal_word;
        input [11:0] digits;input negative;
        reg [7:0] ones,tens,hundreds,sign;
        begin
            ones=GLYPH_ZERO+{4'd0,digits[3:0]};tens=GLYPH_ZERO+{4'd0,digits[7:4]};
            hundreds=GLYPH_ZERO+{4'd0,digits[11:8]};sign=negative ? GLYPH_MINUS:GLYPH_PLUS;
            if(digits==0)signed_decimal_word={3'd1,32'd0,GLYPH_ZERO};
            else if(digits[11:8]!=0)signed_decimal_word={3'd4,8'd0,ones,tens,hundreds,sign};
            else if(digits[7:4]!=0)signed_decimal_word={3'd3,16'd0,ones,tens,sign};
            else signed_decimal_word={3'd2,24'd0,ones,sign};
        end
    endfunction
    wire [42:0] x_decimal=signed_decimal_word(x_digits,x_negative);
    wire [42:0] y_decimal=signed_decimal_word(y_digits,y_negative);
    wire child_input=snapshot_pix[1],editing_input=snapshot_pix[8];
    wire [1:0] group_input=snapshot_pix[3:2];
    wire selected_input=item_input==snapshot_pix[6:4];
    wire signed [8:0] candidate_input=snapshot_pix[19:11];
    wire [19:0] values_input=snapshot_pix[39:20];
    reg signed [9:0] number_input;
    reg [4:0] id_input;
    reg [9:0] magnitude_input;
    reg [7:0] hundreds_input,tens_input,ones_input,sign_input;
    reg [39:0] word_input,value_word_g;
    reg [2:0] length_input,value_length_g;
    reg [4:0] header_id_g,footer0_id_g,footer1_id_g,badge_id_g;
    reg [5:0] status_id_g;
    always @* begin
        number_input=0;id_input=0;magnitude_input=0;word_input=0;length_input=0;
        hundreds_input=0;tens_input=0;ones_input=0;sign_input=0;
            if(child_input && !(group_input==0 && item_input==6) && group_input!=2) begin
                if(group_input==0) case(item_input)
                    0:begin number_input=editing_input && selected_input ? candidate_input:{7'd0,values_input[1:0]};id_input=number_input[1:0];end
                    1:begin number_input=editing_input && selected_input ? candidate_input:{7'd0,snapshot_pix[46:45]};id_input=5'd2+{3'd0,number_input[1:0]};end
                    2:begin
                        number_input=editing_input && selected_input ? candidate_input:{7'd0,values_input[3:2]};
                        case(number_input) 0,1:id_input=3;2:id_input=5;default:id_input=6;endcase
                    end
                    3:number_input=$signed(snapshot_pix[57:48]);
                    4:number_input=$signed(snapshot_pix[67:58]);
                    5:begin number_input=editing_input && selected_input ? candidate_input:{7'd0,values_input[15:14]};id_input=5'd7+{3'd0,number_input[1:0]};end
                    default:begin end
                endcase
                else case(item_input)
                    0:begin number_input=editing_input && selected_input ? candidate_input:{8'd0,values_input[16]};id_input=5'd10+{4'd0,number_input[0]};end
                    1:begin number_input=editing_input && selected_input ? candidate_input:{7'd0,values_input[18:17]};id_input=5'd12+{3'd0,number_input[1:0]};end
                    2:begin number_input=editing_input && selected_input ? candidate_input:{8'd0,values_input[19]};id_input=5'd10+{4'd0,number_input[0]};end
                    3:begin number_input={7'd0,snapshot_pix[41:40]};id_input={3'd0,number_input[1:0]};end
                    4:begin number_input={7'd0,snapshot_pix[43:42]};id_input=5'd17+{3'd0,number_input[1:0]};end
                    default:begin end
                endcase
                word_input=menu_value_word(id_input);length_input=menu_value_length(id_input);
                if(group_input==0 && (item_input==3 || item_input==4)) begin
                    {length_input,word_input}=item_input==3 ? x_decimal:y_decimal;
                end
            end else if(group_input==2 && editing_input) begin
                id_input=candidate_input==0 ? 5'd15:5'd16;word_input=menu_value_word(id_input);length_input=2;
            end
    end
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            alarm_g<=0;x_work<=0;y_work<=0;list_y_g<=0;slot_g<=0;item_g<=0;
            value_word_g<=0;value_length_g<=0;header_id_g<=0;footer0_id_g<=0;footer1_id_g<=0;badge_id_g<=0;status_id_g<=0;
            row_exists_g<=0;row_selected_g<=0;text_zone_g<=0;
            rgb_work<=0;de_work<=0;hs_work<=0;vs_work<=0;
        end else begin
            x_work<=x_in;y_work<=y_in;list_y_g<=list_y_input;
            // Decode text rectangles alongside geometry, before the word LUT.
            // These predicates travel with x_work/y_work: no extra latency.
            text_zone_g[0]<=y_in>=136 && y_in<168;
            text_zone_g[1]<=x_in>=240 && x_in<336 && y_in>=144 && y_in<160;
            text_zone_g[2]<=x_in>=48 && x_in<176 && list_y_input[5:0]>=16 && list_y_input[5:0]<48;
            text_zone_g[3]<=x_in>=48 && x_in<288 && y_in>=520 && y_in<536;
            text_zone_g[4]<=x_in>=48 && x_in<288 && y_in>=544 && y_in<560;
            text_zone_g[5]<=x_in>=288 && x_in<336 && y_in>=544 && y_in<560;
            text_zone_g[6]<=y_in>=568 && y_in<584;
            text_zone_g[7]<=x_in>=64 && x_in<128;
            text_zone_g[8]<=x_in>=240 && x_in<288;

            value_word_g<=word_input;value_length_g<=length_input;
            header_id_g<=child_input ? {3'd0,group_input}+5'd1:5'd0;
            badge_id_g<=snapshot_pix[9] ? 5'd23:5'd14;
            // These controls now drive the accepted frame transform; no
            // obsolete "not ready" placeholder for zoom/position/center.
            status_id_g<=editing_input ? 6'd21:!child_input ? 6'd35:6'd34;
            footer0_id_g<=snapshot_pix[9] ? (!child_input ? 26:editing_input ? (group_input==2 ? 24:28):26):(!child_input ? 15:editing_input ? 19:17);
            footer1_id_g<=snapshot_pix[9] ? (!child_input ? 25:editing_input ? (group_input==2 ? 19:29):snapshot_pix[10] ? 30:27):
                (!child_input ? 16:editing_input ? 20:18);
            slot_g<=list_y_input[8:6];item_g<=item_input;
            // Predecode row predicates in the existing geometry stage. The
            // mailbox freezes snapshot_pix throughout active pixels, so these
            // describe the same pixel as x_work/y_work without extra latency.
            row_exists_g<=snapshot_pix[1] ? item_input<count_input:list_y_input[8:6]<3;
            row_selected_g<=snapshot_pix[1] ? item_input==snapshot_pix[6:4]:list_y_input[8:6]=={1'b0,snapshot_pix[3:2]};
            rgb_work<=rgb_in;de_work<=de_in;hs_work<=hs_in;vs_work<=vs_in;
            alarm_g<=ENABLE_ALARM && alarm_active_pix;
        end
    end
    localparam [23:0] PANEL=24'h102030,GOLD=24'h304050,TITLE=24'h40c0ff,
        INK=24'hffffff,MUTED=24'hc0d0e0,LINE=24'h304050,
        SELECTED=24'h203040,RED=24'h40c0ff;
    function [23:0] half_rgb;
        input [23:0] picture,tint;
        reg [8:0] r,g,b;
        begin
            r={1'b0,picture[23:16]}+{1'b0,tint[23:16]};
            g={1'b0,picture[15:8]}+{1'b0,tint[15:8]};
            b={1'b0,picture[7:0]}+{1'b0,tint[7:0]};
            half_rgb={r[8:1],g[8:1],b[8:1]};
        end
    endfunction
    wire visible=snapshot_pix[0],child=snapshot_pix[1],editing=snapshot_pix[8];
    wire stage2=snapshot_pix[9],quick_entry=snapshot_pix[10];
    wire [1:0] group_id=snapshot_pix[3:2];
    wire [2:0] selected=snapshot_pix[6:4];
    wire first=snapshot_pix[7];
    wire signed [8:0] candidate=snapshot_pix[19:11];
    wire [19:0] values=snapshot_pix[39:20];
    wire [2:0] count=group_id==0 ? 3'd7:group_id==1 ? 3'd5:3'd1;
    wire descriptor_ok=group_id<=2 && (!child || selected<count) && (!first || (child && group_id==0));
    wire alarm_region=ENABLE_ALARM && alarm_g && x_work<960 && y_work<112;
    wire panel=de_work && (alarm_region || (visible && descriptor_ok && x_work>=32 && x_work<352 && y_work>=120 && y_work<600));
    `include "alarm_text_lut.vh"
    wire [9:0] list_y=list_y_g;
    wire [2:0] slot=slot_g;
    wire [2:0] item=item_g;
    wire list=y_work>=184 && y_work<504;
    wire row_exists=row_exists_g;
    wire row_selected=row_selected_g;
    wire [10:0] label_x=x_work-48;
    wire [10:0] footer_x=x_work-48;
    wire [9:0] header_y=y_work-136;
    reg [23:0] base_color,text_color;
    reg base_solid;
    reg [5:0] text_id;reg [4:0] value_id;
    reg [127:0] word,glyph_word;
    reg [39:0] value_word;
    reg [2:0] value_length;
    reg signed [8:0] value_number;
    reg [7:0] glyph;
    reg [4:0] row,col;
    reg hit,small_text,static_text;
    reg [4:0] char_index;
    reg [10:0] start_x,relative_x;
    reg [9:0] relative_y;
    reg [3:0] magnitude;
    always @* begin
        base_color=PANEL;base_solid=0;text_color=INK;text_id=0;value_id=0;word=0;
        value_word=0;value_length=0;value_number=0;glyph=0;glyph_word=0;row=0;col=0;
        hit=0;small_text=0;static_text=0;char_index=0;start_x=0;relative_x=0;relative_y=0;magnitude=0;
        if(list && row_exists) begin
            if(row_selected) base_color=SELECTED;
            if(list_y[5:0]==0) begin base_color=LINE;base_solid=1;end
            if(row_selected && x_work>=33 && x_work<37) begin base_color=RED;base_solid=1;end
        end
        if(x_work==32 || x_work==351 || y_work==120 || y_work==599 || y_work==184 || y_work==504)
            begin base_color=GOLD;base_solid=1;end
        // Header, compact SW0 badge and geometric back arrow.
        if(text_zone_g[0]) begin
            start_x=child ? 11'd68:11'd48;
            if(x_work>=start_x && x_work<start_x+128) begin
                text_id=header_id_g;
                text_id=text_id;static_text=1;relative_x=x_work-start_x;
                char_index={3'd0,relative_x[6:5]};row=header_y[4:0];col=relative_x[4:0];
                hit=1;text_color=INK;
            end
        end
        if(text_zone_g[1]) begin
            text_id=badge_id_g;static_text=1;relative_x=x_work-240;relative_y=y_work-144;
            char_index=relative_x[7:4];row={relative_y[3:0],1'b0};col={relative_x[3:0],1'b0};
            hit=1;small_text=1;text_color=TITLE;
        end
        if(child && y_work>=140 && y_work<=156 && x_work>=52 && x_work<=60 &&
            ((y_work<=148 && x_work==52+148-y_work) || (y_work>148 && x_work==52+y_work-148)))
            begin base_color=TITLE;base_solid=1;end
        // Five body rows, with up to two rows of scrolling for image settings.
        if(list && row_exists) begin
            if(!child) text_id=5'd1+{2'd0,slot};
            else if(group_id==0) begin
                case(item)
                    0:text_id=6'd4;
                    1:text_id=6'd36;
                    default:text_id=6'd3+{3'd0,item};
                endcase
            end
            else if(group_id==1) begin
                case(item) 3:text_id=6'd32;4:text_id=6'd33;default:text_id=6'd10+{3'd0,item};endcase
            end
            else text_id=13;
            if(text_zone_g[2]) begin
                text_id=text_id;static_text=1;char_index={3'd0,label_x[6:5]};
                row=list_y[4:0]-16;col=label_x[4:0];hit=1;
            end
            value_word=value_word_g;value_length=value_length_g;
            start_x=336-{4'd0,value_length,4'd0};
            if(child && value_length!=0 && x_work>=start_x && x_work<336 && list_y[5:0]>=24 && list_y[5:0]<40) begin
                relative_x=x_work-start_x;relative_y=list_y-24;
                char_index={1'd0,relative_x[7:4]};static_text=0;glyph_word={88'd0,value_word};
                row={relative_y[3:0],1'b0};col={relative_x[3:0],1'b0};small_text=1;hit=1;
                text_color=editing && row_selected ? TITLE:INK;
            end
            // A thin cyan underline makes value editing visibly distinct,
            // using the existing title colour and geometry, without new glyphs.
            if(child && editing && row_selected && value_length!=0 &&
                x_work>=start_x && x_work<336 && list_y[5:0]>=41 && list_y[5:0]<=42)
                begin base_color=TITLE;base_solid=1;end
            if((!child || (group_id==0 && item==6) || (group_id==2 && !editing)) &&
                list_y[5:0]>=26 && list_y[5:0]<=38 && x_work>=324 && x_work<=330 &&
                ((list_y[5:0]<=32 && x_work==324+list_y[5:0]-26) ||
                 (list_y[5:0]>32 && x_work==330-(list_y[5:0]-32)))) begin base_color=TITLE;base_solid=1;end
        end
        // Two 16px hint lines. Numeric position is selection/total, not page.
        if(text_zone_g[3] || text_zone_g[4]) begin
            if(text_zone_g[3]) begin
                text_id=footer0_id_g;
                relative_y=y_work-520;
            end else begin
                text_id=footer1_id_g;
                relative_y=y_work-544;
            end
            text_id=text_id;static_text=1;char_index={1'd0,footer_x[7:4]};
            row={relative_y[3:0],1'b0};col={footer_x[3:0],1'b0};
            small_text=1;hit=1;text_color=MUTED;
        end
        if(text_zone_g[5]) begin
            relative_x=x_work-288;relative_y=y_work-544;
            case(relative_x[5:4])
                0:glyph=GLYPH_ZERO+8'd1+(child ? {5'd0,selected}:{6'd0,group_id});
                1:glyph=GLYPH_SLASH;
                default:glyph=GLYPH_ZERO+(child ? {5'd0,count}:8'd3);
            endcase
            static_text=0;glyph_word={120'd0,glyph};char_index=0;
            row={relative_y[3:0],1'b0};col={relative_x[3:0],1'b0};small_text=1;hit=1;text_color=TITLE;
        end
        if(text_zone_g[6]) begin
            if(child && group_id==0 && !editing && text_zone_g[7]) begin
                text_id=first ? 5'd4:5'd9;static_text=1;relative_x=x_work-64;relative_y=y_work-568;
                char_index={1'd0,relative_x[7:4]};
                row={relative_y[3:0],1'b0};col={relative_x[3:0],1'b0};hit=1;small_text=1;text_color=MUTED;
            end
            if(text_zone_g[8]) begin
                text_id=status_id_g;static_text=1;relative_x=x_work-240;relative_y=y_work-568;
                char_index={1'd0,relative_x[7:4]};
                row={relative_y[3:0],1'b0};col={relative_x[3:0],1'b0};hit=1;small_text=1;text_color=TITLE;
            end
            if(child && group_id==0 && !editing && x_work>=48 && x_work<=56) begin
                if((!first && ((x_work==52 && y_work<=580) || (y_work>=576 && y_work<=580 && (x_work==48+y_work-576 || x_work==56-(y_work-576))))) ||
                   (first && ((x_work==52 && y_work>=572) || (y_work>=572 && y_work<=576 && (x_work==52-(y_work-572) || x_work==52+y_work-572)))))
                    begin base_color=MUTED;base_solid=1;end
            end
        end
        // Share one constant word lookup after layout priority resolution.
        if(static_text)glyph_word=menu_text_word(text_id);
        // Reuse the SAME font row port, glyph mux and half_rgb adder. The
        // static banner occupies y<112; existing menu begins at y=120.
        if(alarm_region) begin
            base_color=24'h641d26;base_solid=0;text_color=24'hf4e9d4;
            glyph_word=0;hit=0;small_text=0;row=0;col=0;char_index=0;
            if(x_work>=24 && x_work<88 && y_work>=24 && y_work<88) begin
                relative_x=x_work-24;relative_y=y_work-24;
                glyph_word={120'd0,ALARM_ICON_GLYPH};
                row=relative_y[5:1];col=relative_x[5:1];hit=1;
            end else if(x_work>=128 && x_work<256 && y_work>=40 && y_work<72) begin
                relative_x=x_work-128;relative_y=y_work-40;
                glyph_word=ALARM_TEXT_WORD;char_index={1'b0,relative_x[8:5]};
                row=relative_y[4:0];col=relative_x[4:0];hit=1;
            end
        end
    end
    // Break row/type selection from the wide character-index mux at 75MHz.
    // No RAM here: one pipeline word, not a menu framebuffer or font copy.
    reg [127:0] word_s0;
    reg [3:0] index_s0;
    reg [23:0] rgb_s0,base_s0,ink_s0;
    reg solid_s0;
    reg de_s0,hs_s0,vs_s0,cover_s0,hit_s0,small_s0;
    reg [4:0] row_s0,col_s0;
    reg [23:0] rgb_s1,rgb_s2,base_s1,base_s2,ink_s1,ink_s2;
    reg de_s1,de_s2,hs_s1,hs_s2,vs_s1,vs_s2,cover_s1,cover_s2;
    reg hit_s1,hit_s2,small_s1,small_s2;
    reg [7:0] glyph_s1;
    reg [4:0] row_s1,col_s1,col_s2;
    assign font_req=hit_s1 && glyph_s1!=0 && glyph_s1<176;
    assign font_addr=font_req ? {glyph_s1,row_s1}:13'd0;
    // Keep exactly the original pixel latency. Select inside four 8-bit
    // groups BEFORE the existing ink register, then select the group after
    // it. This shortens the ROM -> register mux without a new pixel stage.
    // Small text uses even columns, so its adjacent pixel stays in a group.
    reg [3:0] ink_groups_s3;
    reg [1:0] ink_group_index_s3;
    wire ink_bit_s3=ink_groups_s3[ink_group_index_s3];
    genvar group;
    generate for(group=0;group<4;group=group+1) begin: glyph_groups
        wire [7:0] bits=font_row[31-group*8-:8];
        wire group_ink=bits[3'd7-col_s2[2:0]] ||
            (small_s2 && bits[3'd6-{col_s2[2:1],1'b0}]);
        always @(posedge clk_pix or negedge rst_pix_n)
            if(!rst_pix_n)ink_groups_s3[group]<=0;
            else ink_groups_s3[group]<=hit_s2 && group_ink;
    end endgenerate
    reg alarm_s0,alarm_s1,alarm_s2,alarm_s3;
    assign alarm_cover_out=ENABLE_ALARM && de_out && cover_out && alarm_s3;
    assign alarm_ink_out=alarm_cover_out && ink_bit_s3;
    reg [23:0] rgb_s3,base_s3,ink_color_s3;
    assign rgb_out=!de_out ? 24'd0:cover_out ?
        (ink_bit_s3 ? ink_color_s3:base_s3):rgb_s3;
    assign pipeline_idle=!(de_in || de_work || de_s0 || de_s1 || de_s2 || de_out || hit_s0 || font_req || hit_s2);
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            alarm_s0<=0;alarm_s1<=0;alarm_s2<=0;alarm_s3<=0;
            word_s0<=0;index_s0<=0;rgb_s0<=0;base_s0<=0;ink_s0<=0;solid_s0<=0;
            de_s0<=0;hs_s0<=0;vs_s0<=0;cover_s0<=0;hit_s0<=0;small_s0<=0;row_s0<=0;col_s0<=0;
            rgb_s1<=0;rgb_s2<=0;base_s1<=0;base_s2<=0;ink_s1<=0;ink_s2<=0;
            de_s1<=0;de_s2<=0;de_out<=0;hs_s1<=0;hs_s2<=0;hs_out<=0;
            vs_s1<=0;vs_s2<=0;vs_out<=0;cover_s1<=0;cover_s2<=0;cover_out<=0;
            hit_s1<=0;hit_s2<=0;small_s1<=0;small_s2<=0;glyph_s1<=0;row_s1<=0;col_s1<=0;col_s2<=0;
            ink_group_index_s3<=0;rgb_s3<=0;base_s3<=0;ink_color_s3<=0;
        end else begin
            alarm_s0<=alarm_region;alarm_s1<=alarm_s0;alarm_s2<=alarm_s1;alarm_s3<=alarm_s2;
            rgb_s0<=rgb_work;de_s0<=de_work;hs_s0<=hs_work;vs_s0<=vs_work;cover_s0<=panel;
            base_s0<=base_color;solid_s0<=base_solid;ink_s0<=text_color;hit_s0<=panel && hit;
            word_s0<=glyph_word;index_s0<=char_index[3:0];row_s0<=row;col_s0<=col;small_s0<=small_text;
            rgb_s1<=rgb_s0;de_s1<=de_s0;hs_s1<=hs_s0;vs_s1<=vs_s0;cover_s1<=cover_s0;
            // Blend the aligned underlying picture in the existing glyph
            // stage. Text, borders, selection stripe and arrows stay solid.
            base_s1<=solid_s0 ? base_s0:half_rgb(rgb_s0,base_s0);
            ink_s1<=ink_s0;hit_s1<=hit_s0;
            small_s1<=small_s0;glyph_s1<=word_s0[{index_s0,3'b000}+:8];row_s1<=row_s0;col_s1<=col_s0;
            rgb_s2<=rgb_s1;de_s2<=de_s1;hs_s2<=hs_s1;vs_s2<=vs_s1;cover_s2<=cover_s1;
            base_s2<=base_s1;ink_s2<=ink_s1;hit_s2<=font_req;small_s2<=small_s1;col_s2<=col_s1;
            de_out<=de_s2;hs_out<=hs_s2;vs_out<=vs_s2;cover_out<=cover_s2;
            ink_group_index_s3<=col_s2[4:3];rgb_s3<=rgb_s2;base_s3<=base_s2;ink_color_s3<=ink_s2;
        end
    end
endmodule
