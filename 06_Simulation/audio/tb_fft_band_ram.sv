`timescale 1ns/1ps
// The unchanged legacy FFT is the fixed-point numerical/cycle reference.
// No FFT stub: both instances execute all512Hann/DIT/channel/bin operations.
module tb_fft_band_ram;
    reg clk=0;always #12.5 clk=~clk;
    reg rst_n=0,clear=0,sample_valid=0;
    reg signed [15:0] sample_l=0,sample_r=0;
    wire legacy_valid,ram_valid,legacy_busy,ram_busy;
    wire [511:0] legacy_bands;
    wire [31:0] legacy_skipped,ram_skipped;
    reg band_read_enable=0;
    reg [4:0] band_read_address=0;
    wire [15:0] band_read_data;
    audio_fft512 legacy(clk,rst_n,clear,sample_valid,sample_l,sample_r,
        legacy_valid,legacy_bands,legacy_busy,legacy_skipped);
    audio_fft512_ram ram_fft(.clk(clk),.rst_n(rst_n),.clear(clear),
        .sample_valid(sample_valid),.sample_l(sample_l),.sample_r(sample_r),
        .result_valid(ram_valid),.busy(ram_busy),.skipped_samples(ram_skipped),
        .band_read_enable(band_read_enable),.band_read_address(band_read_address),
        .band_read_data(band_read_data));
    integer cycle=0,cycle_checks=0,band_checks=0,results=0;
    reg [511:0] snapshot;
    function signed [15:0] waveform;
        input integer profile,index,right_channel;
        real phase,amplitude;
        integer value;
        begin
            phase=0.0;amplitude=0.0;value=0;
            case(profile)
                0:value=0;
                1:begin phase=6.283185307179586*10.0*index/512.0;amplitude=16000.0;value=$rtoi(amplitude*$sin(phase));end
                2:begin phase=6.283185307179586*63.0*index/512.0;amplitude=26000.0;value=$rtoi(amplitude*$sin(phase));if(right_channel)value=-value;end
                3:value=index%2 ? -32768:32767;
                4:begin
                    phase=6.283185307179586*(right_channel ? 110.0:1.0)*index/512.0;
                    amplitude=right_channel ? 24000.0:9000.0;value=$rtoi(amplitude*$sin(phase));
                end
                5:value=((index*1103515245+12345+(right_channel ? 987654321:0))>>8)&16'hffff;
                6:begin phase=6.283185307179586*1000.0*index/48000.0;amplitude=31000.0;value=right_channel ? 0:$rtoi(amplitude*$sin(phase));end
                7:begin phase=6.283185307179586*127.0*index/512.0;amplitude=32000.0;value=$rtoi(amplitude*$cos(phase));if(right_channel)value=-value;end
                default:value=right_channel ? 16'sh8000:16'sh7fff;
            endcase
            waveform=value[15:0];
        end
    endfunction
    task feed_samples;
        input integer profile,count,interval;
        integer n;
        begin
            for(n=0;n<count;n=n+1) begin
                @(negedge clk);
                sample_l=waveform(profile,n,0);sample_r=waveform(profile,n,1);sample_valid=1;
                @(negedge clk);sample_valid=0;
                repeat(interval-2) @(negedge clk);
            end
        end
    endtask
    task await_and_compare;
        input integer profile;
        integer b,nonzero;
        begin
            // Also present real input strobes while busy. The production RAM
            // variant must skip EXACTLY the same cycles as the legacy core.
            while(!legacy_valid) begin
                @(negedge clk);
                sample_valid=legacy_busy&&cycle%31==0;
                sample_l=waveform(5,cycle,0);sample_r=waveform(5,cycle,1);
            end
            sample_valid=0;snapshot=legacy_bands;nonzero=0;
            if(!ram_valid||legacy_busy||ram_busy) $fatal(1,"Result publication phase changed");
            for(b=0;b<32;b=b+1) begin
                @(negedge clk);band_read_enable=1;band_read_address=b;
                @(posedge clk);#0.001;
                if(band_read_data!==snapshot[b*16+:16])
                    $fatal(1,"FFT band mismatch profile=%0d band=%0d RAM=%0d legacy=%0d",profile,b,band_read_data,snapshot[b*16+:16]);
                if(band_read_data!=0) nonzero=nonzero+1;
                band_checks=band_checks+1;
                @(negedge clk);band_read_enable=0;
                // Native No Change port must hold output during read gaps.
                @(posedge clk);#0.001;
                if(band_read_data!==snapshot[b*16+:16]) $fatal(1,"Scalar read gap changed RAM output");
            end
            if(profile==0&&nonzero!=0) $fatal(1,"Silence produced nonzero bands");
            if(profile!=0&&nonzero==0) $fatal(1,"Missing nonzero FFT coverage profile=%0d",profile);
            results=results+1;
            $display("PASS: profile=%0d all32bands numerical/cycle exact, nonzero=%0d skipped=%0d",profile,nonzero,ram_skipped);
        end
    endtask
    task clear_core;
        begin
            @(negedge clk);sample_valid=0;band_read_enable=0;clear=1;
            repeat(3) @(negedge clk);
            if(legacy_valid||ram_valid||legacy_busy||ram_busy||legacy_skipped!=0||ram_skipped!=0)
                $fatal(1,"Clear did not invalidate FFT control/publication");
            clear=0;
        end
    endtask
    always @(negedge clk) cycle=cycle+1;
    always @(posedge clk) if(rst_n) begin
        #0.001;
        cycle_checks=cycle_checks+1;
        if({legacy_valid,legacy_busy,legacy_skipped}!=={ram_valid,ram_busy,ram_skipped})
            $fatal(1,"FFT control/timing changed cycle=%0d legacy=%b/%b/%0d RAM=%b/%b/%0d",cycle,legacy_valid,legacy_busy,legacy_skipped,ram_valid,ram_busy,ram_skipped);
        if(legacy.state!==ram_fft.state||legacy.index!==ram_fft.index||legacy.channel!==ram_fft.channel)
            $fatal(1,"FFT schedule/capture/channel diverged cycle=%0d",cycle);
    end
    integer profile;
    initial begin
        #113;rst_n=1;
        for(profile=0;profile<6;profile=profile+1) begin
            // Full-scale includes realistic48kHz input intervals at40MHz.
            feed_samples(profile,512,profile==3 ? 833:4);
            await_and_compare(profile);
        end
        // Clear in a partial capture, then overwrite every sample/RAM word.
        feed_samples(5,137,4);clear_core();
        feed_samples(6,512,4);await_and_compare(6);
        // Clear in butterfly processing, where old spectrum RAM is only
        // partially accumulated or stale. A fresh transform must still match.
        feed_samples(7,512,4);
        wait(legacy.state==8&&legacy.stage==3);
        clear_core();
        feed_samples(7,512,4);await_and_compare(7);
        // Asynchronous reset also invalidates an unfinished transform.
        feed_samples(4,512,4);
        wait(legacy.state==14);
        @(negedge clk);rst_n=0;sample_valid=0;band_read_enable=0;
        repeat(3) @(negedge clk);rst_n=1;
        feed_samples(8,512,4);await_and_compare(8);
        if(results!=9||band_checks!=288||cycle_checks<1000000)
            $fatal(1,"Insufficient FFT RAM coverage results=%0d bands=%0d cycles=%0d",results,band_checks,cycle_checks);
        $display("PASS: RAM FFT512 Hann/LRmax exact: %0d published results, %0d band reads, %0d identical timing/capture cycles; silence/sine/antiphase/fullscale/stereo/random/clear/reset",results,band_checks,cycle_checks);
        $finish;
    end
    initial begin #60000000;$fatal(1,"FFT RAM equivalence timeout");end
endmodule
