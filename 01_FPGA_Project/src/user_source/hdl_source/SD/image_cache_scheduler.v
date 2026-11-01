`timescale 1ns/1ps
// Six physical RGB32 frame slots, one loader, one SD service. Background
// requests are never withdrawn after publication. Foreground preempts by a
// real loader stop/drain, not by resetting the card, FIFO or SDRAM.
module image_cache_scheduler(
    input wire clk_sys,rst_sys_n,service_ready,background_enable,video_load_allowed,
    input wire [1:0] current_theme,current_image,
    input wire current_valid,
    input wire [2:0] active_slot,
    input wire second_valid,input wire [2:0] second_slot,
    input wire foreground_valid,foreground_stop,
    input wire [3:0] foreground_key,
    output wire foreground_ready,foreground_hit,
    output wire [2:0] foreground_slot,
    output reg foreground_was_hit,
    output reg foreground_animation_ready,
    input wire loader_ready,loader_idle,loader_prepared,loader_error,
    input wire [2:0] loader_prepared_slot,
    output wire background_active,background_valid,background_stop,
    output wire [2:0] background_slot,
    output wire [7:0] background_theme,background_image,
    output reg [7:0] background_image_id,background_text_id,
    output reg [31:0] background_image_bytes,background_text_bytes,background_font_id,
    output reg [15:0] background_glyph_count,
    input wire query_valid,
    input wire [7:0] query_image_id,query_text_id,
    input wire [31:0] query_image_bytes,query_text_bytes,font_id,glyph_count,
    output wire [5:0] valid_slots,
    output reg [3:0] current_images_valid,
    output reg [15:0] cache_hits,cache_misses
);
    localparam IDLE=0,QUERY=1,SEND=2,LOAD=3,DRAIN=4;
    reg [2:0] state,bg_slot;
    reg [3:0] bg_key,fg_key;
    reg [2:0] fg_slot;
    reg fg_live,fg_miss,cancel_pending;
    reg [5:0] valid;
    reg [3:0] tags[0:5];
    integer i;
    wire [1:0] theme_next=current_theme+2'd1,theme_prev=current_theme-2'd1;
    function wanted;
        input [3:0] key;
        begin wanted=key[3:2]==current_theme ||
            (key[1:0]==0 && (key[3:2]==theme_next || key[3:2]==theme_prev));end
    endfunction
    function cached;
        input [3:0] key;
        integer j;
        begin cached=0;for(j=0;j<6;j=j+1) if(valid[j] && tags[j]==key) cached=1;end
    endfunction
    reg hit,alloc,preferred_alloc,bg_needed;
    reg [2:0] hit_slot,alloc_slot,preferred_slot;
    reg [3:0] bg_candidate;
    reg [5:0] locked;
    reg [3:0] target_images_valid,current_images_comb;
    always @* begin
        locked=0;target_images_valid=0;current_images_comb=0;
        // Reserve the default front slot even before its first commit, matching
        // the existing loader's active-bank admission invariant.
        if(active_slot<6) locked[active_slot]=1;
        if(second_valid && second_slot<6) locked[second_slot]=1;
        hit=0;hit_slot=0;alloc=0;preferred_alloc=0;alloc_slot=0;preferred_slot=0;
        for(i=5;i>=0;i=i-1) begin
            if(current_valid && valid[i] && tags[i][3:2]==current_theme)
                current_images_comb[tags[i][1:0]]=1;
            if(valid[i] && tags[i][3:2]==foreground_key[3:2])
                target_images_valid[tags[i][1:0]]=1;
            if(valid[i] && tags[i]==foreground_key) begin hit=1;hit_slot=i;end
            if(!locked[i]) begin alloc=1;alloc_slot=i;end
            if(!locked[i] && (!valid[i] || !wanted(tags[i]))) begin
                preferred_alloc=1;preferred_slot=i;
            end
        end
        // Invalid slots win over eviction, even if an occupied slot has a
        // lower index. Never let the choice depend on a clock-cycle counter.
        for(i=5;i>=0;i=i-1) if(!locked[i] && !valid[i]) begin
            preferred_alloc=1;preferred_slot=i;
        end
        bg_needed=1;bg_candidate={current_theme,current_image+2'd1};
        if(cached(bg_candidate)) begin
            bg_candidate={current_theme,current_image+2'd2};
            if(cached(bg_candidate)) begin
                bg_candidate={current_theme,current_image+2'd3};
                if(cached(bg_candidate)) begin
                    bg_candidate={theme_next,2'd0};
                    if(cached(bg_candidate)) begin
                        bg_candidate={theme_prev,2'd0};
                        if(cached(bg_candidate)) bg_needed=0;
                    end
                end
            end
        end
    end
    assign background_active=state!=IDLE;
    assign background_valid=state==SEND;
    assign background_stop=state==DRAIN;
    assign background_slot=bg_slot;
    assign background_theme={6'd0,bg_key[3:2]};
    assign background_image={6'd0,bg_key[1:0]};
    assign foreground_hit=hit;
    assign foreground_slot=hit ? hit_slot:preferred_alloc ? preferred_slot:alloc_slot;
    assign foreground_ready=state==IDLE && loader_ready && (hit || alloc);
    assign valid_slots=valid;
    wire foreground_fire=foreground_valid && foreground_ready;
    wire background_complete=loader_idle && loader_prepared && !loader_error && loader_prepared_slot==bg_slot;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            current_images_valid<=0;state<=IDLE;valid<=0;bg_slot<=0;bg_key<=0;cancel_pending<=0;
            fg_live<=0;fg_key<=0;fg_slot<=0;fg_miss<=0;foreground_was_hit<=0;foreground_animation_ready<=0;
            cache_hits<=0;cache_misses<=0;
            background_image_id<=0;background_text_id<=0;background_image_bytes<=0;background_text_bytes<=0;
            background_font_id<=0;background_glyph_count<=0;
            for(i=0;i<6;i=i+1) tags[i]<=0;
        end else begin
            current_images_valid<=current_images_comb;
            if(foreground_fire) begin
                fg_key<=foreground_key;fg_slot<=foreground_slot;fg_live<=1;fg_miss<=!hit;
                foreground_was_hit<=hit;
                // Freeze readiness for this transaction, not a later background
                // completion. Partial themes always use the single-read commit.
                foreground_animation_ready<=hit && (&target_images_valid);
                if(hit) begin if(cache_hits!=65535) cache_hits<=cache_hits+1'b1;end
                else begin valid[foreground_slot]<=0;if(cache_misses!=65535) cache_misses<=cache_misses+1'b1;end
            end else if(fg_live && loader_idle) begin
                if(loader_prepared && !loader_error && loader_prepared_slot==fg_slot) begin
                    if(fg_miss) begin valid[fg_slot]<=1;tags[fg_slot]<=fg_key;end
                    fg_live<=0;
                end else if(loader_error || foreground_stop) fg_live<=0;
            end
            if(state!=IDLE && !background_enable) cancel_pending<=1;
            case(state)
                IDLE: begin
                    cancel_pending<=0;
                    if(!foreground_valid && !fg_live && service_ready && background_enable &&
                        video_load_allowed && current_valid && loader_idle && loader_ready &&
                        bg_needed && preferred_alloc) begin
                        bg_key<=bg_candidate;bg_slot<=preferred_slot;state<=QUERY;
                    end
                end
                QUERY: if(!background_enable) state<=IDLE;
                    else if(query_valid) begin
                        background_image_id<=query_image_id;background_text_id<=query_text_id;
                        background_image_bytes<=query_image_bytes;background_text_bytes<=query_text_bytes;
                        background_font_id<=font_id;background_glyph_count<=glyph_count[15:0];
                        state<=SEND;
                    end
                SEND: if(loader_ready) begin
                    valid[bg_slot]<=0;
                    state<=(!background_enable || cancel_pending) ? DRAIN:LOAD;
                end
                LOAD: if(background_complete) begin valid[bg_slot]<=1;tags[bg_slot]<=bg_key;state<=IDLE;end
                    else if(loader_error || !background_enable || cancel_pending) state<=DRAIN;
                DRAIN: if(loader_idle && !loader_prepared) state<=IDLE;
                default: state<=DRAIN;
            endcase
        end
    end
endmodule
