`timescale 1ns/1ps
// ICHSHOW2 v2 boot-time catalog validator. All ports use clk_sys.
// It owns the physical sector port until catalog_commit. It deliberately
// never treats a copied FAT file as a raw image or guesses card capacity.
module resource_catalog_loader #(
    parameter [31:0] INIT_TIMEOUT = 32'd300000000,
    parameter [31:0] SECTOR_TIMEOUT = 32'd1000000
) (
    input wire clk_sys,
    input wire rst_sys_n,
    input wire sd_init_done,
    input wire [2:0] sd_init_error,
    output wire sec_req_valid,
    input wire sec_req_ready,
    output wire [31:0] sec_req_lba,
    input wire sec_data_valid,
    input wire [7:0] sec_data,
    input wire sec_done,
    input wire sec_error,
    output wire catalog_we,
    input wire catalog_ready,
    output wire [3:0] catalog_theme_id,
    output wire [7:0] catalog_flags,
    output wire [31:0] catalog_image_lba,
    output wire [31:0] catalog_image_bytes,
    output wire [31:0] catalog_audio_lba,
    output wire [31:0] catalog_audio_bytes,
    output wire [31:0] catalog_text_lba,
    output wire [31:0] catalog_text_bytes,
    output wire catalog_commit,
    output wire [4:0] catalog_theme_count,
    output reg [7:0] catalog_error,
    output wire ready,
    input wire [3:0] query_theme_id,
    output wire query_valid,
    output wire [7:0] query_flags,
    output wire [31:0] query_display_time_ms,
    output wire [31:0] query_image_bytes,
    output wire [31:0] query_audio_bytes,
    output wire [31:0] query_text_bytes,
    output wire [31:0] font_set_id,
    output wire [31:0] glyph_count
);
    localparam [4:0] S_INIT = 5'd0, S_ISSUE = 5'd1, S_READ = 5'd2,
                     S_HEADER = 5'd3, S_CRC = 5'd5, S_RECORD = 5'd6,
                     S_SAVE = 5'd8, S_COMPARE = 5'd9, S_PUBLISH = 5'd10,
                     S_COMMIT = 5'd11, S_READY = 5'd12, S_ERROR = 5'd13,
                     S_INDEX_ADDR = 5'd14, S_INDEX_CAPTURE = 5'd15,
                     S_VALIDATE = 5'd16,
                     S_RANGE_A_ADDR = 5'd17, S_RANGE_A_CAPTURE = 5'd18,
                     S_RANGE_B_ADDR = 5'd19, S_RANGE_B_CAPTURE = 5'd20,
                     S_BLOCKS = 5'd21, S_ENDS = 5'd22;
    localparam [31:0] INIT_LIMIT = INIT_TIMEOUT == 0 ? 32'd1 : INIT_TIMEOUT;
    localparam [31:0] SECTOR_LIMIT = SECTOR_TIMEOUT == 0 ? 32'd1 : SECTOR_TIMEOUT;

    reg [4:0] state;
    reg [1:0] sector_number;
    reg [9:0] byte_count;
    reg [4:0] record_number, theme_count_reg;
    reg [5:0] range_a, range_b;
    reg [31:0] init_timer, sector_timer, crc;
    // Keep only fields consumed after transport. CRC still covers all 1024
    // index bytes; reserved/unused bytes are checked as they stream in.
    // Fixed header bytes are checked during transport, while the five
    // dynamic 32-bit words retain their complete protocol widths. Report a
    // fixed-byte fault only in S_HEADER, preserving boot error priority.
    reg header_fixed_bad;
    reg [31:0] header_theme_count, header_declared_end, header_index_crc;
    reg [31:0] header_font_set_id, header_glyph_count;
    reg header_reserved_bad;
    reg [15:0] record_reserved_bad, record_nonzero;
    // Single-port BRAMs: write during transport/save, read in address/capture
    // states. NOREG still has a synchronous read; capture is the next edge.
    reg [4:0] record_byte;
    reg publish_mode;
    reg [1:0] save_slot;
    // Four fixed 18-bit words hold one complete 67-bit range. Only boot uses
    // this port; runtime queries keep their existing index RAM timing.
    reg [1:0] range_word;
    reg [7:0] current_id, current_flags;
    reg [31:0] current_image_lba, current_image_bytes;
    reg [31:0] current_audio_lba, current_audio_bytes;
    reg [31:0] current_display_time_ms;
    reg [31:0] current_text_lba, current_text_bytes;
    reg [66:0] compare_range_a, compare_range_b;
    // The validated index already contains every query field. Reuse its BRAM
    // after boot instead of maintaining a second register table. The caller
    // holds query_theme_id until query_valid; completed results stay cached
    // for that ID. An ID change masks the old result immediately.
    localparam [1:0] Q_IDLE=0, Q_ADDR=1, Q_CAPTURE=2, Q_DONE=3;
    reg catalog_committed, query_complete;
    // Reuse the boot address/capture states and record address counters too.
    // These wires retain convenient waveform names, without extra registers.
    wire [1:0] query_state = !ready ? Q_IDLE : state==S_INDEX_ADDR ? Q_ADDR :
                             state==S_INDEX_CAPTURE ? Q_CAPTURE : query_complete ? Q_DONE : Q_IDLE;
    wire [3:0] query_theme_hold = record_number[3:0];
    wire [4:0] query_byte = record_byte;
    wire query_id_valid = {1'b0, query_theme_id} < theme_count_reg;
    wire query_ram_read = rst_sys_n && ready && query_id_valid &&
                          query_state == Q_ADDR && query_theme_hold == query_theme_id;
    wire record_capture = state == S_INDEX_CAPTURE &&
                          (!ready || (query_id_valid && query_theme_hold==query_theme_id));
    wire [4:0] capture_byte = record_byte;
    reg [23:0] image_blocks, audio_blocks, text_blocks;
    reg [32:0] image_end, audio_end, text_end;
    reg [5:0] range_last, range_penultimate;

    wire index_ram_we = rst_sys_n && state == S_READ && sec_data_valid &&
                        byte_count < 10'd512 && sector_number != 2'd0 &&
                        byte_count[5:0] < 6'd32;
    wire index_ram_ce = index_ram_we || (rst_sys_n && state == S_INDEX_ADDR && !ready) || query_ram_read;
    wire [8:0] index_ram_addr = index_ram_we ?
        {~sector_number[0], byte_count[8:6], byte_count[4:0]} :
        {record_number[3:0], record_byte};
    wire [7:0] index_ram_data;
    CATALOG_INDEX_RAM u_index_ram (
        .clka(clk_sys), .cea(index_ram_ce), .wea(index_ram_we),
        .addra(index_ram_addr), .dia(sec_data), .doa(index_ram_data)
    );

    wire [5:0] range_write_base = {record_number[3:0], 1'b0} +
                                   {2'b0, record_number[3:0]};
    wire range_ram_we = rst_sys_n && state == S_SAVE;
    wire range_ram_ce = range_ram_we || (rst_sys_n &&
        (state == S_RANGE_A_ADDR || state == S_RANGE_B_ADDR));
    wire [5:0] range_entry = range_ram_we ?
        range_write_base + {4'b0, save_slot} :
        (state == S_RANGE_A_ADDR ? range_a : range_b);
    wire [7:0] range_ram_addr = {range_entry, range_word};
    wire [66:0] range_record = save_slot == 2'd0 ?
        {1'b1, 1'b0, current_image_lba, image_end} :
        save_slot == 2'd1 ?
        {current_flags[1], 1'b0, current_audio_lba, audio_end} :
        {1'b1, 1'b0, current_text_lba, text_end};
    wire [17:0] range_ram_din = range_word == 2'd0 ? range_record[17:0] :
                               range_word == 2'd1 ? range_record[35:18] :
                               range_word == 2'd2 ? range_record[53:36] :
                               {5'd0, range_record[66:54]};
    wire [17:0] range_ram_data;
    CATALOG_RANGE_RAM u_range_ram (
        .clka(clk_sys), .cea(range_ram_ce), .wea(range_ram_we),
        .addra(range_ram_addr), .dia(range_ram_din), .doa(range_ram_data)
    );

    function [7:0] fixed_header_byte;
        input [5:0] index;
        begin
            case(index)
                0:fixed_header_byte="I";1:fixed_header_byte="C";
                2:fixed_header_byte="H";3:fixed_header_byte="S";
                4:fixed_header_byte="H";5:fixed_header_byte="O";
                6:fixed_header_byte="W";7:fixed_header_byte="2";
                8:fixed_header_byte=8'd2;
                13:fixed_header_byte=8'd2;
                20:fixed_header_byte=8'd64;
                24:fixed_header_byte=8'd1;
                28:fixed_header_byte=8'd2;
                33:fixed_header_byte=8'd8;
                default:fixed_header_byte=8'd0;
            endcase
        end
    endfunction
    function [31:0] crc_byte;
        input [31:0] old_crc;
        input [7:0] value;
        reg [31:0] next_crc;
        integer bit_number;
        begin
            next_crc = old_crc ^ {24'd0, value};
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1)
                next_crc = next_crc[0] ?
                           ((next_crc >> 1) ^ 32'hedb88320) : (next_crc >> 1);
            crc_byte = next_crc;
        end
    endfunction

    wire [5:0] range_count = {theme_count_reg, 1'b0} + {1'b0, theme_count_reg};
    // Separate rounded block count, 33-bit LBA addition and bounds checks.
    // The 24-bit count represents ceil(FFFFFFFF/512)=00800000 exactly.
    wire [32:0] declared_end = {1'b0, header_declared_end};

    assign sec_req_valid = state == S_ISSUE;
    assign sec_req_lba = {30'd0, sector_number};
    assign catalog_we = state == S_PUBLISH;
    assign catalog_commit = state == S_COMMIT;
    assign catalog_theme_id = record_number[3:0];
    assign catalog_theme_count = theme_count_reg;
    assign catalog_flags = current_flags;
    assign catalog_image_lba = current_image_lba;
    assign catalog_image_bytes = current_image_bytes;
    assign catalog_audio_lba = current_audio_lba;
    assign catalog_audio_bytes = current_audio_bytes;
    assign catalog_text_lba = current_text_lba;
    assign catalog_text_bytes = current_text_bytes;
    assign ready = catalog_committed;
    // A completed query was admitted only after the ID bounds check. Until
    // reset, theme_count is immutable; equality masks an ID change at once.
    // Rechecking that bound here adds a carry chain to every result consumer.
    assign query_valid = rst_sys_n && ready &&
                         query_complete && query_theme_hold == query_theme_id;
    assign query_flags = query_valid ? current_flags : 8'd0;
    assign query_display_time_ms = query_valid ? current_display_time_ms : 32'd0;
    assign query_image_bytes = query_valid ? current_image_bytes : 32'd0;
    assign query_audio_bytes = query_valid ? current_audio_bytes : 32'd0;
    assign query_text_bytes = query_valid ? current_text_bytes : 32'd0;
    assign font_set_id = ready ? header_font_set_id : 32'd0;
    assign glyph_count = ready ? header_glyph_count : 32'd0;

    // NOREG BRAM still reads on a clock edge. Capture on the following edge;
    // never combine bytes from different IDs, resets or boot generations.
    // Offsets: flags 1, image bytes 8..11, audio bytes 16..19,
    // display time 20..23, subtitle bytes 28..31 (17 reads, 35 cycles).
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            state <= S_INIT;
            sector_number <= 2'd0;
            byte_count <= 10'd0;
            record_number <= 5'd0;
            theme_count_reg <= 5'd0;
            range_a <= 6'd0;
            range_b <= 6'd1;
            init_timer <= 32'd0;
            sector_timer <= 32'd0;
            crc <= 32'hffffffff;
            catalog_error <= 8'd0;
            header_fixed_bad <= 1'b0;
            header_reserved_bad <= 1'b0;
            record_reserved_bad <= 16'd0;
            record_nonzero <= 16'd0;
            record_byte <= 5'd0;
            publish_mode <= 1'b0;
            save_slot <= 2'd0;
            range_word <= 2'd0;
            current_id <= 8'd0;
            current_flags <= 8'd0;
            current_image_lba <= 32'd0;
            current_image_bytes <= 32'd0;
            current_audio_lba <= 32'd0;
            current_audio_bytes <= 32'd0;
            current_display_time_ms <= 32'd0;
            current_text_lba <= 32'd0;
            current_text_bytes <= 32'd0;
            compare_range_a <= 67'd0;
            compare_range_b <= 67'd0;
            catalog_committed <= 1'b0;
            query_complete <= 1'b0;
            image_blocks<=0;audio_blocks<=0;text_blocks<=0;
            image_end<=0;audio_end<=0;text_end<=0;
            range_last<=0;range_penultimate<=0;
            // No RAM/table reset: every valid entry is overwritten this boot,
            // and ready/query_valid gate access until validation and commit.
        end else begin
            // Boot and runtime use the same field registers and byte shifter.
            // Every 32-bit field is fully overwritten before it is consumed.
            // This avoids variable byte-lane writes and a second result bank.
            if (record_capture) case(capture_byte[4:2])
                0: begin
                    if(capture_byte[1:0]==0) current_id<=index_ram_data;
                    if(capture_byte[1:0]==1) current_flags<=index_ram_data;
                end
                1: current_image_lba<={index_ram_data,current_image_lba[31:8]};
                2: current_image_bytes<={index_ram_data,current_image_bytes[31:8]};
                3: current_audio_lba<={index_ram_data,current_audio_lba[31:8]};
                4: current_audio_bytes<={index_ram_data,current_audio_bytes[31:8]};
                5: current_display_time_ms<={index_ram_data,current_display_time_ms[31:8]};
                6: current_text_lba<={index_ram_data,current_text_lba[31:8]};
                7: current_text_bytes<={index_ram_data,current_text_bytes[31:8]};
            endcase
            if(ready && (!query_id_valid || query_theme_hold!=query_theme_id)) begin
                query_complete<=0;
                record_number<={1'b0,query_theme_id};
                record_byte<=1;
                state<=query_id_valid ? S_INDEX_ADDR : S_READY;
            end else case (state)
                S_INIT: begin
                    if (sd_init_error != 0) begin
                        catalog_error <= 8'd1;
                        state <= S_ERROR;
                    end else if (sd_init_done) begin
                        sector_timer <= 32'd0;
                        state <= S_ISSUE;
                    end else if (init_timer >= INIT_LIMIT - 32'd1) begin
                        catalog_error <= 8'd1;
                        state <= S_ERROR;
                    end else
                        init_timer <= init_timer + 32'd1;
                end
                S_ISSUE: begin
                    if (sd_init_error != 0 || !sd_init_done ||
                        sector_timer >= SECTOR_LIMIT - 32'd1) begin
                        catalog_error <= 8'd5;
                        state <= S_ERROR;
                    end else if (sec_req_ready) begin
                        byte_count <= 10'd0;
                        sector_timer <= sector_timer + 32'd1;
                        state <= S_READ;
                    end else
                        sector_timer <= sector_timer + 32'd1;
                end
                S_READ: begin
                    if (sec_data_valid) begin
                        if (byte_count < 10'd512) begin
                            if (sector_number == 2'd0) begin
                                if (byte_count < 10'd52) begin
                                    // Sequential bytes form the complete
                                    // little-endian word after four writes.
                                    case(byte_count[5:2])
                                        4:header_theme_count<={sec_data,header_theme_count[31:8]};
                                        9:header_declared_end<={sec_data,header_declared_end[31:8]};
                                        10:header_index_crc<={sec_data,header_index_crc[31:8]};
                                        11:header_font_set_id<={sec_data,header_font_set_id[31:8]};
                                        12:header_glyph_count<={sec_data,header_glyph_count[31:8]};
                                        default:if(sec_data!=fixed_header_byte(byte_count[5:0]))
                                            header_fixed_bad<=1'b1;
                                    endcase
                                end
                                else if (sec_data != 0)
                                    header_reserved_bad <= 1'b1;
                            end else begin
                                if (sec_data != 0) begin
                                    record_nonzero[{~sector_number[0], byte_count[8:6]}] <= 1'b1;
                                    if (byte_count[5:0] == 6'd2 || byte_count[5:0] == 6'd3 ||
                                        byte_count[5:0] >= 6'd32)
                                        record_reserved_bad[{~sector_number[0], byte_count[8:6]}] <= 1'b1;
                                end
                                crc <= crc_byte(crc, sec_data);
                            end
                            byte_count <= byte_count + 10'd1;
                        end else
                            byte_count <= 10'd513;
                    end
                    if (sd_init_error != 0 || !sd_init_done) begin
                        catalog_error <= 8'd5;
                        state <= S_ERROR;
                    end else if (sec_done) begin
                        if (sec_error || byte_count + {9'd0, sec_data_valid} != 10'd512) begin
                            catalog_error <= 8'd5;
                            state <= S_ERROR;
                        end else if (sector_number == 2'd2) begin
                            state <= S_HEADER;
                        end else begin
                            sector_number <= sector_number + 2'd1;
                            sector_timer <= 32'd0;
                            state <= S_ISSUE;
                        end
                    end else if (sector_timer >= SECTOR_LIMIT - 32'd1) begin
                        catalog_error <= 8'd5;
                        state <= S_ERROR;
                    end else
                        sector_timer <= sector_timer + 32'd1;
                end
                S_HEADER: begin
                    if (header_fixed_bad ||
                        header_theme_count < 32'd1 || header_theme_count > 32'd16 ||
                        header_declared_end <= 32'd2048 || header_font_set_id == 32'd0 ||
                        header_glyph_count < 32'd1 || header_glyph_count > 32'd512 ||
                         header_reserved_bad) begin
                        catalog_error <= 8'd2;
                        state <= S_ERROR;
                    end else begin
                        theme_count_reg <= header_theme_count;
                        state <= S_CRC;
                    end
                end
                S_CRC: begin
                    range_last<=range_count-6'd1;
                    range_penultimate<=range_count-6'd2;
                    if ((~crc) != header_index_crc) begin
                        catalog_error <= 8'd3;
                        state <= S_ERROR;
                    end else begin
                        record_number <= 5'd0;
                        state <= S_RECORD;
                    end
                end
                S_RECORD: begin
                    if (record_number == 5'd16) begin
                        range_a <= 6'd0;
                        range_b <= 6'd1;
                        range_word <= 2'd0;
                        state <= S_RANGE_A_ADDR;
                    end else if (record_number >= theme_count_reg) begin
                        if (record_nonzero[record_number[3:0]]) begin
                            catalog_error <= 8'd2;
                            state <= S_ERROR;
                        end else
                            record_number <= record_number + 5'd1;
                    end else begin
                        record_byte <= 5'd0;
                        state <= S_INDEX_ADDR;
                    end
                end
                S_INDEX_ADDR: state <= S_INDEX_CAPTURE;
                S_INDEX_CAPTURE: begin
                    // record_capture above assembles the complete field.
                    if(ready) begin
                        if(record_byte==31) begin query_complete<=1;state<=S_READY;end
                        else begin
                            record_byte<=record_byte==1 ? 5'd8 :
                                         record_byte==11 ? 5'd16 :
                                         record_byte==23 ? 5'd28 : record_byte+1'b1;
                            state<=S_INDEX_ADDR;
                        end
                    end else if (record_byte == 5'd31)
                        state <= publish_mode ? S_PUBLISH : S_BLOCKS;
                    else begin
                        record_byte <= record_byte + 5'd1;
                        state <= S_INDEX_ADDR;
                    end
                end
                S_BLOCKS: begin
                    image_blocks<={1'b0,current_image_bytes[31:9]}+{23'd0,|current_image_bytes[8:0]};
                    audio_blocks<={1'b0,current_audio_bytes[31:9]}+{23'd0,|current_audio_bytes[8:0]};
                    text_blocks<={1'b0,current_text_bytes[31:9]}+{23'd0,|current_text_bytes[8:0]};
                    state<=S_ENDS;
                end
                S_ENDS: begin
                    image_end<={1'b0,current_image_lba}+{9'd0,image_blocks};
                    audio_end<={1'b0,current_audio_lba}+{9'd0,audio_blocks};
                    text_end<={1'b0,current_text_lba}+{9'd0,text_blocks};
                    state<=S_VALIDATE;
                end
                S_VALIDATE: begin
                    if (current_id != {3'd0, record_number} ||
                                  current_flags[7:3] != 0 ||
                                  !current_flags[0] || !current_flags[2] ||
                                  record_reserved_bad[record_number[3:0]] ||
                                 current_image_bytes == 0 ||
                                 current_text_bytes < 32'd24 ||
                                 current_text_bytes > 32'd152 ||
                                 current_text_bytes[0] ||
                                 (!current_flags[1] &&
                                  (current_audio_lba != 0 || current_audio_bytes != 0)) ||
                                 (current_flags[1] && current_audio_bytes == 0)) begin
                        catalog_error <= 8'd2;
                        state <= S_ERROR;
                    end else if (current_image_lba < 32'd2048 ||
                                 current_text_lba < 32'd2048 ||
                                 (current_flags[1] && current_audio_lba < 32'd2048) ||
                                 image_end > declared_end || text_end > declared_end ||
                                 (current_flags[1] && audio_end > declared_end)) begin
                        catalog_error <= 8'd4;
                        state <= S_ERROR;
                    end else begin
                        save_slot <= 2'd0;
                        range_word <= 2'd0;
                        state <= S_SAVE;
                    end
                end
                S_SAVE: begin
                    range_word <= range_word + 2'd1;
                    if (range_word == 2'd3) begin
                        if (save_slot == 2'd2) begin
                            record_number <= record_number + 5'd1;
                            state <= S_RECORD;
                        end else save_slot <= save_slot + 2'd1;
                    end
                end
                S_RANGE_A_ADDR: state <= S_RANGE_A_CAPTURE;
                S_RANGE_A_CAPTURE: begin
                    case (range_word)
                        0: compare_range_a[17:0] <= range_ram_data;
                        1: compare_range_a[35:18] <= range_ram_data;
                        2: compare_range_a[53:36] <= range_ram_data;
                        3: compare_range_a[66:54] <= range_ram_data[12:0];
                    endcase
                    range_word <= range_word + 2'd1;
                    state <= range_word == 2'd3 ? S_RANGE_B_ADDR : S_RANGE_A_ADDR;
                end
                S_RANGE_B_ADDR: state <= S_RANGE_B_CAPTURE;
                S_RANGE_B_CAPTURE: begin
                    case (range_word)
                        0: compare_range_b[17:0] <= range_ram_data;
                        1: compare_range_b[35:18] <= range_ram_data;
                        2: compare_range_b[53:36] <= range_ram_data;
                        3: compare_range_b[66:54] <= range_ram_data[12:0];
                    endcase
                    range_word <= range_word + 2'd1;
                    state <= range_word == 2'd3 ? S_COMPARE : S_RANGE_B_ADDR;
                end
                S_COMPARE: begin
                    if (compare_range_a[66] && compare_range_b[66] &&
                        compare_range_a[65:33] < compare_range_b[32:0] &&
                        compare_range_b[65:33] < compare_range_a[32:0]) begin
                        catalog_error <= 8'd4;
                        state <= S_ERROR;
                    end else if (range_a == range_penultimate &&
                                 range_b == range_last) begin
                        record_number <= 5'd0;
                        record_byte <= 5'd0;
                        publish_mode <= 1'b1;
                        state <= S_INDEX_ADDR;
                    end else if (range_b == range_last) begin
                        range_a <= range_a + 6'd1;
                        range_b <= range_a + 6'd2;
                        state <= S_RANGE_A_ADDR;
                    end else begin
                        range_b <= range_b + 6'd1;
                        state <= S_RANGE_B_ADDR;
                    end
                end
                // Descriptor registers remain stable for all twelve service writes.
                S_PUBLISH: if (catalog_ready) begin
                    if (record_number + 5'd1 == theme_count_reg)
                        state <= S_COMMIT;
                    else begin
                        record_number <= record_number + 5'd1;
                        record_byte <= 5'd0;
                        state <= S_INDEX_ADDR;
                    end
                end
                S_COMMIT: begin catalog_committed<=1;state<=S_READY;end
                S_READY: if(query_id_valid && !query_complete) begin
                    record_number<={1'b0,query_theme_id};record_byte<=1;state<=S_INDEX_ADDR;
                end
                S_ERROR: state <= S_ERROR;
                default: state <= S_ERROR;
            endcase
        end
    end
endmodule
