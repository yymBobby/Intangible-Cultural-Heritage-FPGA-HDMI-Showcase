`timescale 1ns/1ps
// ICHSHOW3 v0.1 candidate. SYS clock only; asynchronous active-low reset.
// Validates LBA 0/1/2 before publishing any of the 24 resources. No FAT parser.
// Payload format/CRC and actual card capacity remain separate responsibilities.
module resource_v3_catalog #(
    parameter [31:0] INIT_TIMEOUT=32'd300000000,
    parameter [31:0] SECTOR_TIMEOUT=32'd1000000,
    parameter [31:0] PUBLISH_TIMEOUT=32'd1000000
) (
    input wire clk_sys, rst_sys_n,
    input wire sd_init_done,
    input wire [2:0] sd_init_error,
    output wire sec_req_valid,
    input wire sec_req_ready,
    output wire [31:0] sec_req_lba,
    input wire sec_data_valid,
    input wire [7:0] sec_data,
    input wire sec_done, sec_error,
    output wire catalog_valid,
    input wire catalog_ready,
    output wire [7:0] catalog_resource_id,
    output wire [31:0] catalog_start_lba, catalog_bytes,
    output reg [31:0] catalog_total_sectors,
    output wire catalog_commit,
    output reg [7:0] catalog_error,
    output reg ready,
    // Level query: retain the full 8-bit key until query_valid. Changed keys
    // immediately mask the previous result; even image index 4/255 is rejected.
    input wire [7:0] query_theme_id, query_image_index,
    output wire query_valid,
    output wire [7:0] query_image_resource_id, query_audio_resource_id, query_text_resource_id,
    output wire [31:0] query_image_bytes, query_audio_bytes, query_text_bytes,
    output wire [31:0] query_display_time_ms,
    output wire [31:0] font_set_id, glyph_count
);
    localparam [4:0] S_INIT=0,S_ISSUE=1,S_READ=2,S_HEADER=3,S_CRC=4,
        S_ADDR=5,S_CAPTURE=6,S_VALIDATE=7,S_SAVE=8,S_RA_ADDR=9,S_RA_CAPTURE=10,
        S_RB_ADDR=11,S_RB_CAPTURE=12,S_COMPARE=13,S_PUBLISH=14,S_COMMIT=15,
        S_READY=16,S_ERROR=17,S_QUERY=18;
    localparam [31:0] INIT_LIMIT=INIT_TIMEOUT==0 ? 32'd1 : INIT_TIMEOUT;
    localparam [31:0] SEC_LIMIT=SECTOR_TIMEOUT==0 ? 32'd1 : SECTOR_TIMEOUT;
    localparam [31:0] PUB_LIMIT=PUBLISH_TIMEOUT==0 ? 32'd1 : PUBLISH_TIMEOUT;
    reg [4:0] state, slot, range_a, range_b;
    reg [1:0] sector;
    reg [9:0] byte_count;
    reg [4:0] record_byte;
    reg [31:0] timer, crc;
    reg [63:0] header_dynamic;
    wire [31:0] header_total_sectors=header_dynamic[31:0];
    wire [31:0] header_expected_crc=header_dynamic[63:32];
    reg [255:0] record;
    reg header_bad, table_bad, overflow, publishing, overlap_check;
    reg [66:0] compare_a, compare_b;
    reg [7:0] query_theme_hold, query_image_hold;
    reg query_complete, query_read_theme;
    reg [31:0] image_result, audio_result, text_result, dwell_result;
    wire query_key_ok=query_theme_id<8'd4 && query_image_index<8'd4;
    wire query_same=query_theme_id==query_theme_hold && query_image_index==query_image_hold;
    wire rec_image=slot<5'd16;
    wire [31:0] start_lba=rec_image ? record[63:32] : slot<20 ? record[95:64] : record[159:128];
    wire [31:0] length_bytes=rec_image ? record[95:64] : slot<20 ? record[127:96] : record[191:160];
    wire [32:0] range_end={1'b0,start_lba}+(({1'b0,length_bytes}+33'd511)>>9);
    wire range_ok=start_lba>=32'd2048 && length_bytes!=0 && range_end<={1'b0,catalog_total_sectors};
    wire theme_record_ok=record[31:0]=={8'd0,8'd4,8'd3,6'd0,slot[1:0]} &&
        record[63:32]=={28'd0,slot[1:0],2'b00} && record[223:192]!=0 && record[255:224]==0;
    wire image_record_ok=record[31:0]=={8'd0,8'd1,6'd0,slot[1:0],6'd0,slot[3:2]} &&
        record[127:96]=={16'd480,16'd640} && record[159:128]==0 &&
        record[191:160]=={30'd0,slot[3:2]} && record[255:192]==0;
    wire writing=state==S_READ && sec_data_valid && byte_count<512;
    // One 8x1024 SP bank: four theme records at 0..127; sixteen image
    // records at 512..1023. Theme padding is CRC/zero checked on the stream,
    // so it need not be cached. No separate 67-bit-wide range RAM is needed.
    wire [9:0] rec_address=rec_image ? {1'b1,slot[3:0],record_byte} : {3'd0,slot[1:0],record_byte};
    wire table_write=writing && (sector==2 || (sector==1 && byte_count<128));
    wire [9:0] table_address=table_write ? {sector==2,byte_count[8:0]} : rec_address;
    wire [7:0] table_data;
    resource_v3_catalog_ram table_ram (.clk(clk_sys),.ce(table_write || state==S_ADDR),
        .we(table_write),.addr(table_address),.data_in(sec_data),.data_out(table_data));
    // All fixed bytes are compared during transport. Preserve the two
    // full 32-bit dynamic fields and defer all errors to the original states.
    function [7:0] header_constant;
        input [5:0] offset;
        begin case(offset)
            6'd0:header_constant=8'h49;
            6'd1:header_constant=8'h43;
            6'd2:header_constant=8'h48;
            6'd3:header_constant=8'h53;
            6'd4:header_constant=8'h48;
            6'd5:header_constant=8'h4f;
            6'd6:header_constant=8'h57;
            6'd7:header_constant=8'h33;
            6'd8:header_constant=8'h03;
            6'd13:header_constant=8'h02;
            6'd16:header_constant=8'h04;
            6'd20:header_constant=8'h04;
            6'd24:header_constant=8'h20;
            6'd28:header_constant=8'h20;
            6'd32:header_constant=8'h01;
            6'd36:header_constant=8'h02;
            6'd40:header_constant=8'h02;
            6'd45:header_constant=8'h08;
            6'd56:header_constant=8'hcf;
            6'd57:header_constant=8'h7b;
            6'd58:header_constant=8'he1;
            6'd59:header_constant=8'hcb;
            6'd60:header_constant=8'haf;
            6'd61:header_constant=8'h00;
            6'd62:header_constant=8'h00;
            6'd63:header_constant=8'h00;
            default:header_constant=8'd0;
        endcase end
    endfunction
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] value;
        reg [31:0] work;
        integer i;
        begin
            work=previous^{24'd0,value};
            for(i=0;i<8;i=i+1) work=work[0] ? (work>>1)^32'hedb88320 : work>>1;
            crc_byte=work;
        end
    endfunction
    task fail;
        input [7:0] code;
        begin catalog_error<=code;state<=S_ERROR;query_complete<=0; end
    endtask
    assign sec_req_valid=rst_sys_n && state==S_ISSUE;
    assign sec_req_lba={30'd0,sector};
    // A publication timeout faults the boot generation, but an unaccepted
    // valid/payload stays held until coordinated reset (never silently drops).
    assign catalog_valid=rst_sys_n && (state==S_PUBLISH || (state==S_ERROR && publishing));
    assign catalog_resource_id=rec_image ? {3'd0,slot} : slot<20 ? {6'b010000,slot[1:0]} : {6'b100000,slot[1:0]};
    assign catalog_start_lba=start_lba;
    assign catalog_bytes=length_bytes;
    assign catalog_commit=rst_sys_n && state==S_COMMIT;
    assign query_valid=rst_sys_n && ready && query_complete && query_key_ok && query_same;
    assign query_image_resource_id=query_valid ? {4'd0,query_theme_hold[1:0],query_image_hold[1:0]} : 8'd0;
    assign query_audio_resource_id=query_valid ? {6'b010000,query_theme_hold[1:0]} : 8'd0;
    assign query_text_resource_id=query_valid ? {6'b100000,query_theme_hold[1:0]} : 8'd0;
    assign query_image_bytes=query_valid ? image_result : 32'd0;
    assign query_audio_bytes=query_valid ? audio_result : 32'd0;
    assign query_text_bytes=query_valid ? text_result : 32'd0;
    assign query_display_time_ms=query_valid ? dwell_result : 32'd0;
    assign font_set_id=ready ? 32'hCBE17BCF : 32'd0;
    assign glyph_count=ready ? 32'd175 : 32'd0;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            state<=S_INIT;sector<=0;byte_count<=0;record_byte<=0;slot<=0;
            range_a<=0;range_b<=1;timer<=0;crc<=32'hffffffff;
            header_dynamic<=0;record<=0;header_bad<=0;table_bad<=0;overflow<=0;publishing<=0;overlap_check<=0;
            compare_a<=0;compare_b<=0;catalog_error<=0;catalog_total_sectors<=0;ready<=0;
            query_theme_hold<=0;query_image_hold<=0;query_complete<=0;query_read_theme<=0;
            image_result<=0;audio_result<=0;text_result<=0;dwell_result<=0;
            // No table reset: all used bytes are overwritten before ready.
        end else if(ready && (!query_key_ok || !query_same)) begin
            query_complete<=0;query_theme_hold<=query_theme_id;query_image_hold<=query_image_index;
            query_read_theme<=0;slot<={1'b0,query_theme_id[1:0],query_image_index[1:0]};record_byte<=0;state<=S_READY;
        end else case(state)
            S_INIT: if(sd_init_error!=0) fail(8'd1);
                else if(sd_init_done) begin timer<=0;state<=S_ISSUE;end
                else if(timer>=INIT_LIMIT-1) fail(8'd1);
                else timer<=timer+1;
            S_ISSUE: if(timer>=SEC_LIMIT-1) fail(8'd5);
                else if(sec_req_ready) begin byte_count<=0;overflow<=0;timer<=timer+1;state<=S_READ;end
                else timer<=timer+1;
            S_READ: begin
                if(sec_data_valid) begin
                    if(byte_count<512) begin
                        byte_count<=byte_count+1;
                        if(sector==0) begin
                            if(byte_count<64) begin
                                if(byte_count>=48 && byte_count<56)
                                    header_dynamic<={sec_data,header_dynamic[63:8]};
                                else if(sec_data!=header_constant(byte_count[5:0]))header_bad<=1;
                            end else if(sec_data!=0)header_bad<=1;
                        end else begin
                            crc<=crc_byte(crc,sec_data);
                            if(sector==1 && byte_count>=128 && sec_data!=0) table_bad<=1;
                        end
                    end else overflow<=1;
                end
                if(sec_done) begin
                    if(sec_error || overflow || byte_count+{9'd0,sec_data_valid}!=10'd512) fail(8'd5);
                    else if(sector==0) state<=S_HEADER;
                    else if(sector==2) state<=S_CRC;
                    else begin sector<=2;timer<=0;state<=S_ISSUE;end
                end else if(timer>=SEC_LIMIT-1) fail(8'd5);
                else timer<=timer+1;
            end
            S_HEADER: begin
                if(header_bad || header_total_sectors<=2048)fail(8'd2);
                else begin catalog_total_sectors<=header_total_sectors;sector<=1;timer<=0;state<=S_ISSUE;end
            end
            S_CRC: if(table_bad) fail(8'd2);
                else if((~crc)!=header_expected_crc) fail(8'd3);
                else begin slot<=0;record_byte<=0;state<=S_ADDR;end
            S_ADDR: state<=S_CAPTURE;
            S_CAPTURE: begin
                record<={table_data,record[255:8]};
                if(record_byte==31) begin
                    timer<=0;
                    state<=ready ? S_QUERY : publishing ? S_PUBLISH :
                           overlap_check ? (slot==range_a ? S_RA_CAPTURE : S_RB_CAPTURE) : S_VALIDATE;
                end else begin record_byte<=record_byte+1;state<=S_ADDR;end
            end
            S_VALIDATE: if((rec_image && !image_record_ok) || (!rec_image && !theme_record_ok)) fail(8'd2);
                else if(!range_ok || (slot>=20 && (length_bytes<24 || length_bytes>152 || length_bytes[0]))) fail(8'd4);
                else state<=S_SAVE;
            S_SAVE: if(slot==23) begin
                    overlap_check<=1;range_a<=0;range_b<=1;slot<=0;record_byte<=0;state<=S_ADDR;
                end
                else begin slot<=slot+1;record_byte<=0;state<=S_ADDR;end
            // Re-read validated records to derive ranges. A is held while B
            // walks subsequent slots, covering all 24*23/2=276 pairs. This
            // trades boot clocks for BRAM; no physical SD requests are added.
            S_RA_CAPTURE: begin
                compare_a<={1'b1,1'b0,start_lba,range_end};slot<=range_b;record_byte<=0;state<=S_ADDR;
            end
            S_RB_CAPTURE: begin compare_b<={1'b1,1'b0,start_lba,range_end};state<=S_COMPARE;end
            S_COMPARE: if(compare_a[65:33]<compare_b[32:0] && compare_b[65:33]<compare_a[32:0]) fail(8'd4);
                else if(range_a==22 && range_b==23) begin
                    overlap_check<=0;publishing<=1;slot<=0;record_byte<=0;state<=S_ADDR;
                end else if(range_b==23) begin
                    range_a<=range_a+1;range_b<=range_a+2;slot<=range_a+1;record_byte<=0;state<=S_ADDR;
                end else begin range_b<=range_b+1;slot<=range_b+1;record_byte<=0;state<=S_ADDR;end
            S_PUBLISH: if(catalog_ready) begin
                    if(slot==23) state<=S_COMMIT;
                    else begin slot<=slot+1;record_byte<=0;state<=S_ADDR;end
                end else if(timer>=PUB_LIMIT-1) fail(8'd6);
                else timer<=timer+1;
            S_COMMIT: begin ready<=1;state<=S_READY;end
            S_READY: if(query_key_ok && !query_complete) begin
                query_read_theme<=0;slot<={1'b0,query_theme_hold[1:0],query_image_hold[1:0]};record_byte<=0;state<=S_ADDR;
            end
            S_QUERY: begin
                // Reuse cached theme bytes; only expose a two-record snapshot.
                if(!query_read_theme) begin
                    image_result<=record[95:64];query_read_theme<=1;
                    slot<=5'd16+{3'd0,query_theme_hold[1:0]};record_byte<=0;state<=S_ADDR;
                end else begin
                    audio_result<=record[127:96];text_result<=record[191:160];dwell_result<=record[223:192];
                    query_complete<=1;state<=S_READY;
                end
            end
            S_ERROR: state<=S_ERROR;
            default: fail(8'd2);
        endcase
    end
endmodule

// Native narrow single-port organization; one logical 8x1024 bank.
module resource_v3_catalog_ram (
    input wire clk, ce, we,
    input wire [9:0] addr,
    input wire [7:0] data_in,
    output wire [7:0] data_out
);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
        .DATA_WIDTH_B(8),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),
        .MODE("SP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),
        .IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("NONE"),.FILL_ALL("NONE")
    ) inst (.clka(clk),.clkb(1'b0),.cea(ce),.ceb(1'b0),.addra(addr),.addrb(10'd0),
        .dia(data_in),.dib(8'd0),.doa(data_out),.dob(),.wea(we),.web(1'b0),
        .bea(1'b0),.beb(1'b0),.ocea(1'b0),.oceb(1'b0),.rsta(1'b0),.rstb(1'b0));
endmodule
