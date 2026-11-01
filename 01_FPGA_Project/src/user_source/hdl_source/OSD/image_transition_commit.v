`timescale 1ns/1ps
// Wrap the existing verified four-phase frame/text commit. The old commit
// runs only after the animation has reached its safe endpoint. Descriptor,
// mode and direction are held throughout the SYS<->PIX handshake.
module image_transition_commit #(parameter integer ADAPTIVE_SPEED=0)(
    input wire clk_sys,rst_sys_n,clk_pix,rst_pix_n,
    input wire request_sys,inner_ack_sys,
    input wire [1:0] menu_mode_sys,
    input wire [1:0] speed_sys,
    input wire target_cached_sys,current_valid_sys,
    input wire [2:0] target_slot_sys,
    input wire backwards_sys,
    output wire inner_request_sys,ack_sys,busy_sys,
    input wire frame_start_pix,safe_window_pix,stage_start_allowed_pix,
    input wire second_ready_pix,second_applied_pix,second_drained_pix,
    output reg second_request_pix,
    output reg [2:0] second_slot_pix,
    output wire second_apply_pix,
    output reg [1:0] effect_pix,
    output reg [8:0] alpha_pix,
    output reg [9:0] shift_pix,source_shift_pix,
    output reg backwards_pix,
    output wire animation_live_pix,
    output wire second_repeat_pix,
    output wire second_display_pix
);
    localparam S_IDLE=0,S_WAIT=1,S_ACK=2,S_RELEASE=3;
    localparam P_IDLE=0,P_CAPTURE=1,P_START=2,P_APPLY=3,P_RUN=4,P_WAIT_COMMIT=5,P_FADE_IN=6,P_DONE=7;
    reg [1:0] sys_state;
    reg [2:0] pix_state;
    reg request_hold_sys;
    reg [6:0] descriptor_sys;
    reg prepare_done_pix,finish_done_pix;
    (* ASYNC_REG="TRUE" *) reg request_meta_pix,request_sync_pix,ack_meta_pix,ack_sync_pix; /* fehdl keep="true" */
    (* ASYNC_REG="TRUE" *) reg prepare_meta_sys,prepare_sync_sys,finish_meta_sys,finish_sync_sys; /* fehdl keep="true" */
    reg [6:0] descriptor_pix;
    wire fast=descriptor_pix[6];
    wire [8:0] alpha_step=fast ? 9'd16:9'd8;
    wire [9:0] shift_step=fast ? 10'd60:10'd30;
    wire [9:0] source_step=fast ? 10'd40:10'd20;
    wire slide_last=fast ? alpha_pix>=240:alpha_pix>=248;
    wire [1:0] desired_effect=!current_valid_sys || menu_mode_sys==0 ? 2'd0:
        menu_mode_sys==2 ? 2'd2:target_cached_sys ? 2'd1:2'd3;
    assign busy_sys=sys_state!=S_IDLE || request_sys;
    assign inner_request_sys=request_hold_sys && prepare_sync_sys;
    assign ack_sys=(sys_state==S_ACK || sys_state==S_RELEASE) && inner_ack_sys;
    assign second_apply_pix=pix_state==P_APPLY && second_ready_pix && !second_applied_pix &&
        safe_window_pix && second_drained_pix;
    assign animation_live_pix=effect_pix!=0 && pix_state!=P_IDLE;
    // A previous transition leaves the second adapter's front-valid latched.
    // Selecting a crossfade mid-frame must not expose that stale front before
    // the new stage has applied and the following frame boundary has arrived.
    // P_DONE keeps the final visible frame enabled until normal release.
    assign second_display_pix=second_applied_pix && (effect_pix==1 || effect_pix==2) &&
        (pix_state==P_RUN || pix_state==P_DONE);
    // SYS ACK release can arrive during the final frame's blank, before its
    // prepare pulse. Keep admitting that visible frame; the PIX-side stage
    // request clears at the following frame boundary, before the next prepare.
    // This stops repeats without starving the final frame or abandoning a burst.
    assign second_repeat_pix=second_request_pix && (effect_pix==1 || effect_pix==2) && pix_state!=P_IDLE;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            sys_state<=S_IDLE;request_hold_sys<=0;descriptor_sys<=0;
            prepare_meta_sys<=0;prepare_sync_sys<=0;finish_meta_sys<=0;finish_sync_sys<=0;
        end else begin
            prepare_meta_sys<=prepare_done_pix;prepare_sync_sys<=prepare_meta_sys;
            finish_meta_sys<=finish_done_pix;finish_sync_sys<=finish_meta_sys;
            case(sys_state)
                S_IDLE: if(request_sys) begin
                    descriptor_sys<={ADAPTIVE_SPEED && desired_effect==2 && speed_sys==1,
                        desired_effect,backwards_sys,target_slot_sys};
                    request_hold_sys<=1;sys_state<=S_WAIT;
                end
                S_WAIT: if(inner_ack_sys && finish_sync_sys) sys_state<=S_ACK;
                S_ACK: if(!request_sys) begin request_hold_sys<=0;sys_state<=S_RELEASE;end
                S_RELEASE: if(!inner_ack_sys && !finish_sync_sys && !prepare_sync_sys) sys_state<=S_IDLE;
            endcase
        end
    end
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin request_meta_pix<=0;request_sync_pix<=0;ack_meta_pix<=0;ack_sync_pix<=0;end
        else begin
            request_meta_pix<=request_hold_sys;request_sync_pix<=request_meta_pix;
            ack_meta_pix<=inner_ack_sys;ack_sync_pix<=ack_meta_pix;
        end
    end
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            pix_state<=P_IDLE;descriptor_pix<=0;second_request_pix<=0;second_slot_pix<=0;
            prepare_done_pix<=0;finish_done_pix<=0;effect_pix<=0;alpha_pix<=0;
            shift_pix<=0;source_shift_pix<=0;backwards_pix<=0;
        end else if(!request_sync_pix && (pix_state==P_IDLE || frame_start_pix)) begin
            pix_state<=P_IDLE;second_request_pix<=0;prepare_done_pix<=0;finish_done_pix<=0;
            effect_pix<=0;alpha_pix<=0;shift_pix<=0;source_shift_pix<=0;
        end else case(pix_state)
            P_IDLE: pix_state<=P_CAPTURE;
            // Direction participates in the viewport raster seed even when
            // shift is zero. Publishing a reverse descriptor during active
            // video reseeds Y to the frame origin while old rows are live,
            // causing a scaler underflow before the secondary stage starts.
            // Keep the current geometry intact until the guarded blank; the
            // same start budget also leaves time to seed/prefill both paths.
            P_CAPTURE: if(stage_start_allowed_pix) begin
                descriptor_pix<=descriptor_sys;effect_pix<=descriptor_sys[5:4];
                backwards_pix<=descriptor_sys[3];second_slot_pix<=descriptor_sys[2:0];
                alpha_pix<=0;shift_pix<=0;source_shift_pix<=0;
                pix_state<=P_START;
            end
            P_START: if(descriptor_pix[5:4]==0) begin
                    prepare_done_pix<=1;finish_done_pix<=1;pix_state<=P_DONE;
                end else if(descriptor_pix[5:4]==3) begin
                    if(frame_start_pix) pix_state<=P_RUN;
                end else if(stage_start_allowed_pix && second_drained_pix) begin
                    second_request_pix<=1;pix_state<=P_APPLY;
                end
            // Stage/apply are admitted inside this frame's guarded blank.
            // The scaler starts prefetch as soon as apply raises stream-ready;
            // it must display/retire those rows in the SAME following active
            // frame. Waiting for another vblank strands all but two prefetched
            // rows and makes the adapter's next prepare raise missing-pixels.
            // Retained front-valid remains hidden until this fresh apply.
            P_APPLY: if(second_applied_pix && safe_window_pix) pix_state<=P_RUN;
            P_RUN: if(frame_start_pix) begin
                if(effect_pix==3) begin
                    if(alpha_pix>=240) begin alpha_pix<=256;prepare_done_pix<=1;pix_state<=P_WAIT_COMMIT;end
                    else alpha_pix<=alpha_pix+9'd16;
                end else begin
                    if(slide_last) begin
                        alpha_pix<=256;shift_pix<=960;source_shift_pix<=640;
                        prepare_done_pix<=1;finish_done_pix<=1;pix_state<=P_DONE;
                    end else begin alpha_pix<=alpha_pix+alpha_step;shift_pix<=shift_pix+shift_step;source_shift_pix<=source_shift_pix+source_step;end
                end
            end
            P_WAIT_COMMIT: if(ack_sync_pix && frame_start_pix) pix_state<=P_FADE_IN;
            P_FADE_IN: if(frame_start_pix) begin
                if(alpha_pix<=16) begin alpha_pix<=0;finish_done_pix<=1;pix_state<=P_DONE;end
                else alpha_pix<=alpha_pix-9'd16;
            end
            P_DONE: ;
        endcase
    end
endmodule

// Full stable frame between ordered transactions; no assumption that SYS ACK
// alone means the secondary PIX stream has drained. CDC is a level, not a pulse.
module browse_frame_guard(input wire clk_pix,rst_pix_n,clk_sys,rst_sys_n,
    input wire frame_start_pix,quiet_pix,output wire ready_sys);
    reg quiet_frame,ready_pix;
    (* ASYNC_REG="TRUE" *) reg ready_meta,ready_sync;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n)begin quiet_frame<=0;ready_pix<=0;end
        else if(!quiet_pix)begin quiet_frame<=0;ready_pix<=0;end
        else if(frame_start_pix)begin quiet_frame<=1;ready_pix<=quiet_frame;end
    end
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n)begin ready_meta<=0;ready_sync<=0;end
        else begin ready_meta<=ready_pix;ready_sync<=ready_meta;end
    end
    assign ready_sys=ready_sync;
endmodule
