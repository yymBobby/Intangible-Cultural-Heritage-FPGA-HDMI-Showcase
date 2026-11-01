`timescale 1ns/1ps
// Actual joint/text/BMP loaders, procedural file stream and bounded writer.
// Public release fixture: Font176 header ID/count, payload and CRC cases unchanged.
module tb_cached_image_loader;
 reg clk_sys=0;always #12.5 clk_sys=~clk_sys;
 reg rst_sys_n=0,service_ready=1,cache_hit=0,cache_only=0,img_load_valid=0,img_stop_req=0;
 reg [7:0] service_error=0,img_load_theme_id=0,img_load_image_index=0,img_load_resource_id=0,img_load_text_resource_id=8'h80;
 reg [31:0] img_load_file_bytes=921654,img_load_text_file_bytes=28,img_load_font_set_id=32'hcbe17bcf;
 reg [15:0] img_load_glyph_count=175;reg [2:0] cache_slot=5,active_image_bank_sys=5;
 reg video_load_allowed_sys=1,text_back_available_sys=1,text_back_bank_sys=1;
 wire img_load_ready,img_idle,img_error,img_prepared,img_recovery_needed,text_prepared_sys,joint_image_prepared_sys;
 wire [7:0] img_error_code,img_prepared_theme_id;wire [1:0] img_error_stage;
 wire [2:0] img_prepared_image_bank_sys;wire img_prepared_text_bank_sys;wire [6:0] img_prepared_text_count_sys;
 wire img_req_valid,img_req_ready,img_data_valid,img_data_ready,img_data_last,img_file_last,img_rsp_valid,img_rsp_ready;
 wire [7:0] img_req_resource_id,img_data;wire [31:0] img_req_block_index;wire [2:0] img_rsp_status=0;
 wire text_write_valid,text_write_bank,text_write_ready;wire [5:0] text_write_addr;wire [15:0] text_write_glyph_id;
 wire image_write_start_sys,image_write_abort_sys,image_write_start_ready_sys,image_write_data_valid_sys,image_write_data_ready_sys;
 wire [2:0] image_write_bank_sys;wire [31:0] image_write_data_sys;
 reg image_write_abort_ack_sys=0,image_write_busy_sys=0,image_prepared_sys=0,image_write_error_sys=0;
 reg [2:0] prepared_image_bank_sys=0;
 image_text_loader #(.RESOURCE_VERSION(3),.BANK_BITS(3),.IMAGE_BANK_COUNT(6),.CACHE_CONTROL(1)) dut(.*);
 integer fixture_offset=54,fixture_tail=0,fixture_variant=0;
 `include "bmp_fixture.svh"
 function [31:0] crc_byte(input [31:0] previous,input [7:0] value);
  reg [31:0] c;integer b;begin c=previous^value;for(b=0;b<8;b=b+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
 endfunction
 reg [31:0] txtcrc;reg bad_crc=0;
 function [7:0] text_byte(input integer p);
  reg [63:0] magic;begin magic=64'h3230545854484349;text_byte=0;
   if(p<8)text_byte=magic>>(p*8);
   else case(p)
    8:text_byte=2;10,11:text_byte=32;12:text_byte=8'hcf;13:text_byte=8'h7b;14:text_byte=8'he1;15:text_byte=8'hcb;
    16:text_byte=2;18:text_byte=16;19:text_byte=4;
    20,21,22,23:text_byte=(txtcrc^(bad_crc ? 32'd1:32'd0))>>((p-20)*8);
    24:text_byte=1;26:text_byte=2;
    default:text_byte=0;
   endcase
  end
 endfunction
 integer source_state=0,block=0,index=0,source_id=0,delay=0,tick=0,words=0,texts=0,starts=0,requests=0,prepare_delay=0;
 wire [31:0] length=source_id==128 ? 28:921654;
 wire [31:0] pos=block*512+index;
 wire [31:0] block_length=length-block*512>512 ? 512:length-block*512;
 assign img_req_ready=source_state==0;
 assign img_data_valid=source_state==1 && tick%7!=0;
 assign img_data=source_id==128 ? text_byte(pos):fixture_byte(pos);
 assign img_data_last=index==block_length-1;
 assign img_file_last=pos==length-1;
 assign img_rsp_valid=source_state==3;
 assign text_write_ready=tick%5!=0;
 assign image_write_start_ready_sys=!image_write_busy_sys&&!image_write_abort_ack_sys;
 assign image_write_data_ready_sys=image_write_busy_sys&&tick%5!=0&&!image_write_abort_sys;
 always @(posedge clk_sys) begin
  if(!rst_sys_n) begin source_state<=0;block<=0;index<=0;source_id<=0;delay<=0;tick<=0;
   words<=0;texts<=0;starts<=0;requests<=0;prepare_delay<=0;image_write_busy_sys<=0;image_prepared_sys<=0;image_write_abort_ack_sys<=0;
  end else begin
   tick<=tick+1;
   if(img_req_valid && img_req_ready) begin
    if(cache_hit && img_req_resource_id!=128) $fatal(1,"Cache hit read a BMP block");
    if(cache_only && img_req_resource_id==128) $fatal(1,"Background overwrote subtitle bank");
    source_id<=img_req_resource_id;block<=img_req_block_index;index<=0;source_state<=1;requests<=requests+1;
   end else if(img_data_valid && img_data_ready) begin
    if(img_data_last) begin source_state<=2;delay<=img_file_last ? 100:3;end else index<=index+1;
   end else if(source_state==2) begin if(delay==0)source_state<=3;else delay<=delay-1;end
   else if(img_rsp_valid&&img_rsp_ready)source_state<=0;
   if(text_write_valid&&text_write_ready) begin
    if(text_write_bank!=1 || text_write_addr!=texts || text_write_glyph_id!=texts+1) $fatal(1,"Cached subtitle order/bank");
    texts<=texts+1;
   end
   if(image_write_start_sys&&image_write_start_ready_sys) begin
    if(cache_hit || image_write_bank_sys!=cache_slot) $fatal(1,"Writer started on hit/wrong slot");
    starts<=starts+1;image_write_busy_sys<=1;image_prepared_sys<=0;prepared_image_bank_sys<=image_write_bank_sys;
   end
   if(image_write_data_valid_sys&&image_write_data_ready_sys) begin
    if(image_write_data_sys!==fixture_word(479-words/640,words%640)) $fatal(1,"BMP data order at %0d",words);
    words<=words+1;if(words==307199)prepare_delay<=37;
   end
   if(prepare_delay>0) begin prepare_delay<=prepare_delay-1;if(prepare_delay==1)begin image_prepared_sys<=1;image_write_busy_sys<=0;end end
   if(image_write_abort_sys) begin image_write_abort_ack_sys<=1;image_write_busy_sys<=0;image_prepared_sys<=0;end
   else image_write_abort_ack_sys<=0;
   if(img_prepared && (source_state!=0 || image_write_busy_sys)) $fatal(1,"Prepared before final response/writer drain");
  end
 end
 task run(input bit hit,input bit only,input bit corrupt,input integer slot);
  begin
   @(negedge clk_sys);rst_sys_n=0;img_load_valid=0;cache_hit=hit;cache_only=only;bad_crc=corrupt;
   cache_slot=slot;active_image_bank_sys=hit ? slot:1;text_back_available_sys=!only;
   repeat(4)@(negedge clk_sys);rst_sys_n=1;repeat(4)@(negedge clk_sys);
   img_load_valid=1;do @(posedge clk_sys);while(!img_load_ready);
   @(negedge clk_sys);img_load_valid=0;wait(img_idle);@(negedge clk_sys);
   if(img_recovery_needed || img_prepared!==!corrupt || img_prepared_image_bank_sys!=slot) $fatal(1,"Joint result hit=%b only=%b code=%0d",hit,only,img_error_code);
   if(corrupt)begin if(img_error_code!=6 || joint_image_prepared_sys) $fatal(1,"Bad CRC accepted on cache hit");end
   else begin
    if(img_error || (only ? text_prepared_sys:!joint_image_prepared_sys)) $fatal(1,"Prepared descriptor/font mismatch");
    if(!only && (texts!=2 || img_prepared_text_count_sys!=2)) $fatal(1,"Cached subtitles missing");
   end
   if(hit && (words!=0 || starts!=0 || requests!=1)) $fatal(1,"Cache hit touched SDRAM writer/BMP");
   if(!hit && (words!=307200 || starts!=1 || (only&&texts!=0))) $fatal(1,"Background/miss incomplete physical frame");
   $display("PASS: joint loader hit=%b background=%b bad_crc=%b slot=%0d BMP_words=%0d text_glyphs=%0d",hit,only,corrupt,slot,words,texts);
  end
 endtask
 initial begin
  txtcrc=crc_byte(crc_byte(crc_byte(crc_byte(32'hffffffff,1),0),2),0)^32'hffffffff;
  run(1,0,0,5);run(1,0,1,5);run(0,1,0,4);run(0,0,0,2);$finish;
 end
 initial begin #100000000;$fatal(1,"Joint loader timeout");end
endmodule
