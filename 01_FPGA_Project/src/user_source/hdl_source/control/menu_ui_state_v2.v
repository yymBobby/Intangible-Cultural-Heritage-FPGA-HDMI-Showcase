`timescale 1ns/1ps
// SYS menu settings. Low 40 bits retain the existing UI/transition contract.
// [41:40] volume, [43:42] dwell, [44] restore toggle, [46:45] contrast.
module menu_ui_state_v2 #(parameter integer ENABLE_INHIBIT=0)(
    input wire ui_inhibit_sys,
    input wire clk_sys,rst_sys_n,sw0_valid_sys,sw0_on_sys,
    input wire step_cw_sys,step_ccw_sys,click_sys,back_sys,
    input wire up_sys,down_sys,left_sys,right_sys,joy_click_sys,
    output wire [67:0] snapshot_sys,
    output reg ui_confirm_pulse_sys
);
    localparam [19:0] DEFAULTS=20'h80003;
    reg visible,child,confirming,quick_entry,sw_seen,sw_previous;
    reg [1:0] group_id,root_group;
    reg [2:0] image_item,play_item;
    reg [19:0] values;
    reg [1:0] volume_level,dwell_level,contrast_level;
    reg restore_toggle;
    // Pixel units. Positive X moves right; positive Y moves UP.
    reg signed [9:0] position_x,position_y;
    reg [1:0] zoom_phase;
    wire cw;
    wire [1:0] next_zoom_phase=cw ? zoom_phase+2'd1:zoom_phase-2'd1;
    function [1:0] phase_level;
        input [1:0] phase;
        begin case(phase) 0:phase_level=0;1,3:phase_level=2;default:phase_level=3;endcase end
    endfunction
    function signed [9:0] limit_x;
        input [1:0] level;
        begin case(level) 0:limit_x=0;1:limit_x=0;2:limit_x=240;default:limit_x=480;endcase end
    endfunction
    function signed [9:0] limit_y;
        input [1:0] level;
        begin case(level) 0:limit_y=0;1:limit_y=0;2:limit_y=180;default:limit_y=360;endcase end
    endfunction
    function signed [9:0] clamp_position;
        input signed [9:0] value,maximum;
        begin clamp_position=value>maximum ? maximum:value< -maximum ? -maximum:value;end
    endfunction
    wire [1:0] next_zoom_level=phase_level(next_zoom_phase);
    wire signed [9:0] x_limit=limit_x(values[3:2]),y_limit=limit_y(values[3:2]);
    // Browse pan and numeric fine-pan are mutually exclusive. Share each
    // axis' signed adder/clamp, selecting only the +/-1 or +/-12 constant.
    wire move_x_positive=visible ? cw:right_sys;
    wire move_y_positive=visible ? cw:up_sys;
    wire signed [9:0] delta_x=move_x_positive ? (visible ? 10'sd1:10'sd12):(visible ? -10'sd1:-10'sd12);
    wire signed [9:0] delta_y=move_y_positive ? (visible ? 10'sd1:10'sd12):(visible ? -10'sd1:-10'sd12);
    wire signed [9:0] moved_x=clamp_position(position_x+delta_x,x_limit);
    wire signed [9:0] moved_y=clamp_position(position_y+delta_y,y_limit);
    reg signed [8:0] current_value,lower_limit,upper_limit;
    reg signed [8:0] restore_choice;
    wire signed [8:0] candidate=group_id==2 ? restore_choice:current_value;
    wire [2:0] selected=group_id==0 ? image_item:group_id==1 ? play_item:3'd0;
    wire first=child && group_id==0 && selected>=5;
    wire confirm=right_sys || click_sys;
    wire back=back_sys || (left_sys && child);
    wire up=up_sys && !down_sys,down=down_sys && !up_sys;
    assign cw=(step_cw_sys || (confirming && up)) && !step_ccw_sys && !down;
    wire ccw=(step_ccw_sys || (confirming && down)) && !step_cw_sys && !up;
    wire select_down=down || (!up && !down && cw);
    wire select_up=up || (!up && !down && ccw);
    // Brightness/contrast/volume saturate; other values wrap; zoom has its own reflected cycle, and pixel
    // positions saturate. They must NOT use this wrapping adjustment.
    wire saturating=(group_id==0 && selected<=1) || (group_id==1 && selected==3);
    wire signed [8:0] adjusted=cw ?
        (current_value>=upper_limit ? (saturating ? upper_limit:lower_limit):current_value+9'sd1):
        (current_value<=lower_limit ? (saturating ? lower_limit:upper_limit):current_value-9'sd1);
    always @* begin
        current_value=0;lower_limit=0;upper_limit=1;
        if(group_id==0) case(selected)
            0:begin current_value={7'd0,values[1:0]};upper_limit=3;end
            1:begin current_value={7'd0,contrast_level};upper_limit=3;end
            2:begin current_value={7'd0,values[3:2]};upper_limit=3;end
            5:begin current_value={7'd0,values[15:14]};upper_limit=2;end
            default:upper_limit=0;
        endcase
        else if(group_id==1) case(selected)
            0:current_value={8'd0,values[16]};
            1:begin current_value={7'd0,values[18:17]};upper_limit=2;end
            2:current_value={8'd0,values[19]};
            3:begin current_value={7'd0,volume_level};upper_limit=3;end
            4:begin current_value={7'd0,dwell_level};upper_limit=3;end
            default:begin end
        endcase
    end
    // Bit 8 marks value editing (or system restore confirmation). Values apply live.
    // Candidate mirrors the selected value; obsolete 5-bit X/Y stay zero.
    // [57:48] signed X, [67:58] signed Y, in display pixels.
    assign snapshot_sys={position_y,position_x,1'b0,contrast_level,restore_toggle,dwell_level,volume_level,values,candidate,quick_entry,1'b1,confirming,first,
                         (child ? selected:3'd0),group_id,child,visible};
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            visible<=0;child<=0;confirming<=0;quick_entry<=0;
            sw_seen<=0;sw_previous<=0;group_id<=0;root_group<=0;
            image_item<=0;play_item<=0;values<=DEFAULTS;restore_choice<=0;ui_confirm_pulse_sys<=0;
            volume_level<=3;dwell_level<=1;contrast_level<=1;restore_toggle<=0;
            zoom_phase<=0;position_x<=0;position_y<=0;
        end else begin
            ui_confirm_pulse_sys<=0;
            // Acquire SW0 once, then toggle on either stable edge. A static
            // switch level never overrides joystick navigation afterwards.
            if(ENABLE_INHIBIT && ui_inhibit_sys) begin
                // Consume contacts without modifying menu/settings. Track SW0
                // here so an inhibited physical edge cannot replay on unmute.
                if(sw0_valid_sys) begin sw_seen<=1;sw_previous<=sw0_on_sys;end
            end else if(joy_click_sys) begin
                visible<=!visible;child<=0;confirming<=0;quick_entry<=0;restore_choice<=0;group_id<=root_group;
            end else if(sw0_valid_sys && !sw_seen) begin
                sw_seen<=1;sw_previous<=sw0_on_sys;
                if(sw0_on_sys) begin visible<=1;child<=0;group_id<=root_group;end
            end else if(sw0_valid_sys && sw0_on_sys!=sw_previous) begin
                sw_previous<=sw0_on_sys;visible<=!visible;child<=0;
                confirming<=0;quick_entry<=0;restore_choice<=0;group_id<=root_group;
            end else if(!visible) begin
                // Enlarged images use all four directions for bounded pan.
                // Twelve display pixels per event; opposite events cancel.
                if(values[3:2]>=2) begin
                    if(right_sys && !left_sys)
                        position_x<=moved_x;
                    else if(left_sys && !right_sys)
                        position_x<=moved_x;
                    if(up) position_y<=moved_y;
                    else if(down) position_y<=moved_y;
                end
            end else if(back) begin
                if(confirming) begin confirming<=0;restore_choice<=0;ui_confirm_pulse_sys<=group_id!=2;end
                else if(child && !quick_entry) begin child<=0;group_id<=root_group;end
                else begin
                    child<=0;quick_entry<=0;group_id<=root_group;
                    // Joystick click/SW0 close the menu; encoder click enters.
                end
            end else if(confirm) begin
                if(!child) begin child<=1;quick_entry<=0;end
                else if(confirming) begin
                    if(group_id==2) begin
                        if(restore_choice==1) begin
                            values<=DEFAULTS;volume_level<=3;dwell_level<=1;contrast_level<=1;
                            zoom_phase<=0;position_x<=0;position_y<=0;
                            restore_toggle<=!restore_toggle;ui_confirm_pulse_sys<=1;
                        end
                        confirming<=0;restore_choice<=0;
                    end else if(click_sys) begin
                        confirming<=0;ui_confirm_pulse_sys<=1;
                    end
                end
                else if(group_id==2) begin confirming<=1;restore_choice<=0;end
                else begin
                    if(group_id==0 && selected==6) begin
                        position_x<=0;position_y<=0;ui_confirm_pulse_sys<=1;
                    end else confirming<=1;
                end
            end else if(confirming && group_id==2) begin
                if(select_up || select_down) restore_choice<=restore_choice==0 ? 9'sd1:9'sd0;
            end else if(!confirming && (up || down || cw || ccw)) begin
                if(!child) begin
                    if(select_down) begin
                        group_id<=group_id==2 ? 2'd0:group_id+1'b1;
                        root_group<=group_id==2 ? 2'd0:group_id+1'b1;
                    end else if(select_up) begin
                        group_id<=group_id==0 ? 2'd2:group_id-1'b1;
                        root_group<=group_id==0 ? 2'd2:group_id-1'b1;
                    end
                end else if(group_id==0) begin
                    if(select_down) image_item<=image_item==6 ? 3'd0:image_item+1'b1;
                    else if(select_up) image_item<=image_item==0 ? 3'd6:image_item-1'b1;
                end else if(group_id==1) begin
                    if(select_down) play_item<=play_item==4 ? 3'd0:play_item+1'b1;
                    else if(select_up) play_item<=play_item==0 ? 3'd4:play_item-1'b1;
                end
            end else if(child && confirming && group_id!=2 && (cw || ccw)) begin
                // Live preview; left/encoder click accepts and returns to list.
                if(group_id==0) case(selected)
                    0:values[1:0]<=adjusted[1:0];
                    1:contrast_level<=adjusted[1:0];
                    2:begin
                        zoom_phase<=next_zoom_phase;values[3:2]<=next_zoom_level;
                        position_x<=clamp_position(position_x,limit_x(next_zoom_level));
                        position_y<=clamp_position(position_y,limit_y(next_zoom_level));
                    end
                    3:begin
                        position_x<=moved_x;
                    end
                    4:begin
                        position_y<=moved_y;
                    end
                    5:values[15:14]<=adjusted[1:0];
                    default:begin end
                endcase
                else case(selected)
                    0:values[16]<=adjusted[0];
                    1:values[18:17]<=adjusted[1:0];
                    2:values[19]<=adjusted[0];
                    3:volume_level<=adjusted[1:0];
                    4:dwell_level<=adjusted[1:0];
                    default:begin end
                endcase
            end
        end
    end
endmodule
