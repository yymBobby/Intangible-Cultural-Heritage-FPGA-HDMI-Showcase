`timescale 1ns/1ps
// SYS-domain task controller. One frozen catalogue record owns both loads.
// Request/response byte streams go directly between the service and A/B.
// Recovery requests must reach an external, independently held reset manager.
module theme_controller #(
    parameter integer SYS_CLK_HZ=100000000,
    parameter integer AUTO_ENABLE=0,
    parameter [31:0] INIT_TIMEOUT_CYCLES=500000000,
    parameter [31:0] STOP_TIMEOUT_CYCLES=100000000,
    parameter [31:0] LOAD_TIMEOUT_CYCLES=100000000,
    parameter [31:0] PREPARE_TIMEOUT_CYCLES=500000000,
    parameter [31:0] COMMIT_TIMEOUT_CYCLES=10000000
) (
    input wire clk_sys,rst_sys_n,
    input wire ctl_valid,
    output wire ctl_ready,
    input wire [1:0] ctl_op,
    input wire [7:0] ctl_theme_id,
    input wire service_ready,
    input wire [7:0] service_error,
    input wire resource_recovery_req,
    input wire [4:0] catalog_theme_count,
    output wire [3:0] query_theme_id,
    input wire query_valid,
    input wire [7:0] query_flags,
    input wire [31:0] query_display_time_ms,query_image_bytes,query_audio_bytes,query_text_bytes,
    input wire [31:0] font_set_id,glyph_count,
    output reg img_load_valid,
    input wire img_load_ready,
    output wire [7:0] img_load_theme_id,img_load_resource_id,img_load_text_resource_id,
    output reg [31:0] img_load_file_bytes,img_load_text_file_bytes,img_load_font_set_id,
    output reg [15:0] img_load_glyph_count,
    output wire img_stop_req,
    input wire img_idle,img_prepared,img_error,
    input wire [7:0] img_error_code,
    input wire img_recovery_needed,
    output reg aud_load_valid,
    input wire aud_load_ready,
    output wire [7:0] aud_load_theme_id,aud_load_resource_id,
    output reg [31:0] aud_load_file_bytes,
    output wire aud_stop_req,
    input wire aud_idle,aud_prepared,aud_error,
    input wire [7:0] aud_error_code,
    output reg video_commit_req,
    input wire video_commit_ack,video_commit_error_sys,video_recovery_needed_sys,
    output wire audio_play_enable,
    input wire audio_ended,audio_underflow,
    output reg recovery_req,
    // Diagnostics, all SYS. Codes belong to this controller, not A/B code space.
    output wire [3:0] state_code,
    output reg [7:0] active_theme_id,
    output reg active_theme_valid,audio_muted,auto_enabled,
    output reg [7:0] controller_error_code,
    output reg [31:0] display_elapsed_ms,
    output reg underflow_seen
);
    localparam [3:0] WAIT_SERVICE=0,SELECT=1,QUERY=2,STOP=3,GAP=4,
        LOAD=5,PREPARE=6,AUD_CLEAN=7,COMMIT_REQ=8,COMMIT_RELEASE=9,
        PLAY=10,FAIL_CLEAN=11,HOLD=12,RECOVERY=13;
    localparam integer MS_TICKS=SYS_CLK_HZ<1000 ? 1:SYS_CLK_HZ/1000;
    localparam integer MS_WIDTH=MS_TICKS<=1 ? 1:$clog2(MS_TICKS);
    reg [3:0] state,previous_state;
    reg [7:0] task_theme,pending_theme;
    reg pending_valid,boot_pending,task_has_audio;
    reg img_started,aud_started,aud_cleaned,aud_cleanup_to_play,service_seen;
    reg [31:0] task_display_ms,active_display_ms,wait_timer;
    reg [MS_WIDTH-1:0] ms_divider;
    wire ctl_fire=ctl_valid && ctl_ready;
    wire img_fire=img_load_valid && img_load_ready;
    wire aud_fire=aud_load_valid && aud_load_ready;
    wire count_valid=catalog_theme_count>=1 && catalog_theme_count<=16;
    wire img_fault=img_started && img_error;
    wire aud_fault=aud_started && !aud_cleaned && aud_error;
    wire commit_live=state==COMMIT_REQ || state==COMMIT_RELEASE;
    wire [7:0] command_base=pending_valid ? pending_theme:task_theme;
    wire [7:0] command_theme=ctl_op==0 ? ctl_theme_id:
        ctl_op==1 ? (command_base+1>=catalog_theme_count ? 8'd0:command_base+1'b1):
        (command_base==0 ? {3'd0,catalog_theme_count}-1'b1:command_base-1'b1);
    wire valid_selection=ctl_fire && ctl_op!=3 && command_theme<catalog_theme_count;
    wire metadata_valid=query_valid && (query_flags==8'd5 || query_flags==8'd7) &&
        query_image_bytes>=921654 && query_text_bytes>=24 && query_text_bytes<=152 &&
        !query_text_bytes[0] && glyph_count>=1 && glyph_count<=512 &&
        (query_flags[1] ? query_audio_bytes>=12:query_audio_bytes==0);
    assign ctl_ready=rst_sys_n && service_ready && service_error==0 &&
        count_valid && !recovery_req;
    assign query_theme_id=task_theme[3:0];
    assign img_load_theme_id=task_theme;
    assign img_load_resource_id={task_theme[6:0],1'b0};
    assign img_load_text_resource_id=8'h80+task_theme;
    assign aud_load_theme_id=task_theme;
    assign aud_load_resource_id={task_theme[6:0],1'b1};
    assign state_code=state;
    assign img_stop_req=state==STOP || state==FAIL_CLEAN ||
        (state==RECOVERY && !video_commit_req && !video_commit_ack);
    assign aud_stop_req=img_stop_req || state==AUD_CLEAN;
    assign audio_play_enable=state==PLAY && aud_started && !audio_muted &&
        !aud_error && !audio_ended && !pending_valid && !recovery_req &&
        service_ready && service_error==0;

    reg [31:0] wait_limit;
    always @* begin
        case(state)
            WAIT_SERVICE:wait_limit=INIT_TIMEOUT_CYCLES==0 ? 1:INIT_TIMEOUT_CYCLES;
            QUERY,LOAD:wait_limit=LOAD_TIMEOUT_CYCLES==0 ? 1:LOAD_TIMEOUT_CYCLES;
            STOP,FAIL_CLEAN,AUD_CLEAN:wait_limit=STOP_TIMEOUT_CYCLES==0 ? 1:STOP_TIMEOUT_CYCLES;
            PREPARE:wait_limit=PREPARE_TIMEOUT_CYCLES==0 ? 1:PREPARE_TIMEOUT_CYCLES;
            COMMIT_REQ,COMMIT_RELEASE:wait_limit=COMMIT_TIMEOUT_CYCLES==0 ? 1:COMMIT_TIMEOUT_CYCLES;
            default:wait_limit=0;
        endcase
    end
    // Entry cycle is uncounted. A complete commit shares one budget including
    // ack release; a new state gets a fresh phase budget, never a wrapping timer.
    wire same_budget=state==previous_state ||
        (state==COMMIT_RELEASE && previous_state==COMMIT_REQ);
    wire expired=wait_limit!=0 && same_budget && wait_timer>=wait_limit-1;
    wire global_fault=service_error!=0 || resource_recovery_req ||
        img_recovery_needed || video_commit_error_sys || video_recovery_needed_sys ||
        (service_seen && !service_ready) || (aud_fault && aud_error_code==5);
    wire ack_event=state==COMMIT_REQ && video_commit_ack && !global_fault && !img_fault;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            state<=WAIT_SERVICE;previous_state<=WAIT_SERVICE;wait_timer<=0;
            task_theme<=0;pending_theme<=0;pending_valid<=0;boot_pending<=1;
            task_has_audio<=0;task_display_ms<=0;active_display_ms<=0;
            img_started<=0;aud_started<=0;aud_cleaned<=0;aud_cleanup_to_play<=0;
            img_load_valid<=0;aud_load_valid<=0;video_commit_req<=0;
            img_load_file_bytes<=0;img_load_text_file_bytes<=0;img_load_font_set_id<=0;
            img_load_glyph_count<=0;aud_load_file_bytes<=0;service_seen<=0;
            recovery_req<=0;controller_error_code<=0;active_theme_id<=0;
            active_theme_valid<=0;audio_muted<=1;auto_enabled<=AUTO_ENABLE!=0;
            display_elapsed_ms<=0;ms_divider<=0;underflow_seen<=0;
        end else begin
            previous_state<=state;
            if(wait_limit==0 || !same_budget) wait_timer<=0;
            else if(wait_timer<wait_limit) wait_timer<=wait_timer+1'b1;
            if(service_ready) service_seen<=1;
            if(img_fire) begin img_load_valid<=0;img_started<=1;end
            if(aud_fire) begin aud_load_valid<=0;aud_started<=1;underflow_seen<=0;end
            if(aud_started && audio_underflow) underflow_seen<=1;
            if(aud_fault) begin
                audio_muted<=1;
                if(controller_error_code==0) controller_error_code<=8'h21;
            end

            if(ack_event) begin
                active_theme_id<=task_theme;active_theme_valid<=1;
                active_display_ms<=task_display_ms;display_elapsed_ms<=0;ms_divider<=0;
            end else if(active_theme_valid && active_display_ms!=0 && display_elapsed_ms<active_display_ms) begin
                if(ms_divider==MS_TICKS-1) begin ms_divider<=0;display_elapsed_ms<=display_elapsed_ms+1'b1;end
                else ms_divider<=ms_divider+1'b1;
            end

            if(state!=RECOVERY) begin
                if(global_fault || (commit_live && img_fault) ||
                    (!commit_live && video_commit_ack)) begin
                    state<=RECOVERY;recovery_req<=1;audio_muted<=1;
                    if(controller_error_code==0) controller_error_code<=8'h16;
                    // Keep already-published load/commit requests until actual
                    // coordinated reset. A recovery flag alone cancels nothing.
                end else if(expired) begin
                    state<=RECOVERY;recovery_req<=1;audio_muted<=1;
                    if(controller_error_code==0) controller_error_code<=
                        state==WAIT_SERVICE ? 8'h10:
                        (state==STOP || state==FAIL_CLEAN || state==AUD_CLEAN) ? 8'h13:
                        state==PREPARE ? 8'h14:commit_live ? 8'h15:8'h12;
                end else case(state)
                    WAIT_SERVICE: if(service_ready && count_valid) state<=SELECT;
                    SELECT: if(pending_valid || boot_pending) begin
                        task_theme<=pending_valid ? pending_theme:8'd0;
                        pending_valid<=0;boot_pending<=0;state<=QUERY;
                    end else state<=HOLD;
                    // The catalog queries its synchronous index BRAM. Keep
                    // task_theme frozen and wait for the complete matching ID.
                    QUERY: if(query_valid) begin
                        if(metadata_valid) begin
                            img_load_file_bytes<=query_image_bytes;
                            img_load_text_file_bytes<=query_text_bytes;
                            img_load_font_set_id<=font_set_id;img_load_glyph_count<=glyph_count[15:0];
                            aud_load_file_bytes<=query_audio_bytes;task_has_audio<=query_flags[1];
                            task_display_ms<=query_display_time_ms;controller_error_code<=0;
                            state<=STOP;
                        end else begin controller_error_code<=8'h11;state<=FAIL_CLEAN;end
                    end
                    STOP: if(img_idle && aud_idle) begin
                        state<=GAP;img_started<=0;aud_started<=0;aud_cleaned<=0;
                    end
                    GAP: begin
                        if(pending_valid) state<=SELECT;
                        else begin
                            audio_muted<=!task_has_audio;underflow_seen<=0;
                            img_load_valid<=1;aud_load_valid<=task_has_audio;state<=LOAD;
                        end
                    end
                    LOAD: begin
                        // Even if a new command/error arrives, finish both
                        // published load handshakes before ordinary stopping.
                        if((img_started || img_fire) && (!task_has_audio || aud_started || aud_fire)) state<=PREPARE;
                    end
                    PREPARE: begin
                        if(pending_valid) state<=STOP;
                        else if(img_fault) begin controller_error_code<=8'h20;state<=FAIL_CLEAN;end
                        else if(aud_fault) begin
                            controller_error_code<=8'h21;aud_cleanup_to_play<=0;state<=AUD_CLEAN;
                        end else if(img_prepared && img_started &&
                            (!task_has_audio || (audio_muted && aud_cleaned) || (aud_started && aud_prepared))) begin
                            video_commit_req<=1;state<=COMMIT_REQ;
                        end
                    end
                    AUD_CLEAN: if(aud_idle) begin
                        aud_cleaned<=1;audio_muted<=1;
                        if(pending_valid) state<=STOP;
                        else if(img_fault) begin controller_error_code<=8'h20;state<=FAIL_CLEAN;end
                        else state<=aud_cleanup_to_play ? PLAY:PREPARE;
                    end
                    COMMIT_REQ: if(video_commit_ack) begin video_commit_req<=0;state<=COMMIT_RELEASE;end
                    COMMIT_RELEASE: if(!video_commit_ack) begin
                        if(pending_valid) state<=STOP;
                        else if(aud_fault) begin aud_cleanup_to_play<=1;state<=AUD_CLEAN;end
                        else state<=PLAY;
                    end
                    PLAY: begin
                        if(pending_valid) state<=SELECT;
                        else if(img_fault) begin controller_error_code<=8'h20;state<=FAIL_CLEAN;end
                        else if(aud_fault) begin
                            controller_error_code<=8'h21;aud_cleanup_to_play<=1;state<=AUD_CLEAN;
                        end else if(auto_enabled && !(ctl_fire && ctl_op==3) &&
                            active_display_ms!=0 && display_elapsed_ms>=active_display_ms) begin
                            pending_theme<=active_theme_id+1>=catalog_theme_count ? 8'd0:active_theme_id+1'b1;
                            pending_valid<=1;state<=SELECT;
                        end
                    end
                    FAIL_CLEAN: if(img_idle && aud_idle) begin
                        img_started<=0;aud_started<=0;aud_cleaned<=1;audio_muted<=1;state<=HOLD;
                    end
                    HOLD: if(pending_valid) state<=SELECT;
                    default: begin state<=RECOVERY;recovery_req<=1;controller_error_code<=8'h1f;end
                endcase
            end

            // Latest accepted command wins, including a command arriving on
            // the same edge SELECT consumes an older pending target.
            if(ctl_fire) begin
                if(ctl_op==3) auto_enabled<=!auto_enabled;
                else if(valid_selection) begin pending_theme<=command_theme;pending_valid<=1;end
            end
        end
    end
endmodule
