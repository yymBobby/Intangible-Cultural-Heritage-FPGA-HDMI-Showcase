// Receiver adapted from B test utility at 65cf794f5ba765c2e3e9c500aebb595167cd59e4; B player RTL unchanged.
// Same 64 BCLK/slot sampling convention as A's receiver, with local reset and
// initial partial-frame suppression. No changes to A's shared receiver.
module i2s_frame_receiver(
    input wire clk_pixel, rst_pixel_n, bclk, lrck, dout,
    output reg audio_valid,
    output reg [23:0] left24, right24
);
    (* ASYNC_REG="TRUE" *) reg [2:0] b_sync, l_sync, d_sync;
    reg lrck_sample;
    // The old left/right64-bit shifts are mutually exclusive: every BCLK
    // sample shifts one and clears the other. Encode that invariant as a
    // single shift plus its owner, including short/malformed LRCK slots.
    // The locked left sample only exposes its high24 bits.
    reg [63:0] slot_shift;
    reg slot_bank;
    reg [23:0] left_lock;
    reg left_edge, right_edge, left_complete, right_started, frame_aligned;
    wire b_rise=b_sync[1] && !b_sync[2];
    wire l_rise=l_sync[2] && !lrck_sample;
    wire l_fall=!l_sync[2] && lrck_sample;
    always @(posedge clk_pixel or negedge rst_pixel_n) begin
        if(!rst_pixel_n) begin b_sync<=0; l_sync<=0; d_sync<=0; end
        else begin b_sync<={b_sync[1:0],bclk}; l_sync<={l_sync[1:0],lrck}; d_sync<={d_sync[1:0],dout}; end
    end
    always @(posedge clk_pixel or negedge rst_pixel_n) begin
        if(!rst_pixel_n) begin
            lrck_sample<=0; slot_shift<=0; slot_bank<=0; left_lock<=0;
            left_edge<=0; right_edge<=0; left_complete<=0;
            right_started<=0; frame_aligned<=0;
            audio_valid<=0; left24<=0; right24<=0;
        end else begin
            left_edge<=b_rise && l_rise;
            right_edge<=b_rise && l_fall;
            audio_valid<=0; left24<=0; right24<=0;
            if(b_rise) begin
                lrck_sample<=l_sync[2];
                if(lrck_sample) begin
                    slot_shift<=slot_bank ? {slot_shift[62:0],d_sync[2]}:{63'd0,d_sync[2]};
                    slot_bank<=1;
                end else begin
                    slot_shift<=slot_bank ? {63'd0,d_sync[2]}:{slot_shift[62:0],d_sync[2]};
                    slot_bank<=0;
                end
            end
            if(left_edge) begin
                left_lock<=slot_bank ? 24'd0:slot_shift[63:40]; left_complete<=frame_aligned;
                right_started<=1;
            end
            if(right_edge) begin
                frame_aligned<=right_started;
                if(left_complete) begin
                    audio_valid<=1; left24<=left_lock; right24<=slot_bank ? slot_shift[63:40]:24'd0;
                end
                left_complete<=0;
            end
        end
    end
endmodule
