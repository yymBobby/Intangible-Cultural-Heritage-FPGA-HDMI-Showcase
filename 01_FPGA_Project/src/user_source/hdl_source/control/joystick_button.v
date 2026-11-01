`timescale 1ns/1ps
// Active-low switch: synchronise, require a stable level, suppress power-on-held press.
module joystick_button #(parameter integer STABLE_CYCLES=400000)(
    input wire clk_sys,rst_sys_n,contact_n,
    output reg pressed,press_pulse,valid
);
    localparam integer CW=STABLE_CYCLES>1 ? $clog2(STABLE_CYCLES):1;
    (* async_reg="true" *) reg sync_meta,sync_level;
    reg candidate_n;
    reg [CW-1:0] count;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin sync_meta<=1;sync_level<=1;end
        else begin sync_meta<=contact_n;sync_level<=sync_meta;end
    end
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin candidate_n<=1;count<=0;pressed<=0;press_pulse<=0;valid<=0;end
        else begin
            press_pulse<=0;
            if(sync_level!=candidate_n) begin candidate_n<=sync_level;count<=0;end
            else if(count==STABLE_CYCLES-1) begin
                if(valid && !pressed && !candidate_n) press_pulse<=1;
                pressed<=!candidate_n;valid<=1;
            end else count<=count+1'b1;
        end
    end
endmodule
