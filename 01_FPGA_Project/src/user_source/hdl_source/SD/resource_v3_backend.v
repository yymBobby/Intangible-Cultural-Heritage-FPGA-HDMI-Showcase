`timescale 1ns/1ps
// Standalone v3 backend: connect physical sector pins to sd_sector_adapter.
// Not automatically registered in the Ultimate project; no new board pins.
module resource_v3_backend #(
    parameter [31:0] INIT_TIMEOUT=32'd300000000,
    parameter [31:0] SECTOR_TIMEOUT=32'd1000000,
    parameter [31:0] PUBLISH_TIMEOUT=32'd1000000,
    parameter [31:0] RECOVERY_DRAIN_TIMEOUT=32'd100000000
) (
    input wire clk_sys,
    input wire rst_sys_n,
    output wire service_ready,
    output wire [7:0] service_error,
    output wire recovery_req,
    input wire sd_init_done,
    input wire [2:0] sd_init_error,
    output wire boot_ready,
    output wire [7:0] boot_error,
    input wire [7:0] query_theme_id, query_image_index,
    output wire query_valid,
    output wire [7:0] query_image_resource_id, query_audio_resource_id, query_text_resource_id,
    output wire [31:0] query_image_bytes, query_audio_bytes, query_text_bytes, query_display_time_ms,
    output wire [31:0] font_set_id, glyph_count,
    // A: BMP and ICHTXT02 share this display-resource client.
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
    // B: WAV client.
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
    input wire audio_urgent,
    // One non-stallable 512-byte physical-sector reader. sec_done may coincide
    // with its final sec_data_valid. No next request until this one completes.
    output wire sec_req_valid,
    input wire sec_req_ready,
    output wire [31:0] sec_req_lba,
    input wire sec_data_valid,
    input wire [7:0] sec_data,
    input wire sec_done,
    input wire sec_error
);
    wire boot_req_valid, boot_req_ready, service_req_valid, service_req_ready;
    wire [31:0] boot_req_lba, service_req_lba;
    wire catalog_valid, catalog_ready, catalog_commit, query_valid_raw;
    wire [7:0] catalog_resource_id;
    wire [31:0] catalog_start_lba, catalog_bytes, catalog_total_sectors;
    wire [7:0] query_image_id_raw, query_audio_id_raw, query_text_id_raw;
    wire [31:0] query_image_bytes_raw, query_audio_bytes_raw, query_text_bytes_raw;
    wire [31:0] query_display_time_raw, font_set_raw, glyph_count_raw;
    assign sec_req_valid=boot_ready ? service_req_valid : boot_req_valid;
    assign sec_req_lba=boot_ready ? service_req_lba : boot_req_lba;
    assign boot_req_ready=!boot_ready && sec_req_ready;
    assign service_req_ready=boot_ready && sec_req_ready;
    assign query_valid=query_valid_raw && service_ready;
    // Invalid/change-in-progress keys and runtime faults must not expose a
    // stale usable-looking snapshot. Valid remains the acceptance authority.
    assign query_image_resource_id=query_valid ? query_image_id_raw : 8'd0;
    assign query_audio_resource_id=query_valid ? query_audio_id_raw : 8'd0;
    assign query_text_resource_id=query_valid ? query_text_id_raw : 8'd0;
    assign query_image_bytes=query_valid ? query_image_bytes_raw : 32'd0;
    assign query_audio_bytes=query_valid ? query_audio_bytes_raw : 32'd0;
    assign query_text_bytes=query_valid ? query_text_bytes_raw : 32'd0;
    assign query_display_time_ms=query_valid ? query_display_time_raw : 32'd0;
    assign font_set_id=service_ready ? font_set_raw : 32'd0;
    assign glyph_count=service_ready ? glyph_count_raw : 32'd0;
    resource_v3_catalog #(.INIT_TIMEOUT(INIT_TIMEOUT),.SECTOR_TIMEOUT(SECTOR_TIMEOUT),
        .PUBLISH_TIMEOUT(PUBLISH_TIMEOUT)) catalog (
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.sd_init_done(sd_init_done),.sd_init_error(sd_init_error),
        .sec_req_valid(boot_req_valid),.sec_req_ready(boot_req_ready),.sec_req_lba(boot_req_lba),
        .sec_data_valid(!boot_ready && sec_data_valid),.sec_data(sec_data),.sec_done(!boot_ready && sec_done),
        .sec_error(sec_error),.catalog_valid(catalog_valid),.catalog_ready(catalog_ready),
        .catalog_resource_id(catalog_resource_id),.catalog_start_lba(catalog_start_lba),
        .catalog_bytes(catalog_bytes),.catalog_total_sectors(catalog_total_sectors),
        .catalog_commit(catalog_commit),.catalog_error(boot_error),.ready(boot_ready),
        .query_theme_id(query_theme_id),.query_image_index(query_image_index),.query_valid(query_valid_raw),
        .query_image_resource_id(query_image_id_raw),.query_audio_resource_id(query_audio_id_raw),
        .query_text_resource_id(query_text_id_raw),.query_image_bytes(query_image_bytes_raw),
        .query_audio_bytes(query_audio_bytes_raw),.query_text_bytes(query_text_bytes_raw),
        .query_display_time_ms(query_display_time_raw),.font_set_id(font_set_raw),.glyph_count(glyph_count_raw)
    );
    resource_v3_service #(.SECTOR_TIMEOUT(SECTOR_TIMEOUT),
        .RECOVERY_DRAIN_TIMEOUT(RECOVERY_DRAIN_TIMEOUT)) service (
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .service_ready(service_ready),
        .service_error(service_error),
        .recovery_req(recovery_req),
        .img_req_valid(img_req_valid),
        .img_req_ready(img_req_ready),
        .img_req_resource_id(img_req_resource_id),
        .img_req_block_index(img_req_block_index),
        .img_data_valid(img_data_valid),
        .img_data_ready(img_data_ready),
        .img_data(img_data),
        .img_data_last(img_data_last),
        .img_file_last(img_file_last),
        .img_rsp_valid(img_rsp_valid),
        .img_rsp_ready(img_rsp_ready),
        .img_rsp_status(img_rsp_status),
        .aud_req_valid(aud_req_valid),
        .aud_req_ready(aud_req_ready),
        .aud_req_resource_id(aud_req_resource_id),
        .aud_req_block_index(aud_req_block_index),
        .aud_data_valid(aud_data_valid),
        .aud_data_ready(aud_data_ready),
        .aud_data(aud_data),
        .aud_data_last(aud_data_last),
        .aud_file_last(aud_file_last),
        .aud_rsp_valid(aud_rsp_valid),
        .aud_rsp_ready(aud_rsp_ready),
        .aud_rsp_status(aud_rsp_status),
        .audio_urgent(audio_urgent),
        .catalog_valid(catalog_valid),.catalog_ready(catalog_ready),.catalog_resource_id(catalog_resource_id),
        .catalog_start_lba(catalog_start_lba),.catalog_bytes(catalog_bytes),
        .catalog_total_sectors(catalog_total_sectors),.catalog_commit(catalog_commit),.catalog_error(boot_error),
        .sec_req_valid(service_req_valid),.sec_req_ready(service_req_ready),.sec_req_lba(service_req_lba),
        .sec_data_valid(boot_ready && sec_data_valid),.sec_data(sec_data),
        .sec_done(boot_ready && sec_done),.sec_error(sec_error)
    );
endmodule
