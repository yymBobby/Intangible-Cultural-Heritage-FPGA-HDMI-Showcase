`timescale 1ns/1ps
// C task-five candidate: one SYS-domain picture-task owner, no RAM/FIFO/CDC.
// A must acknowledge only real joint BMP/text/writer completion and safe frame
// commit. The old v2 image_text_loader metadata gate is NOT v3 compatible.
module resource_v3_picture_task #(
    parameter [31:0] PREPARE_TIMEOUT_CYCLES=32'd200000000, // 5s at 40MHz
    parameter [31:0] COMMIT_TIMEOUT_CYCLES=32'd4000000,   // 100ms
    parameter [31:0] STOP_TIMEOUT_CYCLES=32'd40000000,    // 1s
    parameter [31:0] FONT_SET_ID=32'hCBE17BCF,
    parameter [31:0] GLYPH_COUNT=32'd175
) (
    input wire clk_sys,rst_sys_n,
    input wire service_ready,
    input wire [7:0] service_error,
    input wire resource_recovery_req,
    input wire pic_load_valid,
    output wire pic_load_ready,
    input wire [7:0] pic_load_theme_id,pic_load_image_index,
    output reg pic_prepared,
    input wire pic_commit_req,
    output reg pic_commit_ack,
    output reg pic_rsp_valid,
    input wire pic_rsp_ready,
    output reg [2:0] pic_rsp_status,
    output reg [7:0] pic_error_code,
    input wire pic_stop_req,
    output wire pic_idle,
    output reg [7:0] current_theme_id,current_image_index,
    output reg current_valid,recovery_req,
    output wire [7:0] query_theme_id,query_image_index,
    input wire query_valid,
    input wire [7:0] query_image_resource_id,query_audio_resource_id,query_text_resource_id,
    input wire [31:0] query_image_bytes,query_audio_bytes,query_text_bytes,query_display_time_ms,
    input wire [31:0] font_set_id,glyph_count,
    output reg a_load_valid,
    input wire a_load_ready,
    output wire [7:0] a_load_theme_id,a_load_image_index,
    output reg [7:0] a_load_resource_id,a_load_text_resource_id,
    output reg [31:0] a_load_file_bytes,a_load_text_file_bytes,a_load_font_set_id,
    output reg [15:0] a_load_glyph_count,
    output reg [31:0] task_display_time_ms,
    input wire a_idle,a_prepared,a_error_valid,
    input wire [2:0] a_error_status, // normalized TASK status, not raw parser codes
    input wire [7:0] a_error_code,
    input wire a_recovery_req,
    output wire a_stop_req,
    output reg a_commit_req,
    input wire a_commit_ack,a_commit_error,
    output wire [3:0] state_code
);
    localparam [3:0] IDLE=0,QUERY=1,SEND=2,WAIT_PREPARED=3,PREPARED=4,
        ACK_HIGH=5,REQ_LOW=6,ACK_LOW=7,COMPLETE=8,DRAIN=9,RSP=10,RECOVERY=11;
    localparam [31:0] PREPARE_LIMIT=PREPARE_TIMEOUT_CYCLES==0 ? 1:PREPARE_TIMEOUT_CYCLES;
    localparam [31:0] COMMIT_LIMIT=COMMIT_TIMEOUT_CYCLES==0 ? 1:COMMIT_TIMEOUT_CYCLES;
    localparam [31:0] STOP_LIMIT=STOP_TIMEOUT_CYCLES==0 ? 1:STOP_TIMEOUT_CYCLES;
    // Prepare, commit and internal drain are mutually exclusive. Reuse one
    // saturating counter, but retain an independent explicit-stop deadline:
    // stop may overlap any phase, including a commit or a stalled response.
    localparam [31:0] PREPARE_LAST=PREPARE_LIMIT-32'd1,
        COMMIT_LAST=COMMIT_LIMIT-32'd1, STOP_LAST=STOP_LIMIT-32'd1;
    localparam [31:0] PREPARE_COMMIT_MAX=PREPARE_LAST>COMMIT_LAST ? PREPARE_LAST:COMMIT_LAST;
    localparam [31:0] PHASE_LAST_MAX=PREPARE_COMMIT_MAX>STOP_LAST ? PREPARE_COMMIT_MAX:STOP_LAST;
    function integer timer_width;
        input [31:0] last;
        reg [31:0] remaining;
        begin
            remaining=last;timer_width=1;
            while(remaining>1) begin remaining=remaining>>1;timer_width=timer_width+1;end
        end
    endfunction
    localparam integer PHASE_WIDTH=timer_width(PHASE_LAST_MAX), STOP_WIDTH=timer_width(STOP_LAST);
    reg [3:0] state;
    reg [7:0] target_theme,target_image;
    reg task_live,loader_started,commit_live,commit_armed,stop_active,service_seen;
    reg [PHASE_WIDTH-1:0] phase_timer;
    reg [STOP_WIDTH-1:0] stop_timer;
    // Diagnostic aliases show the active phase count, NOT three retained
    // historical counts. Wires do not add counter storage.
    wire [31:0] prepare_timer=phase_timer,commit_timer=phase_timer,drain_timer=phase_timer;
    wire quiet=state==IDLE && !task_live && a_idle && !a_load_valid &&
               !pic_rsp_valid && !commit_live && !a_commit_req && !a_commit_ack && !pic_commit_ack;
    assign pic_idle=rst_sys_n && !recovery_req && quiet;
    assign pic_load_ready=pic_idle && service_ready && service_error==0 &&
        !resource_recovery_req && !a_recovery_req && !a_commit_error && !pic_stop_req && !stop_active;
    assign query_theme_id=target_theme;
    assign query_image_index=target_image;
    assign a_load_theme_id=target_theme;
    assign a_load_image_index=target_image;
    assign state_code=state;
    // An unaccepted published load must handshake BEFORE requesting its stop;
    // the existing A admission interface gates ready while stop is asserted.
    assign a_stop_req=rst_sys_n && !commit_live && !a_commit_req && !a_commit_ack &&
        !a_load_valid && (state==DRAIN || state==RECOVERY || (state==IDLE && pic_stop_req));
    wire a_fire=a_load_valid && a_load_ready;
    wire rsp_fire=pic_rsp_valid && pic_rsp_ready;
    wire preparing=state==QUERY || state==SEND || state==WAIT_PREPARED;
    wire phase_active=preparing || commit_live || state==DRAIN;
    wire [31:0] phase_last=preparing ? PREPARE_LAST : commit_live ? COMMIT_LAST : STOP_LAST;
    wire preparation_complete=state==WAIT_PREPARED && a_idle && a_prepared && !a_error_valid;
    wire commit_complete=state==ACK_LOW && !a_commit_ack;
    // A terminal handshake can make the task quiet ON this edge. Do not
    // require the following IDLE cycle when it is the last stop-budget edge.
    wire stop_finished=quiet || (state==RSP && rsp_fire && a_idle && !a_load_valid &&
        !commit_live && !a_commit_req && !a_commit_ack && !pic_commit_ack);
    wire global_fault=service_error!=0 || resource_recovery_req || a_recovery_req || a_commit_error ||
        ((service_seen || task_live) && !service_ready) || (!commit_live && a_commit_ack) ||
        (state==PREPARED && (!a_idle || !a_prepared)) ||
        (state==ACK_HIGH && !pic_commit_req) || (state==ACK_LOW && pic_commit_req) ||
        (commit_live && !commit_complete && (!a_prepared || a_error_valid));
    wire prepare_expired=preparing && prepare_timer>=PREPARE_LAST && !preparation_complete;
    wire commit_expired=commit_live && commit_timer>=COMMIT_LAST && !commit_complete;
    wire stop_expired=stop_active && stop_timer>=STOP_LAST && !stop_finished;
    wire drain_complete=state==DRAIN && !a_load_valid && a_idle && !a_prepared && !a_commit_ack;
    wire drain_expired=state==DRAIN && drain_timer>=STOP_LAST && !drain_complete;
    wire metadata_ok=query_image_resource_id=={4'd0,target_theme[1:0],target_image[1:0]} &&
        query_audio_resource_id==(8'h40 | target_theme) && query_text_resource_id==(8'h80 | target_theme) &&
        query_image_bytes>=32'd921654 && query_audio_bytes>=32'd44 &&
        query_text_bytes>=24 && query_text_bytes<=152 && !query_text_bytes[0] &&
        query_display_time_ms!=0 && font_set_id==FONT_SET_ID && glyph_count==GLYPH_COUNT &&
        GLYPH_COUNT>0 && GLYPH_COUNT<=512;
    wire loader_failure=loader_started && a_error_valid &&
        (state==WAIT_PREPARED || state==PREPARED);
    wire [2:0] normalized_error=(a_error_status==1 || a_error_status==2 || a_error_status==3 ||
        a_error_status==4 || a_error_status==6) ? a_error_status : 3'd6;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            state<=IDLE;target_theme<=0;target_image<=0;task_live<=0;loader_started<=0;
            commit_live<=0;commit_armed<=0;stop_active<=0;service_seen<=0;
            phase_timer<=0;stop_timer<=0;
            pic_prepared<=0;pic_commit_ack<=0;pic_rsp_valid<=0;pic_rsp_status<=0;pic_error_code<=0;
            current_theme_id<=0;current_image_index<=0;current_valid<=0;recovery_req<=0;
            a_load_valid<=0;a_load_resource_id<=0;a_load_text_resource_id<=0;
            a_load_file_bytes<=0;a_load_text_file_bytes<=0;a_load_font_set_id<=0;a_load_glyph_count<=0;
            task_display_time_ms<=0;a_commit_req<=0;
        end else begin
            if(service_ready) service_seen<=1;
            if(a_fire) begin a_load_valid<=0;loader_started<=1;end
            if(rsp_fire) begin pic_rsp_valid<=0;task_live<=0;end
            if(phase_active && phase_timer<phase_last) phase_timer<=phase_timer+1'b1;
            if(stop_finished) begin stop_active<=0;stop_timer<=0;end
            else if(!stop_active && pic_stop_req) begin stop_active<=1;stop_timer<=0;end
            else if(stop_active && stop_timer<STOP_LAST) stop_timer<=stop_timer+1'b1;

            if(state!=RECOVERY && (global_fault || prepare_expired || commit_expired || stop_expired || drain_expired ||
                    (commit_live && a_error_valid))) begin
                state<=RECOVERY;recovery_req<=1;current_valid<=0;
                // Published load, commit and response payloads survive faults
                // until their handshakes or the actual coordinated reset.
                if(!commit_live) pic_prepared<=0;
                if(task_live && !pic_rsp_valid && state!=COMPLETE) begin
                    pic_rsp_status<=global_fault ? 3'd5 : 3'd4;
                    pic_error_code<=global_fault ? 8'h20 :
                        prepare_expired ? 8'h11 : commit_expired ? 8'h12 : 8'h13;
                end
            end else if(state!=RECOVERY && !commit_live && task_live && state!=COMPLETE && state!=RSP && state!=DRAIN &&
                        (pic_stop_req || stop_active || loader_failure)) begin
                state<=DRAIN;pic_prepared<=0;commit_armed<=0;phase_timer<=0;
                if(loader_failure && !(pic_stop_req || stop_active)) begin
                    pic_rsp_status<=normalized_error;pic_error_code<=a_error_code;
                    if(normalized_error==4) begin state<=RECOVERY;recovery_req<=1;current_valid<=0;end
                end else begin pic_rsp_status<=3'd5;pic_error_code<=0;end
            end else case(state)
                IDLE: if(pic_load_valid && pic_load_ready) begin
                    target_theme<=pic_load_theme_id;target_image<=pic_load_image_index;
                    task_live<=1;loader_started<=0;commit_armed<=0;pic_prepared<=0;
                    phase_timer<=0;pic_rsp_status<=0;pic_error_code<=0;
                    if(pic_load_theme_id>=4 || pic_load_image_index>=4) begin
                        pic_rsp_status<=3'd1;pic_error_code<=8'h01;pic_rsp_valid<=1;state<=RSP;
                    end else state<=QUERY;
                end
                QUERY: if(query_valid) begin
                    if(!metadata_ok) begin
                        pic_rsp_status<=3'd6;pic_error_code<=8'h10;pic_rsp_valid<=1;state<=RSP;
                    end else begin
                        a_load_resource_id<=query_image_resource_id;a_load_text_resource_id<=query_text_resource_id;
                        a_load_file_bytes<=query_image_bytes;a_load_text_file_bytes<=query_text_bytes;
                        a_load_font_set_id<=font_set_id;a_load_glyph_count<=glyph_count[15:0];
                        task_display_time_ms<=query_display_time_ms;a_load_valid<=1;state<=SEND;
                    end
                end
                SEND: if(a_fire) state<=WAIT_PREPARED;
                WAIT_PREPARED: if(preparation_complete) begin
                    pic_prepared<=1;commit_armed<=!pic_commit_req;state<=PREPARED;
                end
                PREPARED: begin
                    if(!pic_commit_req) commit_armed<=1;
                    if(pic_commit_req && commit_armed) begin
                        a_commit_req<=1;commit_live<=1;phase_timer<=0;state<=ACK_HIGH;
                    end
                end
                ACK_HIGH: if(a_commit_ack) begin
                    // Only the real A safe-frame acknowledgement changes the
                    // visible identity. No update on load or prepared.
                    current_theme_id<=target_theme;current_image_index<=target_image;current_valid<=1;
                    pic_commit_ack<=1;state<=REQ_LOW;
                end
                REQ_LOW: if(!a_commit_ack) begin
                        state<=RECOVERY;recovery_req<=1;current_valid<=0;
                        pic_rsp_status<=5;pic_error_code<=8'h21;
                    end else if(!pic_commit_req) begin a_commit_req<=0;state<=ACK_LOW;end
                ACK_LOW: if(!a_commit_ack) begin
                    pic_commit_ack<=0;pic_prepared<=0;commit_live<=0;
                    pic_rsp_status<=0;pic_error_code<=0;state<=COMPLETE;
                end
                COMPLETE: begin pic_rsp_status<=0;pic_error_code<=0;pic_rsp_valid<=1;state<=RSP;end
                DRAIN: if(drain_complete) begin
                    pic_rsp_valid<=1;state<=RSP;
                end
                RSP: if(rsp_fire) begin loader_started<=0;state<=IDLE;end
                RECOVERY: begin
                    // No invented cancellation/idle for an in-flight commit.
                    // A stuck endpoint requires real system reset. A drained
                    // pre-commit task may report its fault while reset is pending.
                    if(task_live && !pic_rsp_valid && !rsp_fire && !commit_live &&
                       !a_load_valid && a_idle && !a_prepared && !a_commit_ack) pic_rsp_valid<=1;
                end
                default: begin state<=RECOVERY;recovery_req<=1;current_valid<=0;end
            endcase
        end
    end
endmodule
