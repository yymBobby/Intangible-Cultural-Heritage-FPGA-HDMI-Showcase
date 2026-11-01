`timescale 1ns/1ps
// SYS-only upper scheduler. C owns picture preparation/commit; B owns PCM.
// Published requests survive backpressure. Board mode queues all accepted browse commands in order.
module resource_v3_runtime #(
    parameter integer SYS_CLK_HZ=40000000,
    parameter integer ORDERED_BROWSE=0,
    parameter integer BROWSE_INTERVAL_CYCLES=(SYS_CLK_HZ/1000)*150,
    parameter integer MENU_DWELL_CONTROL=0,
    parameter integer AUDIO_TIMEOUT_CYCLES=200000000
) (
    input wire clk_sys,rst_sys_n,service_ready,
    input wire [7:0] service_error,
    input wire resource_recovery_req,
    input wire ctl_valid, output wire ctl_ready,
    input wire [1:0] ctl_op, input wire [7:0] ctl_theme_id,
    input wire image_next,image_prev,theme_next,theme_prev,music_toggle,auto_toggle,
    input wire auto_config,menu_open,pause_playback,
    input wire [1:0] dwell_level,input wire restore_defaults_sys,
    output wire pic_load_valid, input wire pic_load_ready,
    output wire [7:0] pic_load_theme_id,pic_load_image_index,
    input wire pic_prepared,pic_idle,pic_commit_ack,pic_rsp_valid,
    output wire pic_commit_req,pic_stop_req,pic_rsp_ready,
    input wire [2:0] pic_rsp_status, input wire [7:0] pic_error_code,
    input wire pic_recovery_req,current_valid,
    input wire [7:0] current_theme_id,current_image_index,
    input wire metadata_valid,
    input wire [7:0] metadata_audio_id,
    input wire [31:0] metadata_audio_bytes,metadata_dwell_ms,
    output wire aud_load_valid, input wire aud_load_ready,
    output wire [7:0] aud_load_theme_id,aud_load_resource_id,
    output wire [31:0] aud_load_file_bytes,
    output wire aud_stop_req, input wire aud_idle,aud_prepared,aud_error,audio_ended,audio_underflow,
    input wire [7:0] aud_error_code,
    output wire audio_play_enable,audio_muted,auto_enabled,
    output reg theme_commit_pulse,recovery_req,underflow_seen,
    output reg [7:0] controller_error_code,
    output wire [31:0] display_elapsed_ms,
    output wire background_enable,
    input wire browse_safe_sys,
    output wire browse_full_sys,browse_overflow_sys,
    output reg [1:0] transition_speed_sys,
    output wire [3:0] state_code
);
    localparam [3:0] WAIT_SERVICE=0,IDLE=1,ISSUE=2,PREPARE=3,
        COMMIT_HIGH=4,COMMIT_LOW=5,RESPONSE=6,CANCEL=7,FAULT=8;
    localparam [2:0] A_STOP=0,A_GAP=1,A_OFF=2,A_LOAD=3,A_WAIT=4,A_READY=5;
    localparam integer MS_CYCLES=SYS_CLK_HZ/1000>0 ? SYS_CLK_HZ/1000:1;
    localparam integer MS_WIDTH=MS_CYCLES>1 ? $clog2(MS_CYCLES):1;
    localparam integer A_LIMIT=AUDIO_TIMEOUT_CYCLES>0 ? AUDIO_TIMEOUT_CYCLES:1;
    localparam integer A_WIDTH=A_LIMIT>1 ? $clog2(A_LIMIT):1;
    // The menu maximum is 30000 ms. Retain full metadata width in legacy mode.
    localparam integer ELAPSED_WIDTH=MENU_DWELL_CONTROL ? 15:32;
    reg [3:0] state;
    reg [2:0] audio_state;
    reg [1:0] desired_theme,desired_image,target_theme,target_image,audio_theme;
    reg pending,music_requested,slideshow_paused,audio_meta,audio_committed,audio_failed;
    reg restart_pending;
    reg [7:0] audio_id,published_audio_id;
    reg [1:0] published_audio_theme;
    reg [31:0] published_audio_bytes;
    reg [31:0] audio_bytes,dwell_ms,task_dwell_ms;
    reg [MS_WIDTH-1:0] ms_counter;
    reg [A_WIDTH-1:0] audio_timer;
    reg [ELAPSED_WIDTH-1:0] elapsed_ms;
    assign display_elapsed_ms={{(32-ELAPSED_WIDTH){1'b0}},elapsed_ms};
    reg [1:0] last_dwell_level;
    reg [15:0] menu_dwell_ms;
    always @* case(dwell_level)
        0:menu_dwell_ms=16'd5000;
        1:menu_dwell_ms=16'd10000;
        2:menu_dwell_ms=16'd20000;
        default:menu_dwell_ms=16'd30000;
    endcase
    wire [31:0] effective_dwell_ms=MENU_DWELL_CONTROL ? {16'd0,menu_dwell_ms}:dwell_ms;
    wire dwell_changed=MENU_DWELL_CONTROL && dwell_level!=last_dwell_level;
    assign state_code=state;
    wire queue_ready,queue_inflight,queue_fire,queue_finish;
    wire [3:0] queue_head;wire [3:0] queue_count;
    assign ctl_ready=service_ready && service_error==0 && !recovery_req && !resource_recovery_req &&
        (!ORDERED_BROWSE || ctl_op==3 || queue_ready);
    wire command=ctl_valid && ctl_ready;
    wire raw_select=command && ctl_op==0 && ctl_theme_id<4;
    wire raw_next_theme=theme_next || (command && ctl_op==1);
    wire raw_prev_theme=theme_prev || (command && ctl_op==2);
    wire raw_manual=raw_select || raw_next_theme || raw_prev_theme || image_next || image_prev;
    wire [3:0] raw_code=raw_select ? {2'b01,ctl_theme_id[1:0]}:
        raw_next_theme ? 4'd2:raw_prev_theme ? 4'd3:image_next ? 4'd0:4'd1;
    wire valid_select=ORDERED_BROWSE ? queue_fire && queue_head[3:2]==1:raw_select;
    wire [1:0] selected_theme=ORDERED_BROWSE ? queue_head[1:0]:ctl_theme_id[1:0];
    wire next_theme=ORDERED_BROWSE ? queue_fire && queue_head==2:raw_next_theme;
    wire prev_theme=ORDERED_BROWSE ? queue_fire && queue_head==3:raw_prev_theme;
    wire select_image_next=ORDERED_BROWSE ? queue_fire && queue_head==0:image_next;
    wire select_image_prev=ORDERED_BROWSE ? queue_fire && queue_head==1:image_prev;
    wire manual_select=valid_select || next_theme || prev_theme || select_image_next || select_image_prev;
    wire toggle_auto=auto_toggle || (command && ctl_op==3);
    assign auto_enabled=auto_config && !slideshow_paused;
    wire auto_due=auto_enabled && !menu_open && state==IDLE && !pending && current_valid &&
        !dwell_changed && !restore_defaults_sys && (!ORDERED_BROWSE || (queue_count==0 && !browse_full_sys && !raw_manual)) && display_elapsed_ms>=effective_dwell_ms;
    assign background_enable=state==IDLE && !pending && !manual_select && current_valid && !recovery_req && (!ORDERED_BROWSE || (queue_count==0 && !browse_full_sys));
    wire launch=state==IDLE && pending && pic_idle && service_ready && !manual_select;
    // A cancelled cross-theme prepare may have already replaced the WAV.
    // Returning to the visible theme must restore its audio context as well.
    wire cross_launch=launch && (!current_valid || {6'd0,desired_theme}!=current_theme_id ||
        desired_theme!=audio_theme);
    assign queue_fire=ORDERED_BROWSE && queue_count!=0 && !queue_inflight &&
        state==IDLE && !pending && pic_idle && service_ready && browse_safe_sys;
    assign queue_finish=queue_inflight && ((state==RESPONSE && pic_rsp_valid) ||
        (state==PREPARE && pic_rsp_valid));
    generate if(ORDERED_BROWSE) begin: ordered
        browse_command_queue #(.MIN_INTERVAL_CYCLES(BROWSE_INTERVAL_CYCLES)) queue(.clk(clk_sys),.rst_n(rst_sys_n),
            .push(raw_manual && service_ready && !recovery_req),.command(raw_code),
            .ready(queue_ready),.head(queue_head),.count(queue_count),
            .start(queue_fire),.finish(queue_finish),.inflight(queue_inflight),
            .resume(state==IDLE && !pending && pic_idle && browse_safe_sys),
            .full(browse_full_sys),.overflow(browse_overflow_sys));
    end else begin: legacy
        assign queue_ready=1'b1;assign queue_head=4'd0;assign queue_count=4'd0;
        assign queue_inflight=1'b0;assign browse_full_sys=1'b0;assign browse_overflow_sys=1'b0;
    end endgenerate
    wire metadata_fire=metadata_valid && state==PREPARE;
    // EOF loops only the committed current theme. Pause/stop inhibit loops;
    // manual stop has priority even when it coincides with the EOF boundary.
    wire music_restart=music_toggle && !music_requested;
    wire music_loop=audio_ended && music_requested && !pause_playback &&
        !music_toggle && audio_state==A_READY && audio_committed && current_valid &&
        {6'd0,audio_theme}==current_theme_id;
    wire restart_audio=cross_launch || music_restart || music_loop;
    assign pic_load_valid=state==ISSUE;
    assign pic_load_theme_id={6'd0,target_theme};
    assign pic_load_image_index={6'd0,target_image};
    assign pic_commit_req=state==COMMIT_HIGH;
    assign pic_stop_req=state==CANCEL;
    assign pic_rsp_ready=1'b1;
    assign aud_load_valid=audio_state==A_LOAD;
    assign aud_load_theme_id={6'd0,published_audio_theme};
    assign aud_load_resource_id=published_audio_id;
    assign aud_load_file_bytes=published_audio_bytes;
    // Do not assert stop while an unaccepted load is published (ready gates stop).
    assign aud_stop_req=audio_state==A_STOP;
    wire audio_error_live=aud_error && (audio_state==A_WAIT || audio_state==A_READY);
    assign audio_play_enable=audio_state==A_READY && music_requested && audio_committed &&
        !pause_playback && !audio_error_live && !restart_audio;
    assign audio_muted=!audio_play_enable;
    wire audio_available=!music_requested || audio_failed ||
        (audio_state==A_READY && aud_prepared && audio_theme==target_theme);
    wire success=state==RESPONSE && pic_rsp_valid && pic_rsp_status==0;
    wire audio_timed_phase=audio_state==A_STOP || audio_state==A_LOAD || audio_state==A_WAIT;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            state<=WAIT_SERVICE;audio_state<=A_STOP;
            desired_theme<=0;desired_image<=0;target_theme<=0;target_image<=0;audio_theme<=0;
            pending<=1;music_requested<=1;slideshow_paused<=0;restart_pending<=0;
            audio_meta<=0;audio_committed<=0;audio_failed<=0;audio_id<=0;audio_bytes<=0;
            published_audio_id<=0;published_audio_theme<=0;published_audio_bytes<=0;
            dwell_ms<=30000;task_dwell_ms<=30000;ms_counter<=0;audio_timer<=0;
            theme_commit_pulse<=0;recovery_req<=0;underflow_seen<=0;
            controller_error_code<=0;elapsed_ms<=0;
            last_dwell_level<=1;transition_speed_sys<=0;
        end else begin
            last_dwell_level<=dwell_level;
            // Lock the speed on the edge that publishes this commit. Count
            // includes the command in flight. Never change speed mid-animation.
            if(ORDERED_BROWSE && state==PREPARE && pic_prepared && audio_available)
                transition_speed_sys<=queue_count>=5 ? 2'd1:2'd0;
            theme_commit_pulse<=0;
            if(audio_underflow) underflow_seen<=1;
            if(restore_defaults_sys || !auto_config) slideshow_paused<=0;
            else if(toggle_auto) slideshow_paused<=!slideshow_paused;
            if(music_toggle) music_requested<=music_restart ? 1'b1:1'b0;
            if(command && ctl_op==0 && ctl_theme_id>=4) controller_error_code<=8'h01;
            if(manual_select) begin
                pending<=1;
                if(valid_select) begin desired_theme<=selected_theme;desired_image<=0;end
                else if(next_theme) begin desired_theme<=(ORDERED_BROWSE ? current_theme_id[1:0]:desired_theme)+2'd1;desired_image<=0;end
                else if(prev_theme) begin desired_theme<=(ORDERED_BROWSE ? current_theme_id[1:0]:desired_theme)-2'd1;desired_image<=0;end
                else if(select_image_next) begin
                    if(ORDERED_BROWSE)desired_theme<=current_theme_id[1:0];
                    desired_image<=(ORDERED_BROWSE ? current_image_index[1:0]:desired_image)+2'd1;
                end else if(select_image_prev) begin
                    if(ORDERED_BROWSE)desired_theme<=current_theme_id[1:0];
                    desired_image<=(ORDERED_BROWSE ? current_image_index[1:0]:desired_image)-2'd1;
                end
            end else if(auto_due) begin
                pending<=1;desired_theme<=current_theme_id[1:0];desired_image<=current_image_index[1:0]+1'b1;
            end
            if(menu_open || raw_manual || manual_select || success || !auto_enabled || !current_valid || dwell_changed || restore_defaults_sys) begin
                ms_counter<=0;elapsed_ms<=0;
            end else if(ms_counter==MS_CYCLES-1) begin
                ms_counter<=0;
                if(display_elapsed_ms<effective_dwell_ms) elapsed_ms<=elapsed_ms+1'b1;
            end else ms_counter<=ms_counter+1'b1;
            if(metadata_fire) begin
                task_dwell_ms<=metadata_dwell_ms;
                // Same-theme pictures keep the existing WAV/FIFO and its position.
                if(audio_theme==target_theme) begin
                    audio_meta<=1;audio_id<=metadata_audio_id;audio_bytes<=metadata_audio_bytes;
                end
            end
            if(cross_launch) begin
                audio_theme<=desired_theme;audio_meta<=0;audio_committed<=0;audio_failed<=0;
            end
            if(success) begin
                dwell_ms<=task_dwell_ms;audio_committed<=1;
                theme_commit_pulse<=1;controller_error_code<=0;
            end
            if(restart_audio) restart_pending<=1;
            if(audio_timed_phase) begin
                if(audio_timer<A_LIMIT-1) audio_timer<=audio_timer+1'b1;
                else begin recovery_req<=1;controller_error_code<=8'h31;end
            end else audio_timer<=0;
            case(audio_state)
                A_STOP: if(aud_idle) begin audio_state<=A_GAP;audio_timer<=0;restart_pending<=0;end
                A_GAP: audio_state<=A_OFF;
                A_OFF: if(music_requested && audio_meta && !audio_failed && !restart_pending && !restart_audio) begin
                    audio_state<=A_LOAD;audio_timer<=0;
                    published_audio_theme<=audio_theme;published_audio_id<=audio_id;published_audio_bytes<=audio_bytes;
                end
                A_LOAD: if(aud_load_ready) begin
                    audio_state<=(!music_requested || restart_pending || restart_audio) ? A_STOP:A_WAIT;
                    audio_timer<=0;
                end
                A_WAIT: if(!music_requested || restart_pending || restart_audio) begin audio_state<=A_STOP;audio_timer<=0;end
                    else if(aud_error) begin audio_failed<=1;audio_state<=A_STOP;audio_timer<=0;controller_error_code<=aud_error_code;end
                    else if(aud_prepared) begin audio_state<=A_READY;audio_timer<=0;end
                A_READY: if(!music_requested || restart_pending || restart_audio || aud_error) begin
                    audio_state<=A_STOP;audio_timer<=0;
                    if(aud_error) begin audio_failed<=1;controller_error_code<=aud_error_code;end
                end
                default: begin audio_state<=A_STOP;audio_timer<=0;end
            endcase
            // A_OFF/A_GAP also consume restarts, never deadlock on a stale flag.
            if((audio_state==A_OFF || audio_state==A_GAP) && (restart_pending || restart_audio)) begin
                audio_state<=A_STOP;audio_timer<=0;
                if(music_restart) audio_failed<=0;
            end
            if(service_error!=0 || resource_recovery_req || pic_recovery_req) begin
                recovery_req<=1;controller_error_code<=8'h30;
            end
            case(state)
                WAIT_SERVICE: if(service_ready) state<=IDLE;
                IDLE: if(launch) begin
                    target_theme<=desired_theme;target_image<=desired_image;pending<=0;state<=ISSUE;
                end
                ISSUE: if(pic_load_ready) state<=PREPARE;
                PREPARE: if(pending || manual_select) state<=CANCEL;
                    else if(pic_rsp_valid) begin controller_error_code<=pic_error_code;state<=IDLE;end
                    else if(pic_prepared && audio_available) state<=COMMIT_HIGH;
                COMMIT_HIGH: if(pic_commit_ack) state<=COMMIT_LOW;
                COMMIT_LOW: if(!pic_commit_ack) state<=RESPONSE;
                RESPONSE: if(pic_rsp_valid) begin
                    if(pic_rsp_status!=0) controller_error_code<=pic_error_code;
                    state<=IDLE;
                end
                CANCEL: if(pic_idle) state<=IDLE;
                FAULT: ;
                default: begin state<=FAULT;recovery_req<=1;end
            endcase
            // A fault does not retract published ISSUE/COMMIT payloads. The
            // coordinated reset manager is the authority for recovery.
        end
    end
endmodule

// Eight accepted commands, INCLUDING the active head until its real response.
// Async reset of packed entries forces a small register implementation, no BRAM.
module browse_command_queue #(parameter integer MIN_INTERVAL_CYCLES=6000000)(
    input wire clk,rst_n,push,input wire [3:0] command,
    output wire ready,output wire [3:0] head,output reg [3:0] count,
    input wire start,finish,resume,output reg inflight,output wire full,output reg overflow);
    localparam integer INTERVAL=MIN_INTERVAL_CYCLES>0 ? MIN_INTERVAL_CYCLES:1;
    localparam integer TIMER_WIDTH=INTERVAL>1 ? $clog2(INTERVAL):1;
    reg [TIMER_WIDTH-1:0] cooldown;
    reg [31:0] entries;reg [2:0] read_pointer,write_pointer;
    reg blocked;
    wire pop=finish && inflight;
    // Reaching eight locks admission until EVERY command finishes and the
    // video guard allows resume. Freeing a single slot never reopens admission.
    assign full=blocked || count==8;
    assign ready=!full && cooldown==0;
    wire accept=push && ready;
    assign head=entries[{read_pointer,2'b00} +: 4];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin entries<=0;read_pointer<=0;write_pointer<=0;count<=0;inflight<=0;overflow<=0;blocked<=0;cooldown<=0;end
        else begin
            // Reset ONLY on acceptance; rapid rejected notches do not prolong
            // cooldown. First input is immediate, exact 150ms is admissible.
            if(accept)cooldown<=INTERVAL-1;
            else if(cooldown!=0)cooldown<=cooldown-1'b1;
            if(accept)begin entries[{write_pointer,2'b00} +: 4]<=command;write_pointer<=write_pointer+1'b1;end
            if(pop)begin read_pointer<=read_pointer+1'b1;inflight<=0;end
            else if(start && count!=0 && !inflight)inflight<=1;
            case({accept,pop}) 2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
            if(accept && !pop && count==7)blocked<=1;
            else if(count==0 && resume)blocked<=0;
            if(push && full)overflow<=1;
            else if(count==0 && resume)overflow<=0;
        end
    end
endmodule
