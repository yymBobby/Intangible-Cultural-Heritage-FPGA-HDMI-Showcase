// Project v0.6 streaming profile. Offsets count handshakes, never clock cycles.
module wav_pcm_parser (
    input wire clk_sys, input wire rst_sys_n,
    input wire clear, input wire start, input wire [31:0] file_bytes,
    input wire byte_valid, output wire byte_ready,
    input wire [7:0] byte_data, input wire byte_file_last,
    output reg pcm_valid, input wire pcm_ready,
    output reg signed [15:0] pcm_left, pcm_right, output reg pcm_last,
    output reg format_valid, output reg data_done,
    output reg error, output reg [7:0] error_code
);
    localparam IDLE=0, RIFF=1, HEADER=2, FMT=3, SKIP=4, PCM=5, FINISH=6, BAD=7,
               SIZE_PAD=8, SIZE_END=9, CHECK_CHUNK=10;
    reg [3:0] state;
    reg [4:0] index;
    reg [32:0] offset, limit, last_offset, riff_end, padded_size, chunk_end;
    // The same32-bit word holds RIFF size first, then each chunk size.
    // RIFF uses it only through byte8; each later HEADER overwrites all
    // four size bytes before SIZE_PAD can observe it. riff_end remains33bit.
    reg [31:0] size_word,remaining_bytes;
    // Only these two chunk IDs affect dispatch; accumulate exact byte
    // matches, then hold the flags through SIZE_PAD/SIZE_END/CHECK_CHUNK.
    reg tag_fmt,tag_data;
    reg fmt_bad,fmt_seen;
    reg [23:0] frame_word;
    wire [31:0] size_next = {byte_data, size_word[31:8]};
    // Canonical PCM/stereo/48kHz/16bit fmt fields are checked as bytes.
    // Keep rejection at the original16th-byte handshake, including a bad
    // current byte; no early error or ready/valid timing change is exposed.
    function [7:0] expected_fmt_byte;
        input [3:0] position;
        begin
            case(position)
                0:expected_fmt_byte=8'd1;
                2,10:expected_fmt_byte=8'd2;
                4:expected_fmt_byte=8'h80;
                5:expected_fmt_byte=8'hbb;
                9:expected_fmt_byte=8'hee;
                12:expected_fmt_byte=8'd4;
                14:expected_fmt_byte=8'd16;
                default:expected_fmt_byte=8'd0;
            endcase
        end
    endfunction
    wire fmt_byte_bad=byte_data!=expected_fmt_byte(index[3:0]);
    assign byte_ready = !pcm_valid && !error &&
                       (state==RIFF || state==HEADER || state==FMT || state==SKIP || state==PCM);

    task fail;
        input [7:0] code;
        begin error <= 1; error_code <= code; state <= BAD; pcm_valid <= 0; end
    endtask

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            state<=IDLE; index<=0; offset<=0; limit<=0; last_offset<=0;
            riff_end<=0;padded_size<=0;chunk_end<=0;tag_fmt<=0;tag_data<=0;
            size_word<=0;remaining_bytes<=0;fmt_bad<=0;fmt_seen<=0;
            frame_word<=0; pcm_valid<=0; pcm_left<=0; pcm_right<=0; pcm_last<=0;
            format_valid<=0; data_done<=0; error<=0; error_code<=0;
        end else if (clear || start) begin
            state<=start ? RIFF : IDLE; index<=0; offset<=0; limit<={1'b0,file_bytes};
            last_offset<={1'b0,file_bytes}-33'd1;riff_end<=0;padded_size<=0;chunk_end<=0;
            tag_fmt<=0;tag_data<=0;size_word<=0;remaining_bytes<=0;
            fmt_bad<=0; fmt_seen<=0; frame_word<=0; pcm_valid<=0;
            pcm_left<=0; pcm_right<=0; pcm_last<=0; format_valid<=0;
            data_done<=0; error<=0; error_code<=0;
            if (start && file_bytes<12) fail(2);
        end else begin
            // Separate addition, boundary comparison and state dispatch. A
            // stalled header is held by ready/valid during these three cycles.
            if(state==SIZE_PAD) begin
                padded_size<={1'b0,size_word}+{32'd0,size_word[0]};state<=SIZE_END;
            end else if(state==SIZE_END) begin
                chunk_end<=offset+padded_size;state<=CHECK_CHUNK;
            end else if(state==CHECK_CHUNK) begin
                if(chunk_end>limit) fail(2);
                else if(tag_fmt) begin
                    if(fmt_seen || size_word<16) fail(1);
                    else begin state<=FMT;remaining_bytes<=padded_size[31:0]-32'd16;fmt_bad<=0;end
                end else if(tag_data) begin
                    if(!fmt_seen) fail(1);
                    else if(size_word==0 || size_word[1:0]!=0) fail(2);
                    else begin state<=PCM;remaining_bytes<=size_word;end
                end else if(size_word==0) state<=HEADER;
                else begin state<=SKIP;remaining_bytes<=padded_size[31:0];end
            end
            if (pcm_valid && pcm_ready) begin
                pcm_valid<=0;
                if (pcm_last) data_done<=1;
            end
            if (byte_valid && byte_ready) begin
                offset<=offset+1;
                case (state)
                    RIFF: begin
                        index<=index+1;
                        case(index)
                            0: if(byte_data!="R") fail(1);
                            1: if(byte_data!="I") fail(1);
                            2,3: if(byte_data!="F") fail(1);
                            4,5,6,7:size_word<=size_next;
                            8: begin
                                riff_end<={1'b0,size_word}+33'd8;
                                if(byte_data!="W") fail(1);
                            end
                            9: if(byte_data!="A") fail(1);
                            10: if(byte_data!="V") fail(1);
                            11: begin
                                if(byte_data!="E") fail(1);
                                else if(riff_end!=limit) fail(2);
                                else begin state<=HEADER; index<=0; end
                            end
                        endcase
                    end
                    HEADER: begin
                        index<=index+1;
                        if(index<4) begin
                            case(index[1:0])
                                0:begin tag_fmt<=byte_data==8'h66;tag_data<=byte_data==8'h64;end
                                1:begin tag_fmt<=tag_fmt&&byte_data==8'h6d;tag_data<=tag_data&&byte_data==8'h61;end
                                2:begin tag_fmt<=tag_fmt&&byte_data==8'h74;tag_data<=tag_data&&byte_data==8'h74;end
                                3:begin tag_fmt<=tag_fmt&&byte_data==8'h20;tag_data<=tag_data&&byte_data==8'h61;end
                            endcase
                        end else size_word<=size_next;
                        if(index==7) begin
                            index<=0;state<=SIZE_PAD;
                        end
                    end
                    FMT: begin
                        fmt_bad<=fmt_bad||fmt_byte_bad; index<=index+1;
                        if(index==15) begin
                            index<=0;
                            if(fmt_bad||fmt_byte_bad) fail(1);
                            else begin
                                fmt_seen<=1; format_valid<=1;
                                state<=remaining_bytes==0 ? HEADER : SKIP;
                            end
                        end
                    end
                    SKIP: begin
                        remaining_bytes<=remaining_bytes-1;
                        if(remaining_bytes==1) begin state<=HEADER; index<=0; end
                    end
                    PCM: begin
                        frame_word<={byte_data,frame_word[23:8]}; index<=index+1;
                        remaining_bytes<=remaining_bytes-1;
                        if(index==3) begin
                            index<=0; pcm_left<=frame_word[15:0];
                            pcm_right<={byte_data,frame_word[23:16]};
                            pcm_valid<=1; pcm_last<=remaining_bytes==1;
                            if(remaining_bytes==1) state<=FINISH;
                        end
                    end
                    default: fail(5);
                endcase
                // First data is authoritative; tail chunks are checked by the offline packer.
                if (offset>=limit || (byte_file_last && offset!=last_offset)) fail(2);
                else if (offset==last_offset && !(state==PCM && index==3 && remaining_bytes==1)) fail(2);
            end
        end
    end
endmodule
