`timescale 1ns/1ps
// Menu-only values. No media/brightness/scaler/player command outputs.
// Inputs are debounced SYS levels and single-cycle decoded encoder events.
// 48-bit snapshot: visible[0], child[1], group[3:2], selected[6:4],
// first[7], edit[8], reserved[10:9], candidate[19:11], values[39:20].
// Values: brightness[1:0], scale[3:2], x[8:4], y[13:9], filter[15:14],
// auto[16], transition[18:17], subtitle[19]. X/Y are temporary -8..8 steps.
module menu_ui_state(
    input wire clk_sys,rst_sys_n,sw0_valid_sys,sw0_on_sys,
    input wire step_cw_sys,step_ccw_sys,click_sys,back_sys,
    output wire [47:0] snapshot_sys,
    output reg ui_confirm_pulse_sys
);
    localparam [19:0] DEFAULTS=20'h80003;
    reg visible,child,editing,first;
    reg [1:0] group_id;
    reg [2:0] selected;
    reg [19:0] values;
    reg signed [8:0] candidate;
    wire [2:0] last_item=group_id==0 ? 3'd5:group_id==1 ? 3'd2:3'd0;
    wire turn_up=step_cw_sys && !step_ccw_sys;
    wire turn_down=step_ccw_sys && !step_cw_sys;
    reg signed [8:0] initial_value,lower_limit,upper_limit;
    always @* begin
        initial_value=0;lower_limit=0;upper_limit=1;
        if(group_id==0) case(selected)
            0:begin initial_value={7'd0,values[1:0]};upper_limit=3;end
            1:begin initial_value={7'd0,values[3:2]};upper_limit=3;end
            2:begin initial_value={{4{values[8]}},values[8:4]};lower_limit=-8;upper_limit=8;end
            3:begin initial_value={{4{values[13]}},values[13:9]};lower_limit=-8;upper_limit=8;end
            4:begin initial_value={7'd0,values[15:14]};upper_limit=2;end
            default:begin initial_value=0;upper_limit=0;end
        endcase
        else if(group_id==1) case(selected)
            0:initial_value={8'd0,values[16]};
            1:begin initial_value={7'd0,values[18:17]};upper_limit=2;end
            2:initial_value={8'd0,values[19]};
            default:initial_value=0;
        endcase
    end
    assign snapshot_sys={8'd0,values,candidate,2'd0,editing,first,selected,group_id,child,visible};
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            visible<=0;child<=0;editing<=0;first<=0;group_id<=0;selected<=0;
            values<=DEFAULTS;candidate<=0;ui_confirm_pulse_sys<=0;
        end else begin
            ui_confirm_pulse_sys<=0;
            // SW0 acquisition/change wins; events on that edge are discarded.
            if(sw0_valid_sys && sw0_on_sys!=visible) begin
                visible<=sw0_on_sys;child<=0;editing<=0;first<=0;
                selected<=0;candidate<=0;
            end else if(visible && sw0_valid_sys) begin
                if(back_sys) begin
                    if(editing) begin editing<=0;candidate<=0;end
                    else if(child) begin child<=0;selected<=0;first<=0;end
                end else if(click_sys) begin
                    if(!child) begin child<=1;selected<=0;first<=0;end
                    else if(editing) begin
                        editing<=0;ui_confirm_pulse_sys<=1;
                        if(group_id==0) case(selected)
                            0:values[1:0]<=candidate[1:0];
                            1:values[3:2]<=candidate[1:0];
                            2:values[8:4]<=candidate[4:0];
                            3:values[13:9]<=candidate[4:0];
                            4:values[15:14]<=candidate[1:0];
                            default:begin end
                        endcase
                        else if(group_id==1) case(selected)
                            0:values[16]<=candidate[0];
                            1:values[18:17]<=candidate[1:0];
                            2:values[19]<=candidate[0];
                            default:begin end
                        endcase
                        else if(candidate==1) values<=DEFAULTS;
                    end else if(group_id==0 && selected==5) begin
                        values[8:4]<=0;values[13:9]<=0;ui_confirm_pulse_sys<=1;
                    end else begin editing<=1;candidate<=initial_value;end
                end else if(turn_up || turn_down) begin
                    if(editing) begin
                        if(turn_up && candidate<upper_limit) candidate<=candidate+1'b1;
                        else if(turn_down && candidate>lower_limit) candidate<=candidate-1'b1;
                    end else if(!child) begin
                        if(turn_up && group_id<2) group_id<=group_id+1'b1;
                        else if(turn_down && group_id>0) group_id<=group_id-1'b1;
                    end else begin
                        if(turn_up && selected<last_item) begin
                            selected<=selected+1'b1;
                            if(group_id==0 && selected==4) first<=1;
                        end else if(turn_down && selected>0) begin
                            selected<=selected-1'b1;
                            if(selected==1) first<=0;
                        end
                    end
                end
            end
        end
    end
endmodule
