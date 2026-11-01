`timescale 1ns/1ps
module tb_image_cache_scheduler;
    reg clk_sys=0,rst_sys_n=0;always #5 clk_sys=~clk_sys;
    reg service_ready=1,background_enable=0,video_load_allowed=1,current_valid=0;
    reg [1:0] current_theme=0,current_image=0;
    reg [2:0] active_slot=0,second_slot=0;
    reg second_valid=0,foreground_valid=0,foreground_stop=0;
    reg [3:0] foreground_key=0;
    wire foreground_ready,foreground_hit,foreground_was_hit;
    wire foreground_animation_ready;
    wire [2:0] foreground_slot,background_slot;
    reg loader_ready=1,loader_idle=1,loader_prepared=0,loader_error=0;
    reg [2:0] loader_prepared_slot=0;
    wire background_active,background_valid,background_stop;
    wire [7:0] background_theme,background_image,background_image_id,background_text_id;
    wire [31:0] background_image_bytes,background_text_bytes,background_font_id;
    wire [15:0] background_glyph_count,cache_hits,cache_misses;
    wire [5:0] valid_slots;wire [3:0] current_images_valid;
    reg query_valid=1;
    wire [7:0] query_image_id={4'd0,background_theme[1:0],background_image[1:0]};
    wire [7:0] query_text_id=8'h80|background_theme;
    reg [31:0] query_image_bytes=921654,query_text_bytes=32,font_id=32'h7f318820,glyph_count=184;
    image_cache_scheduler dut(.*);
    task step;begin @(posedge clk_sys);#1;@(negedge clk_sys);end endtask
    task foreground(input [3:0] key,input bit expected_hit);
        reg [2:0] slot;
        begin
            foreground_key=key;foreground_valid=1;#1;
            if(!foreground_ready || foreground_hit!=expected_hit) $fatal(1,"unexpected cache lookup key=%h hit=%b",key,foreground_hit);
            slot=foreground_slot;
            if(!expected_hit && (slot==active_slot || (second_valid && slot==second_slot))) $fatal(1,"evicted pinned source");
            step;foreground_valid=0;loader_ready=0;loader_idle=0;loader_prepared=0;
            repeat(3) step;
            loader_idle=1;loader_prepared=1;loader_prepared_slot=slot;loader_ready=1;
            repeat(2) step;
        end
    endtask
    integer n,timeout;
    reg [2:0] selected;
    reg [7:0] saved_id;reg [2:0] saved_slot;
    initial begin
        repeat(3) step;rst_sys_n=1;step;
        foreground(4'h0,0);active_slot=loader_prepared_slot;current_valid=1;background_enable=1;
        if(foreground_animation_ready) $fatal(1,"Cold theme admitted animation");
        for(n=0;n<5;n=n+1) begin
            timeout=0;while(!background_valid && timeout<50) begin step;timeout++;end
            if(!background_valid) $fatal(1,"prefetch did not publish");
            selected=background_slot;
            if(selected==active_slot) $fatal(1,"prefetch overwrote visible frame");
            if(n<3 && background_image!=n+1) $fatal(1,"current theme fill order incorrect");
            if(n==3 && (background_theme!=1 || background_image!=0)) $fatal(1,"next theme first missing");
            if(n==4 && (background_theme!=3 || background_image!=0)) $fatal(1,"previous theme first missing");
            step;loader_ready=0;loader_idle=0;loader_prepared=0;
            repeat(4) step;
            loader_idle=1;loader_ready=1;loader_prepared=1;loader_prepared_slot=selected;
            step;
            repeat(2)step;
            if(current_images_valid!=(n==0 ? 4'b0011:n==1 ? 4'b0111:4'b1111))
                $fatal(1,"Progress must report current theme images only: %b",current_images_valid);
        end
        background_enable=0;repeat(3) step;
        if(valid_slots!=6'b111111) $fatal(1,"six slots not completed: %b",valid_slots);
        foreground(4'h3,1);
        if(!foreground_animation_ready) $fatal(1,"Completed four-image theme did not enable animation");
        if(cache_hits!=1 || cache_misses!=1 || !foreground_was_hit) $fatal(1,"cache hit counters incorrect");
        // Adjacent cover is cached, but the other three pictures are not.
        // A cache HIT alone must never admit dual-read animation.
        foreground(4'h4,1);
        if(foreground_animation_ready || !foreground_was_hit) $fatal(1,"Cached cover of incomplete theme admitted animation");
        active_slot=loader_prepared_slot;current_theme=1;current_image=0;background_enable=1;
        for(n=0;n<3;n=n+1) begin
            timeout=0;while(!background_valid && timeout<50) begin step;timeout++;end
            if(!background_valid || background_theme!=1 || background_image!=n+1) $fatal(1,"New theme was not filled first");
            selected=background_slot;step;loader_ready=0;loader_idle=0;loader_prepared=0;
            repeat(4) step;
            loader_idle=1;loader_ready=1;loader_prepared=1;loader_prepared_slot=selected;step;
            if(foreground_animation_ready) $fatal(1,"Background completion changed the frozen foreground mode");
        end
        background_enable=0;repeat(3) step;
        foreground(4'h7,1);
        if(!foreground_animation_ready) $fatal(1,"Next foreground did not restore animation after all-four fill");
        second_valid=1;second_slot=5;
        foreground(4'h8,0);active_slot=loader_prepared_slot;current_theme=2;current_image=0;
        if(foreground_animation_ready) $fatal(1,"Partially cached new theme admitted animation");
        background_enable=1;loader_ready=0;
        // Background admission requires idle-ready, then publication is held
        // even if the consumer stalls and the user preempts afterwards.
        loader_ready=1;step;loader_ready=0;
        timeout=0;while(!background_valid && timeout<50) begin step;timeout++;end
        if(!background_valid) $fatal(1,"background request not issued");
        saved_id=background_image_id;saved_slot=background_slot;background_enable=0;
        repeat(5) begin
            step;if(!background_valid || background_stop || background_image_id!=saved_id || background_slot!=saved_slot)
                $fatal(1,"published background payload withdrawn before ready");
        end
        loader_ready=1;step;loader_ready=0;loader_idle=0;loader_prepared=0;
        if(!background_stop) $fatal(1,"preempt did not request real loader drain");
        repeat(4) step;loader_idle=1;loader_ready=1;step;
        if(background_active || valid_slots[saved_slot]) $fatal(1,"aborted frame marked valid");
        $display("PASS: six-frame cache, cold miss/partial-theme HIT forbid animation, all-four HIT permits it, neighbour covers, pinned slots, stable stalled request and cancellation drain");$finish;
    end
    initial begin #100000;$fatal(1,"cache watchdog");end
endmodule
