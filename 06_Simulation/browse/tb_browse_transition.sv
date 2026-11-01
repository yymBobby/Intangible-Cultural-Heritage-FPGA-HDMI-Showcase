`timescale 1ns/1ps
module tb_browse_transition;
 reg [1:0] speed_sys=2'd0;integer updates=0,expected_updates=32;
    reg quiet=0;wire guard_ready;
    browse_frame_guard guard(.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.frame_start_pix(frame_start_pix),.quiet_pix(quiet),.ready_sys(guard_ready));
    wire second_repeat_pix;
    wire second_display_pix;
    reg clk_sys=0,clk_pix=0,rst_sys_n=0,rst_pix_n=0;
    always #12.5 clk_sys=~clk_sys;always #6.667 clk_pix=~clk_pix;
    reg request_sys=0,inner_ack_sys=0;reg [1:0] menu_mode_sys=0;
    reg target_cached_sys=0,current_valid_sys=1;reg [2:0] target_slot_sys=5;
    reg backwards_sys=0;
    wire inner_request_sys,ack_sys,busy_sys;
    reg [7:0] ticks=0;
    always @(negedge clk_pix) if(rst_pix_n) ticks<=ticks+1'b1;
    wire frame_start_pix=ticks==0;
    wire safe_window_pix=ticks<80,stage_start_allowed_pix=ticks<32;
    reg second_ready_pix=0,second_applied_pix=0;wire second_drained_pix=1;
    wire second_request_pix,second_apply_pix;wire [2:0] second_slot_pix;
    wire [1:0] effect_pix;wire [8:0] alpha_pix;
    wire [9:0] shift_pix,source_shift_pix;wire backwards_pix,animation_live_pix;
    image_transition_commit #(.ADAPTIVE_SPEED(1)) dut(.*);
    integer second_delay=0,ack_delay=0,frames=0;
    reg [8:0] last_alpha=0;reg [9:0] last_shift=0;reg [1:0] last_effect=0;reg last_direction=0;
    always @(posedge clk_pix) begin
        if(!rst_pix_n || !second_request_pix) begin second_ready_pix<=0;second_applied_pix<=0;second_delay<=0;end
        else begin
            if(second_delay<8) second_delay<=second_delay+1;
            else second_ready_pix<=1;
            if(second_apply_pix) second_applied_pix<=1;
        end
        if(frame_start_pix) frames<=frames+1;
        #1;
        if(rst_pix_n && ((effect_pix!=last_effect && effect_pix!=0) || backwards_pix!=last_direction) && !stage_start_allowed_pix)
            $fatal(1,"descriptor geometry published outside guarded blank");
        if(rst_pix_n && (alpha_pix!=last_alpha || shift_pix!=last_shift) && !frame_start_pix)
            $fatal(1,"animation changed inside active frame");
        if(effect_pix==2 && alpha_pix>last_alpha)begin
            updates=updates+1;
            if(alpha_pix-last_alpha!=(expected_updates==16 ? 16:8))$fatal(1,"incorrect per-frame speed");
        end
        last_alpha=alpha_pix;last_shift=shift_pix;last_effect=effect_pix;last_direction=backwards_pix;
        if(effect_pix==2 && shift_pix!=alpha_pix*30/8) $fatal(1,"slide position and frame progress differ");
    end
    always @(posedge clk_sys) begin
        if(!inner_request_sys) begin inner_ack_sys<=0;ack_delay<=0;end
        else if(ack_delay<5) ack_delay<=ack_delay+1;
        else inner_ack_sys<=1;
        if(rst_sys_n && inner_request_sys && effect_pix!=0 && alpha_pix!=256 && !inner_ack_sys)
            $fatal(1,"primary commit started before transition endpoint");
    end
    task run_slide(input integer speed,input bit back);
        integer age;
        begin
            updates=0;expected_updates=speed==1 ? 16:32;speed_sys=speed;
            menu_mode_sys=2;target_cached_sys=1;current_valid_sys=1;backwards_sys=back;
            @(negedge clk_sys);request_sys=1;
            wait(alpha_pix!=0);
            // Change requested speed in flight: captured descriptor must hold.
            speed_sys=speed==1 ? 0:1;
            age=0;while(!ack_sys&&age<60000)begin @(negedge clk_sys);age++;end
            if(!ack_sys||updates!=expected_updates||shift_pix!=960||source_shift_pix!=640||backwards_pix!=back)
                $fatal(1,"slide frame/endpoint mismatch speed=%0d updates=%0d expected=%0d",speed,updates,expected_updates);
            $display("PASS: slide speed=%0d direction=%b exact_frames=%0d endpoint=960/640, descriptor locked",speed,back,updates);
            request_sys=0;age=0;while(busy_sys&&age<5000)begin @(negedge clk_sys);age++;end
            if(busy_sys||ack_sys||animation_live_pix)$fatal(1,"release failed");
        end
    endtask
    initial begin
        $dumpfile("browse_transition.vcd");
        $dumpvars(0,request_sys,ack_sys,busy_sys,speed_sys,alpha_pix,shift_pix,source_shift_pix,effect_pix,updates,quiet,guard_ready);
        repeat(4)@(negedge clk_sys);rst_sys_n=1;rst_pix_n=1;
        run_slide(0,0);run_slide(1,0);run_slide(1,1);run_slide(0,1);
        quiet=1;
        while(!frame_start_pix)@(negedge clk_pix);@(posedge clk_pix);#1;
        repeat(4)@(negedge clk_sys);if(guard_ready)$fatal(1,"guard opened before complete stable frame");
        while(!frame_start_pix)@(negedge clk_pix);@(posedge clk_pix);#1;
        repeat(4)@(negedge clk_sys);if(!guard_ready)$fatal(1,"guard did not open after stable frame");
        quiet=0;repeat(4)@(negedge clk_sys);if(guard_ready)$fatal(1,"guard did not revoke on activity");
        $display("PASS: stable-frame guard, two boundaries, asynchronous-domain level sync, activity revokes admission");$finish;
    end
    initial begin #2000000;$fatal(1,"browse transition watchdog");end
endmodule
