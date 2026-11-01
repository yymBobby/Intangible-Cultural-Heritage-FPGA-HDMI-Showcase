`timescale 1ns/1ps
// One owner of the protected SDRAM core. Admission is per complete burst,
// NOT per word gated by Sdr_busy. Addresses are 32-bit WORD addresses.
// 100 MHz producer -> existing show-ahead FIFO -> 125 MHz SDRAM.
// Reset all domains/controller together; a fault requires coordinated reset.
module sdram_image_backend #(
    parameter integer FRAME_WORDS=307200,
    parameter integer IMAGE_BANK_COUNT=2,
    parameter integer BANK_BITS=2,
    parameter integer DUAL_READ=0,
    parameter integer ROW_WORDS=640,
    parameter integer WRITE_BOTTOM_UP=0,
    // Board at MEM=50MHz, SDRAM +8ns: DOUT leads registered valid by 2 cycles.
    // 0 is retained only for explicit legacy-interface simulation comparison.
    parameter integer READ_DATA_DELAY=2,
    parameter integer READ_BURST=256,
    parameter integer WRITE_BURST=128,
    parameter integer TAIL_CYCLES=40,
    parameter integer REFRESH_CYCLES=625,
    parameter integer REFRESH_MARGIN=384,
    parameter integer WATCHDOG_CYCLES=500000000, // SYS: whole-frame load, 5 s at 100 MHz
    parameter integer MEM_WATCHDOG_CYCLES=400000 // MEM: one physical operation, 10 ms at 125 MHz
) (
    input wire clk_sys, rst_sys_n, clk_mem, clk_mem_sft, rst_mem_n,
    input wire image_write_start_sys,
    // Four-phase cancellation. Finish the reserved physical burst/tail, then
    // clear ONLY the write FIFO. Hold request until ack; no new job until idle.
    input wire image_write_abort_sys,
    output reg image_write_abort_ack_sys,
    input wire [BANK_BITS-1:0] image_write_bank_sys,
    output wire image_write_start_ready_sys,
    input wire image_write_data_valid_sys,
    input wire [31:0] image_write_data_sys,
    output wire image_write_data_ready_sys,
    output wire image_write_busy_sys,
    output reg image_prepared_sys,
    output reg [BANK_BITS-1:0] prepared_image_bank_sys,
    input wire write_allowed_sys, front_valid_sys,
    input wire [BANK_BITS-1:0] active_image_bank_sys,
    output wire image_write_error_sys,
    output wire [7:0] image_write_error_code_sys,
    input wire App_rd_burst_req_b,App_rd_en_b,
    input wire [20:0] App_rd_addr_b,
    output wire mem_read_permit_b,mem_write_busy_b,Sdr_rd_en_b,
    input wire App_rd_burst_req, App_rd_en,
    input wire [20:0] App_rd_addr,
    output wire mem_read_permit, mem_write_busy,
    output wire Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout,
    output wire Sdr_init_done,
    output reg [7:0] mem_error_code,
    output wire SDRAM_CLK, SDR_RAS, SDR_CAS, SDR_WE,
    output wire [1:0] SDR_BA,
    output wire [10:0] SDR_ADDR,
    output wire [3:0] SDR_DM,
    inout wire [31:0] SDR_DQ
);
    localparam [2:0] IDLE=0, READ=1, READ_TAIL=2, WRITE=3,
        WRITE_TAIL=4, REF_START=5, REF_WAIT=6, CANCEL_RESET=7;
    localparam [2:0] W_IDLE=0,W_LOAD=1,W_DRAIN=2,W_RELEASE=3,W_CANCEL=4,W_CANCEL_RELEASE=5;
    localparam integer FRAME_BITS=FRAME_WORDS>1 ? $clog2(FRAME_WORDS+1):1;
    localparam integer COLUMN_BITS=ROW_WORDS>1 ? $clog2(ROW_WORDS):1;
    localparam integer SYS_TIMER_BITS=WATCHDOG_CYCLES>1 ? $clog2(WATCHDOG_CYCLES+1):1;
    localparam integer MEM_TIMER_BITS=MEM_WATCHDOG_CYCLES>1 ? $clog2(MEM_WATCHDOG_CYCLES+1):1;
    localparam integer REF_TIMER_BITS=REFRESH_CYCLES>1 ? $clog2(REFRESH_CYCLES+2):1;
    localparam [FRAME_BITS-1:0] FRAME_COUNT=FRAME_WORDS, FRAME_LAST=FRAME_WORDS-1;
    localparam [COLUMN_BITS-1:0] COLUMN_LAST=ROW_WORDS-1;
    localparam [SYS_TIMER_BITS-1:0] SYS_LIMIT=WATCHDOG_CYCLES, SYS_LAST=WATCHDOG_CYCLES-1;
    localparam [MEM_TIMER_BITS-1:0] MEM_LAST=MEM_WATCHDOG_CYCLES-1;
    localparam [REF_TIMER_BITS-1:0] REF_DUE=REFRESH_CYCLES-REFRESH_MARGIN,
        REF_LIMIT=REFRESH_CYCLES, REF_SATURATE=REFRESH_CYCLES+1;
    localparam [20:0] FIRST_OFFSET=WRITE_BOTTOM_UP ? FRAME_WORDS-ROW_WORDS:0;
    localparam [20:0] BANK1_FIRST=FRAME_WORDS+FIRST_OFFSET;
    localparam [20:0] LINE_JUMP=ROW_WORDS*2-1;
    wire config_valid=FRAME_WORDS>0 && FRAME_WORDS*IMAGE_BANK_COUNT<=2097152 && IMAGE_BANK_COUNT>=2 && IMAGE_BANK_COUNT<=6 &&
        READ_DATA_DELAY>=0 && READ_DATA_DELAY<=2 &&
        READ_BURST==256 && WRITE_BURST==128 && FRAME_WORDS%256==0 &&
        (!WRITE_BOTTOM_UP || (ROW_WORDS>0 && ROW_WORDS%128==0 && FRAME_WORDS%ROW_WORDS==0)) &&
        TAIL_CYCLES>=40 && TAIL_CYCLES<=255 && REFRESH_MARGIN>READ_BURST+TAIL_CYCLES+32 &&
        REFRESH_CYCLES>REFRESH_MARGIN+64 && WATCHDOG_CYCLES>1000 && MEM_WATCHDOG_CYCLES>1000;
    reg [2:0] sys_state;
    reg job_req_sys;
    reg cancel_req_sys,cancel_done_mem,cancel_fifo_reset_mem;
    (* async_reg="true" *) reg cancel_meta_mem,cancel_sync_mem,cancel_done_meta_sys,cancel_done_sync_sys;
    reg [FRAME_BITS-1:0] accepted_sys;
    reg [SYS_TIMER_BITS-1:0] sys_watchdog;
    reg [7:0] sys_error_code;
    (* async_reg="true" *) reg req_meta_mem,req_sync_mem;
    (* async_reg="true" *) reg done_meta_sys,done_sync_sys,fault_meta_sys,fault_sync_sys;
    reg job_active_mem,job_done_mem,capture_job_mem;
    reg [BANK_BITS-1:0] bank_mem;
    reg [2:0] state;
    reg [FRAME_BITS-1:0] written_mem;
    reg [REF_TIMER_BITS-1:0] refresh_age;
    reg [MEM_TIMER_BITS-1:0] mem_watchdog;
    reg [COLUMN_BITS-1:0] write_column_mem;
    reg [20:0] write_addr_mem;
    reg [8:0] words_left, outstanding;
    reg [7:0] tail_age;
    reg prefer_read,ref_vld_d,read_owner,prefer_second;
    wire fifo_full,fifo_empty,fifo_valid;
    wire [8:0] fifo_wr_level,fifo_rd_level;
    reg write_stocked_mem;
    wire [31:0] fifo_data;
    wire Sdr_busy,Sdr_init_ref_vld;
    wire fault_mem=mem_error_code!=0;
    wire refresh_due=refresh_age>=REF_DUE;
    wire write_eligible=job_active_mem && !job_done_mem && written_mem<FRAME_COUNT &&
        write_stocked_mem;
    wire start_ready=rst_mem_n && config_valid && !fault_mem && Sdr_init_done &&
        !Sdr_busy && !Sdr_init_ref_vld && !refresh_due && !cancel_sync_mem && !cancel_done_mem;
    wire want_read=App_rd_burst_req || (DUAL_READ && App_rd_burst_req_b);
    wire choose_second=DUAL_READ && App_rd_burst_req_b && (!App_rd_burst_req || prefer_second);
    wire grant_read=state==IDLE && start_ready && want_read &&
        (!write_eligible || prefer_read);
    wire grant_write=state==IDLE && start_ready && write_eligible &&
        (!want_read || !prefer_read);
    wire owner_second=state==IDLE ? choose_second:read_owner;
    assign mem_read_permit=(grant_read || state==READ) && !owner_second && !fault_mem && rst_mem_n;
    assign mem_read_permit_b=(grant_read || state==READ) && owner_second && !fault_mem && rst_mem_n;
    assign mem_write_busy=!(grant_read || state==READ) || owner_second;
    assign mem_write_busy_b=!(grant_read || state==READ) || !owner_second;
    wire read_en_selected=read_owner ? App_rd_en_b:App_rd_en;
    wire [20:0] read_addr_selected=read_owner ? App_rd_addr_b:App_rd_addr;
    reg return_valid;
    wire read_return=return_valid;
    wire any_app_read=App_rd_en || (DUAL_READ && App_rd_en_b);
    wire App_wr_en=state==WRITE && words_left!=0 && !fault_mem && rst_mem_n;
    // Example-5 address scheme: increment within a row, jump at its end.
    wire [20:0] App_wr_addr=write_addr_mem;
    wire App_ref_req=state==REF_START && !fault_mem;
    wire fifo_write=image_write_data_valid_sys && image_write_data_ready_sys;
    assign image_write_start_ready_sys=rst_sys_n && sys_state==W_IDLE &&
        write_allowed_sys && !image_write_error_sys && !image_write_abort_sys && !image_write_abort_ack_sys;
    assign image_write_data_ready_sys=rst_sys_n && sys_state==W_LOAD &&
        accepted_sys<FRAME_COUNT && !fifo_full && !image_write_error_sys && !image_write_abort_sys;
    assign image_write_busy_sys=sys_state!=W_IDLE;
    assign image_write_error_sys=sys_error_code!=0 || fault_sync_sys;
    assign image_write_error_code_sys=sys_error_code!=0 ? sys_error_code:
        (fault_sync_sys ? mem_error_code:8'd0);
    wfifo_32_32_512 write_fifo(.rst(!rst_sys_n || !rst_mem_n || cancel_fifo_reset_mem),
        .clkw(clk_sys),.clkr(clk_mem),.we(fifo_write),.di(image_write_data_sys),
        .re(App_wr_en),.dout(fifo_data),.valid(fifo_valid),.full_flag(fifo_full),
        .empty_flag(fifo_empty),.afull(),.aempty(),.wrusedw(fifo_wr_level),.rdusedw(fifo_rd_level));
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin done_meta_sys<=0;done_sync_sys<=0;fault_meta_sys<=0;fault_sync_sys<=0;
            cancel_done_meta_sys<=0;cancel_done_sync_sys<=0;end
        else begin done_meta_sys<=job_done_mem;done_sync_sys<=done_meta_sys;
            fault_meta_sys<=fault_mem;fault_sync_sys<=fault_meta_sys;
            cancel_done_meta_sys<=cancel_done_mem;cancel_done_sync_sys<=cancel_done_meta_sys;end
    end
    always @(posedge clk_mem or negedge rst_mem_n) begin
        // Only this controller consumes the FIFO, during WRITE. Between
        // bursts its level can only rise, so a one-cycle-old sufficient-stock
        // test is conservative. Clear it while consuming or flushing; the
        // existing tail states give flags time to settle before a new grant.
        if(!rst_mem_n) write_stocked_mem<=0;
        else if(state==WRITE || state==CANCEL_RESET) write_stocked_mem<=0;
        else write_stocked_mem<=fifo_rd_level>=WRITE_BURST && !fifo_empty;
    end
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if(!rst_mem_n) begin req_meta_mem<=0;req_sync_mem<=0;cancel_meta_mem<=0;cancel_sync_mem<=0;end
        else begin req_meta_mem<=job_req_sys;req_sync_mem<=req_meta_mem;
            cancel_meta_mem<=cancel_req_sys;cancel_sync_mem<=cancel_meta_mem;end
    end
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin sys_state<=W_IDLE;job_req_sys<=0;accepted_sys<=0;sys_watchdog<=0;
            sys_error_code<=0;image_prepared_sys<=0;prepared_image_bank_sys<=0;
            cancel_req_sys<=0;image_write_abort_ack_sys<=0;end
        else if(!image_write_error_sys) begin
            if(sys_state==W_IDLE) sys_watchdog<=0;
            else if(sys_watchdog<SYS_LIMIT) sys_watchdog<=sys_watchdog+1'b1;
            if(!config_valid) sys_error_code<=8'd1;
            else if(sys_state!=W_IDLE && sys_watchdog>=SYS_LAST) sys_error_code<=8'd3;
            else if(image_write_abort_sys && sys_state!=W_IDLE && sys_state!=W_CANCEL && sys_state!=W_CANCEL_RELEASE) begin
                image_prepared_sys<=0;cancel_req_sys<=1;sys_state<=W_CANCEL;
            end
            else case(sys_state)
                W_IDLE: begin
                  image_write_abort_ack_sys<=image_write_abort_sys;
                  if(image_write_abort_sys) image_prepared_sys<=0;
                  if(image_write_start_sys && image_write_start_ready_sys) begin
                    if(image_write_bank_sys>=IMAGE_BANK_COUNT || (front_valid_sys && image_write_bank_sys==active_image_bank_sys))
                        sys_error_code<=8'd4;
                    else begin prepared_image_bank_sys<=image_write_bank_sys;image_prepared_sys<=0;
                        accepted_sys<=0;job_req_sys<=1;sys_state<=W_LOAD;end
                  end
                end
                W_LOAD: if(fifo_write) begin
                    accepted_sys<=accepted_sys+1'b1;
                    if(accepted_sys==FRAME_LAST) sys_state<=W_DRAIN;
                end
                W_DRAIN: if(done_sync_sys) begin
                    if(accepted_sys!=FRAME_COUNT) sys_error_code<=8'd2;
                    else begin image_prepared_sys<=1;job_req_sys<=0;sys_state<=W_RELEASE;end
                end
                W_RELEASE: if(!done_sync_sys) sys_state<=W_IDLE;
                W_CANCEL: if(cancel_done_sync_sys) begin
                    image_write_abort_ack_sys<=1;job_req_sys<=0;cancel_req_sys<=0;sys_state<=W_CANCEL_RELEASE;
                end
                W_CANCEL_RELEASE: if(!cancel_done_sync_sys) sys_state<=W_IDLE;
            endcase
        end
    end
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if(!rst_mem_n) begin state<=IDLE;bank_mem<=0;written_mem<=0;job_active_mem<=0;
            job_done_mem<=0;capture_job_mem<=0;words_left<=0;outstanding<=0;
            tail_age<=0;prefer_read<=1;read_owner<=0;prefer_second<=0;refresh_age<=0;ref_vld_d<=0;mem_watchdog<=0;mem_error_code<=0;
            cancel_done_mem<=0;cancel_fifo_reset_mem<=0;write_addr_mem<=0;write_column_mem<=0;end
        else if(!fault_mem) begin
            ref_vld_d<=Sdr_init_ref_vld;
            if(!Sdr_init_done || (Sdr_init_ref_vld && !ref_vld_d)) refresh_age<=0;
            else if(refresh_age<REF_SATURATE) refresh_age<=refresh_age+1'b1;
            if(state==IDLE) mem_watchdog<=0;
            else mem_watchdog<=mem_watchdog+1'b1;
            if(!job_active_mem && req_sync_mem && !cancel_sync_mem && !cancel_done_mem) begin
                if(!capture_job_mem) capture_job_mem<=1;
                else begin bank_mem<=prepared_image_bank_sys;job_active_mem<=1;
                    capture_job_mem<=0;written_mem<=0;
                    write_addr_mem<=prepared_image_bank_sys*FRAME_WORDS+FIRST_OFFSET;
                    write_column_mem<=0;end
            end
            if(job_done_mem && !req_sync_mem) begin job_active_mem<=0;job_done_mem<=0;end
            if(cancel_done_mem && !cancel_sync_mem && !req_sync_mem) cancel_done_mem<=0;
            case({read_en_selected,read_return})
                2'b10:outstanding<=outstanding+1'b1;
                2'b01:outstanding<=outstanding-1'b1;
            endcase
            if(!config_valid) mem_error_code<=8'd1;
            else if(Sdr_init_done && refresh_age>=REF_LIMIT) mem_error_code<=8'd5;
            else if(state!=IDLE && mem_watchdog>=MEM_LAST) mem_error_code<=8'd3;
            else if(any_app_read && state!=READ) mem_error_code<=8'd2;
            else if(read_return && outstanding==0 && !read_en_selected) mem_error_code<=8'd2;
            else if(App_wr_en && (fifo_empty || !fifo_valid)) mem_error_code<=8'd2;
            else case(state)
                IDLE: begin
                    tail_age<=0;
                    if(Sdr_init_done && !Sdr_busy && !Sdr_init_ref_vld && refresh_due) state<=REF_START;
                    else if(cancel_sync_mem && !cancel_done_mem && !Sdr_busy && !Sdr_init_ref_vld && outstanding==0 && !read_return) begin
                        // SYS has stopped writes before the cancellation crosses.
                        // The entire old physical burst AND tail have completed.
                        job_active_mem<=0;job_done_mem<=0;capture_job_mem<=0;
                        cancel_fifo_reset_mem<=1;state<=CANCEL_RESET;
                    end
                    else if(grant_read) begin state<=READ;words_left<=READ_BURST;read_owner<=choose_second;prefer_second<=!choose_second;end
                    else if(grant_write) begin state<=WRITE;words_left<=WRITE_BURST;end
                end
                READ: begin
                    if(!read_en_selected) mem_error_code<=8'd6; // never pause a reserved physical burst
                    else begin words_left<=words_left-1'b1;
                        if(words_left==1) begin state<=READ_TAIL;tail_age<=0;prefer_read<=0;end
                    end
                end
                WRITE: begin
                    written_mem<=written_mem+1'b1;words_left<=words_left-1'b1;
                    if(WRITE_BOTTOM_UP) begin
                        if(write_column_mem==COLUMN_LAST) begin
                            write_column_mem<=0;
                            // No address is issued after the final frame word.
                            write_addr_mem<=write_addr_mem-LINE_JUMP;
                        end else begin
                            write_column_mem<=write_column_mem+1'b1;
                            write_addr_mem<=write_addr_mem+1'b1;
                        end
                    end else write_addr_mem<=write_addr_mem+1'b1;
                    if(words_left==1) begin state<=WRITE_TAIL;tail_age<=0;prefer_read<=1;end
                end
                READ_TAIL,WRITE_TAIL: begin
                    if(tail_age<TAIL_CYCLES) tail_age<=tail_age+1'b1;
                    if(tail_age>=TAIL_CYCLES && outstanding==0 && !read_return && !Sdr_busy && !Sdr_init_ref_vld) begin
                        state<=IDLE;
                        if(state==WRITE_TAIL && written_mem==FRAME_COUNT) job_done_mem<=1;
                    end
                end
                REF_START: state<=REF_WAIT;
                REF_WAIT: begin
                    if(Sdr_init_ref_vld) tail_age<=1;
                    if(tail_age!=0 && !Sdr_init_ref_vld && !Sdr_busy) state<=IDLE;
                end
                CANCEL_RESET: begin
                    // >=16 MEM clocks asserted (128ns), then eight clocks for
                    // FIFO flags to settle. SYS/MEM ports share this reset;
                    // the independent read FIFO and SDRAM are never reset here.
                    tail_age<=tail_age+1'b1;
                    if(tail_age==15) cancel_fifo_reset_mem<=0;
                    if(tail_age==23) begin cancel_done_mem<=1;state<=IDLE;end
                end
                default: mem_error_code<=8'd6;
            endcase
        end
    end
    // Keep the original registered valid, burst counts, owner and drain rules.
    // Address-coded board test: raw return 0 was A80002, expected A80000.
    // A two-cycle DOUT delay passed 16 complete frames (4,915,200 words).
    // Delay all 32 data bits together, including the padding byte. This also
    // retains each burst's final words before the SDRAM page wraps/idle data.
    // FIFO write-valid timing and all downstream public interfaces are unchanged.
    wire core_rd_valid;
    wire [31:0] core_rd_data;
    reg [31:0] read_data_d1,read_data_d2;
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if(!rst_mem_n) begin read_data_d1<=0;read_data_d2<=0;end
        else begin read_data_d1<=core_rd_data;read_data_d2<=read_data_d1;end
    end
    assign Sdr_rd_dout=READ_DATA_DELAY==2 ? read_data_d2:
        READ_DATA_DELAY==1 ? read_data_d1:core_rd_data;
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if(!rst_mem_n) return_valid<=1'b0;
        else return_valid<=core_rd_valid;
    end
    assign Sdr_rd_en=return_valid && !read_owner;
    assign Sdr_rd_en_b=return_valid && read_owner;
    sdr_as_ram #(.self_refresh_open(1'b0)) core(
        .Sdr_clk(clk_mem),.Sdr_clk_sft(clk_mem_sft),.Rst(!rst_mem_n),
        .Sdr_init_done(Sdr_init_done),.Sdr_init_ref_vld(Sdr_init_ref_vld),.Sdr_busy(Sdr_busy),
        .App_ref_req(App_ref_req),.App_wr_en(App_wr_en),.App_wr_addr(App_wr_addr),
        .App_wr_dm(4'b0000),.App_wr_din(fifo_data),.App_rd_en(read_en_selected),.App_rd_addr(read_addr_selected),
        .Sdr_rd_en(core_rd_valid),.Sdr_rd_dout(core_rd_data),.SDRAM_CLK(SDRAM_CLK),
        .SDR_RAS(SDR_RAS),.SDR_CAS(SDR_CAS),.SDR_WE(SDR_WE),.SDR_BA(SDR_BA),
        .SDR_ADDR(SDR_ADDR),.SDR_DM(SDR_DM),.SDR_DQ(SDR_DQ));
`ifndef SIMULATION
    EG_PHY_SDRAM_2M_32 memory(.clk(SDRAM_CLK),.ras_n(SDR_RAS),.cas_n(SDR_CAS),.we_n(SDR_WE),
        .addr(SDR_ADDR),.ba(SDR_BA),.dq(SDR_DQ),.cs_n(1'b0),.cke(1'b1),
        .dm0(SDR_DM[0]),.dm1(SDR_DM[1]),.dm2(SDR_DM[2]),.dm3(SDR_DM[3]));
`endif
endmodule
