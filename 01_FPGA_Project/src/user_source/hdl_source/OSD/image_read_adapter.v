`timescale 1ns/1ps
// Image read path with the EXISTING rfifo_32_32_512 IP. One SDRAM word per
// pixel, RGB in bits [31:8]. All App addresses are WORD addresses.
// mem_read_permit means that this edge accepts an App_rd_en word command.
// It must be bound to the physical controller's actual acceptance contract.
// Responses must be ordered, exactly one Sdr_rd_en word per accepted command.
// Reset mem/pix/SDRAM coherently; do not reset this adapter alone in flight.
module image_read_adapter #(
    parameter integer ADDR_BITS=21,
    parameter integer FRAME_WORDS=307200,
    parameter integer IMAGE_BANK_COUNT=2,
    parameter integer BANK_BITS=2,
    parameter [ADDR_BITS-1:0] BANK0_BASE=0,
    parameter [ADDR_BITS-1:0] BANK1_BASE=307200,
    parameter [ADDR_BITS-1:0] BANK2_BASE=614400,
    parameter [ADDR_BITS-1:0] BANK3_BASE=921600,
    parameter [ADDR_BITS-1:0] BANK4_BASE=1228800,
    parameter [ADDR_BITS-1:0] BANK5_BASE=1536000,
    parameter integer BURST_WORDS=256,
    parameter integer PREFILL_WORDS=256,
    parameter integer MEM_TIMEOUT_CYCLES=40000,
    parameter integer PIX_TIMEOUT_CYCLES=25000,
    // The physical Anlogic core cannot pause an admitted word burst.
    parameter integer FINISH_BURST_ON_FENCE=0,
    parameter integer VIEWPORT_ENABLE=0
) (
    input wire clk_mem, rst_mem_n, clk_pix, rst_pix_n,
    input wire mem_read_permit, mem_write_busy,
    output wire App_rd_en,
    output wire [ADDR_BITS-1:0] App_rd_addr,
    output wire O_rd_busy,
    output wire App_rd_burst_req,
    input wire Sdr_rd_en,
    input wire [31:0] Sdr_rd_dout,
    input wire prepare_frame_pix, safe_commit_window_pix,
    input wire [21:0] viewport_request_pix,
    output wire [21:0] viewport_actual_pix,
    output wire [8:0] viewport_first_row_pix,
    input wire pixel_read_en_pix,
    input wire image_stage_req_pix,
    input wire [BANK_BITS-1:0] image_stage_bank_pix,
    output reg image_stage_ready_pix, image_applied_pix,
    input wire image_apply_pix,
    output reg [BANK_BITS-1:0] image_front_bank_pix,
    output reg image_front_valid_pix,
    output wire image_stage_error_pix,
    output wire [7:0] image_error_code_pix,
    // Own OLD-frame drain is latched before any next-frame prefetch. Combine
    // this with OSD and AXIS idle in video_frame_commit, not FIFO empty alone.
    output reg old_image_drained_pix,
    output wire [31:0] pixel_word_pix,
    output wire pixel_word_valid_pix,
    // A prefetch consumer may drain only after the staged descriptor is applied.
    output wire pixel_stream_ready_pix,
    output wire image_read_idle_pix,
    output wire [8:0] fifo_level_pix,
    output wire fifo_reset_mem,
    output reg [7:0] mem_error_code
);
    localparam [2:0] P_IDLE=0,P_ACK=1,P_RELEASE=2,P_GEOMETRY=3,P_GEOMETRY_WAIT=4;
    localparam [2:0] M_RUN=0,M_CAPTURE=1,M_FENCE=2,M_RESET=3,
        M_RESET_RELEASE=4,M_PREFILL=5,M_ACK=6;
    localparam integer MLIMIT=MEM_TIMEOUT_CYCLES<1 ? 1:MEM_TIMEOUT_CYCLES;
    localparam integer PLIMIT=PIX_TIMEOUT_CYCLES<1 ? 1:PIX_TIMEOUT_CYCLES;
    // Inclusive counters must also represent FRAME_WORDS/the timeout limit.
    localparam integer FRAME_BITS=FRAME_WORDS>1 ? $clog2(FRAME_WORDS+1):1;
    localparam integer MEM_TIMER_BITS=$clog2(MLIMIT+1);
    localparam integer PIX_TIMER_BITS=$clog2(PLIMIT+1);
    localparam integer CHUNK_LIMIT=BURST_WORDS<1 ? 1:BURST_WORDS;
    localparam integer CHUNK_BITS=CHUNK_LIMIT>1 ? $clog2(CHUNK_LIMIT+1):1;
    localparam [FRAME_BITS-1:0] FRAME_COUNT=FRAME_WORDS, FRAME_LAST=FRAME_WORDS-1;
    localparam [MEM_TIMER_BITS-1:0] MEM_LIMIT=MLIMIT, MEM_LAST=MLIMIT-1;
    localparam [PIX_TIMER_BITS-1:0] PIX_LIMIT=PLIMIT, PIX_LAST=PLIMIT-1;
    localparam [CHUNK_BITS-1:0] FULL_CHUNK=CHUNK_LIMIT;
    // Bank range checks are constant per bank, not a runtime address adder.
    localparam [ADDR_BITS:0] BANK0_END={1'b0,BANK0_BASE}+FRAME_WORDS;
    localparam [ADDR_BITS:0] BANK1_END={1'b0,BANK1_BASE}+FRAME_WORDS;
    localparam [ADDR_BITS:0] BANK2_END={1'b0,BANK2_BASE}+FRAME_WORDS;
    localparam [ADDR_BITS:0] BANK3_END={1'b0,BANK3_BASE}+FRAME_WORDS;
    wire config_valid=ADDR_BITS>=1 && ADDR_BITS<=30 && FRAME_WORDS>0 &&
        FRAME_WORDS<=(2**ADDR_BITS) && IMAGE_BANK_COUNT>=2 && IMAGE_BANK_COUNT<=6 &&
        BURST_WORDS>=1 && BURST_WORDS<=511 && PREFILL_WORDS>=1 &&
        PREFILL_WORDS<=511 && PREFILL_WORDS<=FRAME_WORDS &&
        (VIEWPORT_ENABLE==0 || (FRAME_WORDS==307200 && BURST_WORDS==256));
    reg [2:0] pix_state;
    reg [BANK_BITS-1:0] command_bank_pix;
    reg command_req_pix, command_is_stage_pix, stage_owned_pix;
    reg auto_due_pix, frame_ready_pix, visible_frame_started_pix;
    reg [FRAME_BITS-1:0] pixels_left_pix;
    reg [21:0] command_viewport_pix;
    reg [8:0] command_first_row_pix;
    reg [FRAME_BITS-1:0] command_words_pix;
    reg [ADDR_BITS-1:0] command_offset_pix;
    wire [8:0] requested_first_row;
    wire [9:0] requested_rows;
    wire geometry_done;
    generate if(VIEWPORT_ENABLE) begin: viewport_geometry
        viewport_descriptor_geometry geometry(.clk(clk_pix),.rst_n(rst_pix_n),
            .start(pix_state==P_GEOMETRY),.transform(command_viewport_pix),.done(geometry_done),
            .first_row(requested_first_row),.row_count(requested_rows));
    end else begin: full_frame_geometry
        assign requested_first_row=0;assign requested_rows=480;assign geometry_done=1'b1;
    end endgenerate
    wire [18:0] requested_words=({9'd0,requested_rows}<<9)+({9'd0,requested_rows}<<7);
    wire [18:0] requested_offset=({10'd0,requested_first_row}<<9)+({10'd0,requested_first_row}<<7);
    assign viewport_actual_pix=command_viewport_pix;
    assign viewport_first_row_pix=command_first_row_pix;
    reg [FRAME_BITS-1:0] frame_count_mem,pending_words_mem;
    reg [ADDR_BITS-1:0] pending_offset_mem;
    // Predict zero at the consuming edge, avoiding the wide counter compare
    // in every FIFO/admission/error path. It has exactly the same cycle value.
    reg pixels_nonzero_pix;
    reg [PIX_TIMER_BITS-1:0] pix_timer;
    reg [7:0] pix_error_code;
    reg [2:0] mem_state;
    reg command_ack_mem, fifo_clear_mem, stream_active_mem, frame_done_mem;
    reg [BANK_BITS-1:0] base_bank_mem, pending_bank_mem;
    reg [ADDR_BITS-1:0] read_addr_mem;
    wire [ADDR_BITS-1:0] base_mem=base_bank_mem==0 ? BANK0_BASE:
        base_bank_mem==1 ? BANK1_BASE:base_bank_mem==2 ? BANK2_BASE:
        base_bank_mem==3 ? BANK3_BASE:base_bank_mem==4 ? BANK4_BASE:BANK5_BASE;
    wire [ADDR_BITS-1:0] pending_base_mem=pending_bank_mem==0 ? BANK0_BASE:
        pending_bank_mem==1 ? BANK1_BASE:pending_bank_mem==2 ? BANK2_BASE:
        pending_bank_mem==3 ? BANK3_BASE:pending_bank_mem==4 ? BANK4_BASE:BANK5_BASE;
    reg [FRAME_BITS-1:0] issued_mem, returned_mem;
    reg [MEM_TIMER_BITS-1:0] mem_timer, response_timer;
    reg [CHUNK_BITS-1:0] outstanding_mem, burst_left_mem;
    reg burst_active_mem;
    reg [3:0] reset_ticks_mem;
    (* async_reg="true" *) reg req_meta_mem,req_sync_mem;
    (* async_reg="true" *) reg ack_meta_pix,ack_sync_pix;
    (* async_reg="true" *) reg reset_meta_pix,reset_sync_pix;
    (* async_reg="true" *) reg reset_meta_mem,reset_sync_mem;
    (* async_reg="true" *) reg done_meta_pix,done_sync_pix;
    (* async_reg="true" *) reg error_meta_pix,error_sync_pix;
    (* async_reg="true" *) reg error_meta_mem,error_sync_mem;
    (* async_reg="true" *) reg [1:0] fifo_run_mem,fifo_run_pix;
    reg [3:0] reset_ticks_pix;
    reg reset_seen_pix;
    wire [31:0] fifo_data;
    wire fifo_valid,fifo_full,fifo_empty;
    wire [8:0] fifo_level_mem;
    wire fault_mem=(mem_error_code!=0) || error_sync_mem;
    wire fault_pix=(pix_error_code!=0) || error_sync_pix;
    assign image_stage_error_pix=fault_pix;
    // The mem code is a stable bundled diagnostic once its fault level is
    // synchronized. Public recovery needs only image_stage_error_pix.
    assign image_error_code_pix=pix_error_code!=0 ? pix_error_code :
        (error_sync_pix ? mem_error_code:8'd0);
    assign fifo_reset_mem=fifo_clear_mem || !rst_mem_n || !rst_pix_n;
    // Raw FIFO reset is asynchronous in BOTH domains. Assert the guards at
    // once, then release each on its own clocks; never use the other domain's
    // reset directly in an ordinary read/response clock-enable cone.
    always @(posedge clk_mem or posedge fifo_reset_mem) begin
        if(fifo_reset_mem) fifo_run_mem<=0;
        else fifo_run_mem<={fifo_run_mem[0],1'b1};
    end
    always @(posedge clk_pix or posedge fifo_reset_mem) begin
        if(fifo_reset_mem) fifo_run_pix<=0;
        else fifo_run_pix<={fifo_run_pix[0],1'b1};
    end
    wire fifo_read=rst_pix_n && image_front_valid_pix && frame_ready_pix &&
        !fault_pix && fifo_run_pix[1] && !reset_sync_pix && pixel_read_en_pix &&
        pixels_nonzero_pix && !fifo_empty;
    assign pixel_stream_ready_pix=rst_pix_n&&image_front_valid_pix&&frame_ready_pix&&
        (!stage_owned_pix||image_applied_pix)&&!fault_pix&&fifo_run_pix[1]&&
        !reset_sync_pix&&pixels_nonzero_pix;
    assign pixel_word_valid_pix=fifo_valid && !fault_pix && fifo_run_pix[1];
    assign pixel_word_pix=pixel_word_valid_pix ? fifo_data:32'd0;
    assign image_read_idle_pix=!fifo_read && !fifo_valid;
    wire fill_state=mem_state==M_RUN || mem_state==M_PREFILL || mem_state==M_ACK;
    wire new_command_stop=mem_state==M_RUN && req_sync_mem;
    assign App_rd_en=rst_mem_n && stream_active_mem &&
        ((fill_state && !new_command_stop) || FINISH_BURST_ON_FENCE!=0) &&
        burst_active_mem && burst_left_mem!=0 &&
        mem_read_permit && !fault_mem && fifo_run_mem[1];
    assign App_rd_addr=read_addr_mem;
    // No combinational grant loop with frame_fifo_write: a read reserves a
    // burst on a clock edge only after seeing mem_write_busy=0, then owns the
    // arbiter until the ACTUAL last return, including any delayed tail.
    assign O_rd_busy=burst_active_mem || outstanding_mem!=0;
    wire response_expected=outstanding_mem!=0 || App_rd_en;
    wire fifo_write=Sdr_rd_en && response_expected && fifo_run_mem[1] && !fifo_full && !fault_mem;
    wire [CHUNK_BITS-1:0] next_chunk;
    generate
        if(FRAME_WORDS%CHUNK_LIMIT==0) begin: fixed_chunks
            // 640x480 / 256 has no partial final burst.
            assign next_chunk=FULL_CHUNK;
        end else begin: partial_chunk
            wire [FRAME_BITS-1:0] remaining=frame_count_mem-issued_mem;
            assign next_chunk=remaining<CHUNK_LIMIT ? remaining:FULL_CHUNK;
        end
    endgenerate
    // No next burst can start until burst_active_mem=0 and all its actual
    // returns are drained (outstanding_mem=0). If that burst issued the final
    // word, its final return has already set frame_done_mem before admission
    // can reopen. Reuse this registered completion instead of placing the
    // wide issued<count comparison before the dual-reader arbiter. This is
    // cycle-equivalent at the request interface, including zero-latency and
    // delayed responses, and adds no state or data-path latency.
    assign App_rd_burst_req=rst_mem_n && stream_active_mem && fill_state &&
        !new_command_stop && !burst_active_mem && !frame_done_mem &&
        outstanding_mem==0 && fifo_level_mem<=10'd511-{1'b0,next_chunk} &&
        !fault_mem && fifo_run_mem[1];
    wire descriptor_valid=config_valid && (VIEWPORT_ENABLE==0 || (FRAME_WORDS==307200 &&
        command_words_pix>=PREFILL_WORDS && command_words_pix+{1'b0,command_offset_pix}<=FRAME_WORDS)) &&
        (command_bank_pix==0 ? (IMAGE_BANK_COUNT>0 && BANK0_END<=(2**ADDR_BITS)):
         command_bank_pix==1 ? (IMAGE_BANK_COUNT>1 && BANK1_END<=(2**ADDR_BITS)):
         command_bank_pix==2 ? (IMAGE_BANK_COUNT>2 && BANK2_END<=(2**ADDR_BITS)):
                              command_bank_pix==3 ? (IMAGE_BANK_COUNT>3 && BANK3_END<=(2**ADDR_BITS)):
         command_bank_pix==4 ? (IMAGE_BANK_COUNT>4 && BANK4_BASE+FRAME_WORDS<=(2**ADDR_BITS)):
         command_bank_pix==5 && IMAGE_BANK_COUNT>5 && BANK5_BASE+FRAME_WORDS<=(2**ADDR_BITS));

    rfifo_32_32_512 read_fifo(
        .rst(fifo_reset_mem),.clkw(clk_mem),.clkr(clk_pix),
        .we(fifo_write),.di(Sdr_rd_dout),.re(fifo_read),.dout(fifo_data),.valid(fifo_valid),
        .full_flag(fifo_full),.empty_flag(fifo_empty),.afull(),.aempty(),
        .wrusedw(fifo_level_mem),.rdusedw(fifo_level_pix)
    );
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if(!rst_mem_n) begin req_meta_mem<=0;req_sync_mem<=0;reset_meta_mem<=0;reset_sync_mem<=0;
            error_meta_mem<=0;error_sync_mem<=0;end
        else begin req_meta_mem<=command_req_pix;req_sync_mem<=req_meta_mem;
            reset_meta_mem<=reset_seen_pix;reset_sync_mem<=reset_meta_mem;
            error_meta_mem<=fault_pix;error_sync_mem<=error_meta_mem;end
    end
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin ack_meta_pix<=0;ack_sync_pix<=0;reset_meta_pix<=1;reset_sync_pix<=1;
            done_meta_pix<=0;done_sync_pix<=0;error_meta_pix<=0;error_sync_pix<=0;
            reset_ticks_pix<=0;reset_seen_pix<=0;end
        else begin ack_meta_pix<=command_ack_mem;ack_sync_pix<=ack_meta_pix;
            reset_meta_pix<=fifo_clear_mem;reset_sync_pix<=reset_meta_pix;
            done_meta_pix<=frame_done_mem;done_sync_pix<=done_meta_pix;
            error_meta_pix<=mem_error_code!=0;error_sync_pix<=error_meta_pix;
            // Confirm BOTH asserted reset and four read clocks of release.
            // The IP itself synchronizes reset release for its two pointers.
            if(reset_sync_pix) begin reset_seen_pix<=1;reset_ticks_pix<=0;end
            else if(reset_ticks_pix<4) reset_ticks_pix<=reset_ticks_pix+1'b1;
            else reset_seen_pix<=0;
        end
    end

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            pix_state<=P_IDLE;command_bank_pix<=0;command_req_pix<=0;command_is_stage_pix<=0;
            stage_owned_pix<=0;image_stage_ready_pix<=0;image_applied_pix<=0;
            image_front_bank_pix<=0;image_front_valid_pix<=0;auto_due_pix<=0;
            frame_ready_pix<=0;pixels_left_pix<=0;pixels_nonzero_pix<=0;visible_frame_started_pix<=0;
            old_image_drained_pix<=1;pix_timer<=0;pix_error_code<=0;
            command_viewport_pix<=0;command_first_row_pix<=0;
            command_words_pix<=FRAME_COUNT;command_offset_pix<=0;
        end else if(!fault_pix) begin
            if(prepare_frame_pix && image_front_valid_pix) auto_due_pix<=1;
            if(pix_state!=P_IDLE && pix_timer<PIX_LIMIT) pix_timer<=pix_timer+1'b1;
            if(!config_valid) pix_error_code<=8'd1;
            else if(prepare_frame_pix && image_front_valid_pix && visible_frame_started_pix && pixels_nonzero_pix)
                pix_error_code<=8'd7; // Frontend omitted pixels from the preceding frame.
            else if(pix_state!=P_IDLE && pix_timer>=PIX_LAST) pix_error_code<=8'd3;
            else if((pix_state!=P_IDLE || (stage_owned_pix && !image_applied_pix)) && !safe_commit_window_pix)
                pix_error_code<=8'd5;
            else if(stage_owned_pix && !image_stage_req_pix && !image_applied_pix)
                pix_error_code<=8'd6;
            else if(pixel_read_en_pix && image_front_valid_pix &&
                (!frame_ready_pix || !pixels_nonzero_pix || fifo_empty || !fifo_run_pix[1] || reset_sync_pix))
                pix_error_code<=8'd4;
            else begin
                if(fifo_read) begin
                    pixels_left_pix<=pixels_left_pix-1'b1;pixels_nonzero_pix<=pixels_left_pix!=1;
                    visible_frame_started_pix<=1;old_image_drained_pix<=0;
                end
                if(visible_frame_started_pix && !pixels_nonzero_pix && !fifo_valid && done_sync_pix)
                    old_image_drained_pix<=1;
                if(stage_owned_pix && !image_stage_req_pix && image_applied_pix && pix_state==P_IDLE) begin
                    image_stage_ready_pix<=0;image_applied_pix<=0;stage_owned_pix<=0;
                end
                if(image_apply_pix) begin
                    if(!stage_owned_pix || !image_stage_ready_pix || image_applied_pix ||
                        !image_stage_req_pix || !safe_commit_window_pix || !old_image_drained_pix ||
                        pixel_read_en_pix || fifo_valid || pix_state!=P_IDLE) pix_error_code<=8'd6;
                    else begin image_front_bank_pix<=command_bank_pix;image_front_valid_pix<=1;
                        image_applied_pix<=1;auto_due_pix<=0;end
                end
                case(pix_state)
                    P_IDLE: begin
                        pix_timer<=0;
                        // A queued stage preempts a repeat when idle. If a
                        // repeat is already crossing clocks, finish its finite
                        // handshake first, then fence/flush it for the stage.
                        if(image_stage_req_pix && !stage_owned_pix && safe_commit_window_pix && old_image_drained_pix) begin
                            command_bank_pix<=image_stage_bank_pix;command_is_stage_pix<=1;stage_owned_pix<=1;
                            command_req_pix<=VIEWPORT_ENABLE ? 0:1;frame_ready_pix<=0;pix_state<=VIEWPORT_ENABLE ? P_GEOMETRY:P_ACK;auto_due_pix<=0;
                            visible_frame_started_pix<=0;
                            command_viewport_pix<=VIEWPORT_ENABLE ? viewport_request_pix:22'd0;
                            if(!VIEWPORT_ENABLE) begin command_first_row_pix<=0;command_words_pix<=FRAME_COUNT;command_offset_pix<=0;end
                        end else if(auto_due_pix && image_front_valid_pix &&
                            (!stage_owned_pix || image_applied_pix) && safe_commit_window_pix && old_image_drained_pix) begin
                            command_bank_pix<=image_front_bank_pix;command_is_stage_pix<=0;
                            command_req_pix<=VIEWPORT_ENABLE ? 0:1;frame_ready_pix<=0;pix_state<=VIEWPORT_ENABLE ? P_GEOMETRY:P_ACK;auto_due_pix<=0;
                            visible_frame_started_pix<=0;
                            command_viewport_pix<=VIEWPORT_ENABLE ? viewport_request_pix:22'd0;
                            if(!VIEWPORT_ENABLE) begin command_first_row_pix<=0;command_words_pix<=FRAME_COUNT;command_offset_pix<=0;end
                        end
                    end
                    // Freeze the target first, calculate the finite crop in
                    // blank, then launch the unchanged four-phase CDC request.
                    P_GEOMETRY: pix_state<=P_GEOMETRY_WAIT;
                    P_GEOMETRY_WAIT: if(geometry_done) begin
                        command_first_row_pix<=requested_first_row;
                        command_words_pix<=requested_words;command_offset_pix<=requested_offset;
                        command_req_pix<=1;pix_state<=P_ACK;
                    end
                    P_ACK: if(ack_sync_pix && !reset_sync_pix && fifo_level_pix>=PREFILL_WORDS) begin
                        command_req_pix<=0;pix_state<=P_RELEASE;
                    end
                    P_RELEASE: if(!ack_sync_pix) begin
                        pixels_left_pix<=command_words_pix;pixels_nonzero_pix<=command_words_pix!=0;frame_ready_pix<=1;pix_state<=P_IDLE;
                        if(command_is_stage_pix) image_stage_ready_pix<=1;
                    end
                    default: pix_error_code<=8'd6;
                endcase
            end
        end
    end

    always @(posedge clk_mem or negedge rst_mem_n) begin
        if(!rst_mem_n) begin
            mem_state<=M_RUN;command_ack_mem<=0;fifo_clear_mem<=0;stream_active_mem<=0;
            frame_done_mem<=0;base_bank_mem<=0;pending_bank_mem<=0;read_addr_mem<=0;
            issued_mem<=0;returned_mem<=0;outstanding_mem<=0;
            burst_left_mem<=0;burst_active_mem<=0;reset_ticks_mem<=0;
            mem_timer<=0;response_timer<=0;mem_error_code<=0;
            frame_count_mem<=FRAME_COUNT;pending_words_mem<=FRAME_COUNT;pending_offset_mem<=0;
        end else if(!fault_mem) begin
            if(mem_state!=M_RUN && mem_timer<MEM_LIMIT) mem_timer<=mem_timer+1'b1;
            if(O_rd_busy && !App_rd_en && !Sdr_rd_en) response_timer<=response_timer+1'b1;
            else response_timer<=0;
            // Track every accepted command and every actual response. Space
            // reservations include outstanding returns, not just FIFO level.
            case({App_rd_en,Sdr_rd_en})
                2'b10: outstanding_mem<=outstanding_mem+1'b1;
                2'b01: if(response_expected) outstanding_mem<=outstanding_mem-1'b1;
                default: outstanding_mem<=outstanding_mem;
            endcase
            if(App_rd_en) begin
                issued_mem<=issued_mem+1'b1;burst_left_mem<=burst_left_mem-1'b1;
                read_addr_mem<=read_addr_mem+1'b1;
            end
            if(Sdr_rd_en && response_expected) begin
                returned_mem<=returned_mem+1'b1;
                if(returned_mem==frame_count_mem-1'b1) frame_done_mem<=1;
            end
            if(Sdr_rd_en && (!response_expected || !fifo_run_mem[1] || fifo_full)) mem_error_code<=8'd2;
            else if((mem_state!=M_RUN && mem_timer>=MEM_LAST) ||
                (O_rd_busy && response_timer>=MEM_LAST)) mem_error_code<=8'd3;
            else begin
                if((!fill_state || new_command_stop) && FINISH_BURST_ON_FENCE==0) begin
                    burst_left_mem<=0;
                    if(outstanding_mem==0 && !Sdr_rd_en) burst_active_mem<=0;
                end else if(burst_active_mem) begin
                    if(burst_left_mem==0 && outstanding_mem==0) burst_active_mem<=0;
                end else if(App_rd_burst_req && !mem_write_busy && mem_read_permit) begin
                    burst_active_mem<=1;burst_left_mem<=next_chunk;
                end
                case(mem_state)
                    M_RUN: begin
                        mem_timer<=0;
                        if(req_sync_mem) mem_state<=M_CAPTURE;
                    end
                    M_CAPTURE: begin
                        if(!descriptor_valid) mem_error_code<=8'd1;
                        else begin
                            pending_bank_mem<=command_bank_pix;pending_words_mem<=command_words_pix;
                            pending_offset_mem<=command_offset_pix;mem_state<=M_FENCE;
                        end
                    end
                    M_FENCE: if(outstanding_mem==0 && !Sdr_rd_en &&
                        (FINISH_BURST_ON_FENCE==0 || burst_left_mem==0)) begin
                        base_bank_mem<=pending_bank_mem;read_addr_mem<=pending_base_mem+pending_offset_mem;
                        frame_count_mem<=pending_words_mem;
                        fifo_clear_mem<=1;stream_active_mem<=0;frame_done_mem<=0;
                        burst_active_mem<=0;burst_left_mem<=0;reset_ticks_mem<=0;mem_state<=M_RESET;
                    end
                    M_RESET: begin
                        if(reset_ticks_mem<4) reset_ticks_mem<=reset_ticks_mem+1'b1;
                        if(reset_ticks_mem>=4 && reset_sync_mem) begin
                            fifo_clear_mem<=0;reset_ticks_mem<=0;mem_state<=M_RESET_RELEASE;
                        end
                    end
                    M_RESET_RELEASE: begin
                        if(reset_ticks_mem<4) reset_ticks_mem<=reset_ticks_mem+1'b1;
                        if(reset_ticks_mem>=4 && !reset_sync_mem) begin
                            issued_mem<=0;returned_mem<=0;outstanding_mem<=0;
                            stream_active_mem<=1;mem_state<=M_PREFILL;
                        end
                    end
                    M_PREFILL: if(returned_mem>=PREFILL_WORDS) begin command_ack_mem<=1;mem_state<=M_ACK;end
                    M_ACK: if(!req_sync_mem) begin command_ack_mem<=0;mem_state<=M_RUN;end
                    default: mem_error_code<=8'd6;
                endcase
            end
        end
    end
endmodule
