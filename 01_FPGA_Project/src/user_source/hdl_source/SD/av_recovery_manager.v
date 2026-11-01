`timescale 1ns/1ps
// Runs from the unreset board reference oscillator, NOT a managed PLL clock.
// All request sources must be reset by the outputs of this module. Requests
// are SYS-domain levels held until reset; short asynchronous pulses are invalid.
module av_recovery_manager #(
    parameter [31:0] HOLD_CYCLES=32'd50000,          // 1 ms at REF=50 MHz
    parameter [31:0] CLOCK_TIMEOUT_CYCLES=32'd50000,
    parameter [31:0] RELEASE_TIMEOUT_CYCLES=32'd500000, // 10 ms per phase
    parameter [31:0] REQUEST_CLEAR_TIMEOUT_CYCLES=32'd5000000, // 100 ms
    parameter [31:0] MAX_RECOVERIES=32'd3
) (
    input wire clk_ref,ext_reset_n,
    input wire clocks_locked_async,
    input wire clk_sys,clk_mem,clk_pix,clk_audio,clk_tmds,
    input wire recovery_req_sys,
    output wire rst_sys_n,rst_mem_n,rst_pix_n,rst_audio_n,rst_tmds_n,
    output wire run_enable_sys,
    // Diagnostics are REF-domain; synchronize before reading in another domain.
    output wire recovery_busy_ref,
    output reg recovery_lockout_ref,
    output wire [2:0] recovery_state_ref,
    output wire [4:0] clock_alive_ref,
    output reg [31:0] recovery_count_ref,
    output reg [4:0] last_reason_ref
);
    localparam [2:0] HOLD=0,RELEASE_LEAVES=1,RELEASE_SYS=2,RUN=3,LOCKOUT=4;
    localparam [31:0] HOLD_LIMIT=HOLD_CYCLES==0 ? 32'd1:HOLD_CYCLES;
    localparam [31:0] RELEASE_LIMIT=RELEASE_TIMEOUT_CYCLES==0 ? 32'd1:RELEASE_TIMEOUT_CYCLES;
    localparam [31:0] CLEAR_LIMIT=REQUEST_CLEAR_TIMEOUT_CYCLES==0 ? 32'd1:REQUEST_CLEAR_TIMEOUT_CYCLES;
    // {TMDS,AUDIO,PIX,MEM,SYS}; heartbeats survive a coordinated reset.
    av_clock_presence #(.TIMEOUT_CYCLES(CLOCK_TIMEOUT_CYCLES)) sys_clock(clk_ref,ext_reset_n,clk_sys,clock_alive_ref[0]);
    av_clock_presence #(.TIMEOUT_CYCLES(CLOCK_TIMEOUT_CYCLES)) mem_clock(clk_ref,ext_reset_n,clk_mem,clock_alive_ref[1]);
    av_clock_presence #(.TIMEOUT_CYCLES(CLOCK_TIMEOUT_CYCLES)) pix_clock(clk_ref,ext_reset_n,clk_pix,clock_alive_ref[2]);
    av_clock_presence #(.TIMEOUT_CYCLES(CLOCK_TIMEOUT_CYCLES)) audio_clock(clk_ref,ext_reset_n,clk_audio,clock_alive_ref[3]);
    av_clock_presence #(.TIMEOUT_CYCLES(CLOCK_TIMEOUT_CYCLES)) tmds_clock(clk_ref,ext_reset_n,clk_tmds,clock_alive_ref[4]);
    wire clock_health_n=ext_reset_n && clocks_locked_async && (&clock_alive_ref);
    // Async loss capture survives a lock glitch shorter than a REF period.
    // The FSM sees zero for at least one edge and restarts the full hold time.
    (* ASYNC_REG="TRUE" *) reg [1:0] clock_qualified;
    always @(posedge clk_ref or negedge clock_health_n) begin
        if(!clock_health_n) clock_qualified<=0;
        else clock_qualified<={clock_qualified[0],1'b1};
    end
    (* ASYNC_REG="TRUE" *) reg req_meta_ref,req_sync_ref;
    always @(posedge clk_ref or negedge ext_reset_n) begin
        if(!ext_reset_n) begin req_meta_ref<=0;req_sync_ref<=0;end
        else begin req_meta_ref<=recovery_req_sys;req_sync_ref<=req_meta_ref;end
    end
    reg [2:0] state;
    // Saturating timers retain their original limits and cycles. HOLD can
    // reach HOLD_LIMIT; the other timers stop at LIMIT-1. Use a 33-bit
    // constant for LIMIT+1 so the 32'hffffffff override remains supported.
    localparam HOLD_WIDTH=$clog2({1'b0,HOLD_LIMIT}+33'd1);
    localparam PHASE_WIDTH=RELEASE_LIMIT>1 ? $clog2(RELEASE_LIMIT):1;
    localparam CLEAR_WIDTH=CLEAR_LIMIT>1 ? $clog2(CLEAR_LIMIT):1;
    reg [HOLD_WIDTH-1:0] hold_count;
    reg [PHASE_WIDTH-1:0] phase_count;
    reg [CLEAR_WIDTH-1:0] clear_count;
    reg ever_run;
    wire leaf_release_n=clock_health_n && clock_qualified[1] && !recovery_lockout_ref &&
        (state==RELEASE_LEAVES || state==RELEASE_SYS || state==RUN);
    wire sys_release_n=leaf_release_n && (state==RELEASE_SYS || state==RUN);
    av_reset_release sys_reset(clk_sys,sys_release_n,rst_sys_n);
    av_reset_release mem_reset(clk_mem,leaf_release_n,rst_mem_n);
    av_reset_release pix_reset(clk_pix,leaf_release_n,rst_pix_n);
    av_reset_release audio_reset(clk_audio,leaf_release_n,rst_audio_n);
    av_reset_release tmds_reset(clk_tmds,leaf_release_n,rst_tmds_n);
    (* ASYNC_REG="TRUE" *) reg [4:0] release_meta_ref,release_sync_ref;
    always @(posedge clk_ref or negedge ext_reset_n) begin
        if(!ext_reset_n) begin release_meta_ref<=0;release_sync_ref<=0;end
        else begin
            release_meta_ref<={rst_tmds_n,rst_audio_n,rst_pix_n,rst_mem_n,rst_sys_n};
            release_sync_ref<=release_meta_ref;
        end
    end
    assign recovery_state_ref=state;
    wire running_ref=state==RUN && clock_health_n && clock_qualified[1] &&
        !req_sync_ref && !recovery_lockout_ref;
    assign recovery_busy_ref=!running_ref;
    (* ASYNC_REG="TRUE" *) reg run_meta_sys,run_sync_sys;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin run_meta_sys<=0;run_sync_sys<=0;end
        else begin run_meta_sys<=running_ref;run_sync_sys<=run_meta_sys;end
    end
    assign run_enable_sys=rst_sys_n && run_sync_sys && !recovery_req_sys;

    always @(posedge clk_ref or negedge ext_reset_n) begin
        if(!ext_reset_n) begin
            state<=HOLD;hold_count<=0;phase_count<=0;clear_count<=0;
            recovery_lockout_ref<=0;recovery_count_ref<=0;last_reason_ref<=0;ever_run<=0;
        end else if(recovery_lockout_ref) begin
            state<=LOCKOUT;
        end else if(!clock_qualified[1]) begin
            state<=HOLD;hold_count<=0;phase_count<=0;clear_count<=0;
            if(ever_run) last_reason_ref<=5'b00010;
        end else begin
            case(state)
                HOLD: begin
                    phase_count<=0;
                    if(hold_count<HOLD_LIMIT) hold_count<=hold_count+1'b1;
                    if(req_sync_ref) begin
                        if(clear_count>=CLEAR_LIMIT-1) begin
                            recovery_lockout_ref<=1;state<=LOCKOUT;last_reason_ref<=5'b00100;
                        end else clear_count<=clear_count+1'b1;
                    end else begin
                        clear_count<=0;
                        // Observe every previous release ACK low before a new
                        // release. This also protects very short HOLD settings
                        // from stale acknowledgements in the REF synchronizers.
                        if(hold_count>=HOLD_LIMIT-1 && release_sync_ref==5'd0) state<=RELEASE_LEAVES;
                    end
                end
                RELEASE_LEAVES,RELEASE_SYS,RUN: begin
                    if(req_sync_ref) begin
                        if(recovery_count_ref>=MAX_RECOVERIES) begin
                            recovery_lockout_ref<=1;state<=LOCKOUT;last_reason_ref<=5'b10000;
                        end else begin
                            recovery_count_ref<=recovery_count_ref+1'b1;
                            state<=HOLD;hold_count<=0;phase_count<=0;clear_count<=0;last_reason_ref<=5'b00001;
                        end
                    end else if(state==RUN) begin
                        ever_run<=1;phase_count<=0;
                    end else if((state==RELEASE_LEAVES && (&release_sync_ref[4:1])) ||
                        (state==RELEASE_SYS && release_sync_ref[0])) begin
                        phase_count<=0;
                        state<=state==RELEASE_LEAVES ? RELEASE_SYS:RUN;
                    end else if(phase_count>=RELEASE_LIMIT-1) begin
                        recovery_lockout_ref<=1;state<=LOCKOUT;last_reason_ref<=5'b01000;
                    end else phase_count<=phase_count+1'b1;
                end
                default: begin recovery_lockout_ref<=1;state<=LOCKOUT;last_reason_ref<=5'b01000;end
            endcase
        end
    end
endmodule

// Three local rising edges to release; assertion does not require a clock.
module av_reset_release(input wire clk,async_reset_n,output wire reset_n);
    (* ASYNC_REG="TRUE" *) reg [2:0] stages;
    always @(posedge clk or negedge async_reset_n) begin
        if(!async_reset_n) stages<=0;
        else stages<={stages[1:0],1'b1};
    end
    assign reset_n=stages[2];
endmodule

// Presence watchdog, not a frequency meter. A slow toggle avoids aliasing
// at the project's REF50/SYS100/MEM125/PIX25/AUDIO12.3/TMDS125 MHz rates.
module av_clock_presence #(
    parameter [31:0] TIMEOUT_CYCLES=32'd50000
) (input wire clk_ref,ext_reset_n,domain_clk,output reg alive_ref);
    localparam [31:0] LIMIT=TIMEOUT_CYCLES==0 ? 32'd1:TIMEOUT_CYCLES;
    reg [5:0] heartbeat_count;
    always @(posedge domain_clk or negedge ext_reset_n) begin
        if(!ext_reset_n) heartbeat_count<=0;
        else heartbeat_count<=heartbeat_count+1'b1;
    end
    (* ASYNC_REG="TRUE" *) reg toggle_meta,toggle_sync;
    reg seen_toggle;
    localparam AGE_WIDTH=LIMIT>1 ? $clog2(LIMIT):1;
    reg [AGE_WIDTH-1:0] age;
    always @(posedge clk_ref or negedge ext_reset_n) begin
        if(!ext_reset_n) begin toggle_meta<=0;toggle_sync<=0;seen_toggle<=0;age<=0;alive_ref<=0;end
        else begin
            toggle_meta<=heartbeat_count[5];toggle_sync<=toggle_meta;
            if(toggle_sync!=seen_toggle) begin seen_toggle<=toggle_sync;age<=0;alive_ref<=1;end
            else if(age>=LIMIT-1) alive_ref<=0;
            else age<=age+1'b1;
        end
    end
endmodule
