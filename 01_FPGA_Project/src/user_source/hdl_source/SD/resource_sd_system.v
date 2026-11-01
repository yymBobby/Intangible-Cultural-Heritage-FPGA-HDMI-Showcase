`timescale 1ns/1ps
// C's single-clock TF-card resource front end. Board top supplies clk_sys and
// a domain-safe rst_sys_n; legacy SD logic uses the inverted active-high reset.
// This is not the finished A/B/theme-controller top-level integration.
module resource_sd_system #(
    parameter [15:0] SPI_LOW_SPEED_DIV = 16'd248,
    parameter [15:0] SPI_HIGH_SPEED_DIV = 16'd0,
    parameter [31:0] CMD58_TIMEOUT_CYCLES = 32'd100000000,
    parameter [31:0] INIT_TIMEOUT = 32'd300000000,
    parameter [31:0] SECTOR_TIMEOUT = 32'd1000000,
    // Leave room for adapter completion to propagate through the outer
    // sector deadline. Late request acceptance can still exhaust the outer
    // deadline first and must be handled by coordinated reset.
    parameter [31:0] ADAPTER_READ_TIMEOUT =
        SECTOR_TIMEOUT > 32'd16384 ? SECTOR_TIMEOUT - 32'd1024 :
        (SECTOR_TIMEOUT > 32'd64 ? SECTOR_TIMEOUT - (SECTOR_TIMEOUT >> 4) :
         (SECTOR_TIMEOUT > 32'd4 ? SECTOR_TIMEOUT - 32'd4 : 32'd1)),
    parameter [31:0] RECOVERY_DRAIN_TIMEOUT = 32'd100000000
) (
    input wire clk_sys,
    input wire rst_sys_n,
    output wire SD_nCS,
    output wire SD_DCLK,
    output wire SD_MOSI,
    input wire SD_MISO,
    output wire sd_init_done,
    output wire [2:0] sd_init_error,
    output wire service_ready,
    output wire [7:0] service_error,
    output wire recovery_req,
    input wire [3:0] query_theme_id,
    output wire query_valid,
    output wire [7:0] query_flags,
    output wire [31:0] query_display_time_ms,
    output wire [31:0] query_image_bytes,
    output wire [31:0] query_audio_bytes,
    output wire [31:0] query_text_bytes,
    output wire [31:0] font_set_id,
    output wire [31:0] glyph_count,
    input wire img_req_valid,
    output wire img_req_ready,
    input wire [7:0] img_req_resource_id,
    input wire [31:0] img_req_block_index,
    output wire img_data_valid,
    input wire img_data_ready,
    output wire [7:0] img_data,
    output wire img_data_last,
    output wire img_file_last,
    output wire img_rsp_valid,
    input wire img_rsp_ready,
    output wire [2:0] img_rsp_status,
    input wire aud_req_valid,
    output wire aud_req_ready,
    input wire [7:0] aud_req_resource_id,
    input wire [31:0] aud_req_block_index,
    output wire aud_data_valid,
    input wire aud_data_ready,
    output wire [7:0] aud_data,
    output wire aud_data_last,
    output wire aud_file_last,
    output wire aud_rsp_valid,
    input wire aud_rsp_ready,
    output wire [2:0] aud_rsp_status,
    input wire audio_urgent
);
    wire sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire [7:0] sd_sec_read_data;
    wire sd_sec_read_data_valid, sd_sec_read_end, sd_sec_read_error;
    wire adapter_req_ready, adapter_data_valid, adapter_done, adapter_error;
    wire [7:0] adapter_data;
    wire adapter_req_valid;
    wire [31:0] adapter_req_lba;
    wire boot_req_valid, boot_req_ready;
    wire [31:0] boot_req_lba;
    wire boot_ready;
    wire [7:0] boot_error;
    wire service_req_valid, service_req_ready;
    wire [31:0] service_req_lba;
    wire catalog_ready;
    wire catalog_we, catalog_commit;
    wire [3:0] catalog_theme_id;
    wire [4:0] catalog_theme_count;
    wire [7:0] catalog_flags;
    wire [31:0] catalog_image_lba, catalog_image_bytes;
    wire [31:0] catalog_audio_lba, catalog_audio_bytes;
    wire [31:0] catalog_text_lba, catalog_text_bytes;

    // The legacy controller has no read-ready pin. The adapter emits one
    // launch pulse and blocks every later request until completion or reset.
    sd_card_top #(
        .SPI_LOW_SPEED_DIV(SPI_LOW_SPEED_DIV),
        .SPI_HIGH_SPEED_DIV(SPI_HIGH_SPEED_DIV),
        .CMD58_TIMEOUT_CYCLES(CMD58_TIMEOUT_CYCLES)
    ) card (
        .clk(clk_sys), .rst(~rst_sys_n), .SD_nCS(SD_nCS),
        .SD_DCLK(SD_DCLK), .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO),
        .sd_init_done(sd_init_done), .sd_init_error(sd_init_error),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .sd_sec_read_error(sd_sec_read_error),
        .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0),
        .sd_sec_write_data(8'd0), .sd_sec_write_data_req(),
        .sd_sec_write_end()
    );

    assign adapter_req_valid = boot_ready ? service_req_valid : boot_req_valid;
    assign adapter_req_lba = boot_ready ? service_req_lba : boot_req_lba;
    assign boot_req_ready = !boot_ready && adapter_req_ready;
    assign service_req_ready = boot_ready && adapter_req_ready;

    sd_sector_adapter #(.READ_TIMEOUT(ADAPTER_READ_TIMEOUT)) adapter (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n),
        .sd_init_done(sd_init_done), .sd_init_error(sd_init_error),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .sd_sec_read_error(sd_sec_read_error),
        .sec_req_ready(adapter_req_ready), .sec_req_valid(adapter_req_valid),
        .sec_req_lba(adapter_req_lba), .sec_data_valid(adapter_data_valid),
        .sec_data(adapter_data), .sec_done(adapter_done),
        .sec_error(adapter_error), .fault()
    );

    resource_catalog_loader #(
        .INIT_TIMEOUT(INIT_TIMEOUT), .SECTOR_TIMEOUT(SECTOR_TIMEOUT)
    ) catalog (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n),
        .sd_init_done(sd_init_done), .sd_init_error(sd_init_error),
        .sec_req_valid(boot_req_valid), .sec_req_ready(boot_req_ready),
        .sec_req_lba(boot_req_lba), .sec_data_valid(adapter_data_valid),
        .sec_data(adapter_data), .sec_done(adapter_done),
        .sec_error(adapter_error), .catalog_ready(catalog_ready), .catalog_we(catalog_we),
        .catalog_theme_id(catalog_theme_id), .catalog_flags(catalog_flags),
        .catalog_image_lba(catalog_image_lba),
        .catalog_image_bytes(catalog_image_bytes),
        .catalog_audio_lba(catalog_audio_lba),
        .catalog_audio_bytes(catalog_audio_bytes),
        .catalog_text_lba(catalog_text_lba),
        .catalog_text_bytes(catalog_text_bytes),
        .catalog_commit(catalog_commit),
        .catalog_theme_count(catalog_theme_count),
        .catalog_error(boot_error), .ready(boot_ready),
        .query_theme_id(query_theme_id), .query_valid(query_valid),
        .query_flags(query_flags),
        .query_display_time_ms(query_display_time_ms),
        .query_image_bytes(query_image_bytes),
        .query_audio_bytes(query_audio_bytes),
        .query_text_bytes(query_text_bytes),
        .font_set_id(font_set_id), .glyph_count(glyph_count)
    );

    resource_sd_service #(
        .SECTOR_TIMEOUT(SECTOR_TIMEOUT),
        .RECOVERY_DRAIN_TIMEOUT(RECOVERY_DRAIN_TIMEOUT)
    ) service (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n),
        .catalog_ready(catalog_ready), .catalog_we(catalog_we), .catalog_theme_id(catalog_theme_id),
        .catalog_flags(catalog_flags),
        .catalog_image_lba(catalog_image_lba),
        .catalog_image_bytes(catalog_image_bytes),
        .catalog_audio_lba(catalog_audio_lba),
        .catalog_audio_bytes(catalog_audio_bytes),
        .catalog_text_lba(catalog_text_lba),
        .catalog_text_bytes(catalog_text_bytes),
        .catalog_commit(catalog_commit),
        .catalog_theme_count(catalog_theme_count),
        .catalog_error(boot_error), .service_ready(service_ready),
        .service_error(service_error), .recovery_req(recovery_req),
        .img_req_valid(img_req_valid), .img_req_ready(img_req_ready),
        .img_req_resource_id(img_req_resource_id),
        .img_req_block_index(img_req_block_index),
        .img_data_valid(img_data_valid), .img_data_ready(img_data_ready),
        .img_data(img_data), .img_data_last(img_data_last),
        .img_file_last(img_file_last), .img_rsp_valid(img_rsp_valid),
        .img_rsp_ready(img_rsp_ready), .img_rsp_status(img_rsp_status),
        .aud_req_valid(aud_req_valid), .aud_req_ready(aud_req_ready),
        .aud_req_resource_id(aud_req_resource_id),
        .aud_req_block_index(aud_req_block_index),
        .aud_data_valid(aud_data_valid), .aud_data_ready(aud_data_ready),
        .aud_data(aud_data), .aud_data_last(aud_data_last),
        .aud_file_last(aud_file_last), .aud_rsp_valid(aud_rsp_valid),
        .aud_rsp_ready(aud_rsp_ready), .aud_rsp_status(aud_rsp_status),
        .audio_urgent(audio_urgent),
        .sec_req_valid(service_req_valid), .sec_req_ready(service_req_ready),
        .sec_req_lba(service_req_lba), .sec_data_valid(adapter_data_valid),
        .sec_data(adapter_data), .sec_done(adapter_done),
        .sec_error(adapter_error)
    );
endmodule
