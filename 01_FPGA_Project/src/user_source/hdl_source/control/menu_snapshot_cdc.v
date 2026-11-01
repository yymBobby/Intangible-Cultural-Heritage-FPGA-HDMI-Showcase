`timescale 1ns/1ps
// Coalescing UI mailbox, coordinated reset. Complete payload stays held until
// PIX acknowledges at a drained frame boundary; never bit-sync the payload.
module menu_snapshot_cdc #(parameter integer WIDTH=48,parameter [WIDTH-1:0] RESET_SNAPSHOT=0)(
    input wire clk_sys,rst_sys_n,
    input wire [WIDTH-1:0] snapshot_sys,
    output wire ready_sys,
    output reg applied_sys,
    input wire clk_pix,rst_pix_n,apply_safe_pix,
    output reg [WIDTH-1:0] snapshot_pix,
    output reg applied_pix
);
    reg [WIDTH-1:0] held_sys,last_sent_sys;
    reg request_sys,inflight_sys,ack_pix;
    (* async_reg="true" *) reg request_meta_pix,request_sync_pix;
    (* async_reg="true" *) reg ack_meta_sys,ack_sync_sys;
    assign ready_sys=rst_sys_n && !inflight_sys;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            held_sys<=RESET_SNAPSHOT;last_sent_sys<=RESET_SNAPSHOT;request_sys<=0;inflight_sys<=0;
            ack_meta_sys<=0;ack_sync_sys<=0;applied_sys<=0;
        end else begin
            ack_meta_sys<=ack_pix;ack_sync_sys<=ack_meta_sys;applied_sys<=0;
            if(ready_sys && snapshot_sys!=last_sent_sys) begin
                held_sys<=snapshot_sys;last_sent_sys<=snapshot_sys;
                request_sys<=!request_sys;inflight_sys<=1;
            end
            if(inflight_sys && ack_sync_sys==request_sys) begin
                inflight_sys<=0;applied_sys<=1;
            end
        end
    end
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            request_meta_pix<=0;request_sync_pix<=0;ack_pix<=0;
            snapshot_pix<=RESET_SNAPSHOT;applied_pix<=0;
        end else begin
            request_meta_pix<=request_sys;request_sync_pix<=request_meta_pix;
            applied_pix<=0;
            if(apply_safe_pix && request_sync_pix!=ack_pix) begin
                snapshot_pix<=held_sys;ack_pix<=request_sync_pix;applied_pix<=1;
            end
        end
    end
endmodule
