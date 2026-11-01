`timescale 1ns/1ps
// EG4 ADC controller. Run at 10 MHz; one SOC every 50 clocks (200 kS/s).
// The mux is held throughout the four acquisition and twelve conversion clocks.
module joystick_adc_pair #(
    parameter integer PERIOD_CYCLES=50,
    parameter integer TIMEOUT_CYCLES=32,
    parameter integer WAKE_CYCLES=5
)(
    input wire clk_adc, rst_adc_n,
    input wire adc_eoc,
    input wire [11:0] adc_dout,
    output reg adc_pd, adc_soc,
    output reg [2:0] adc_channel,
    output reg [11:0] pair_x, pair_y,
    output reg pair_valid,
    output reg fault
);
    localparam integer CW=$clog2(PERIOD_CYCLES+TIMEOUT_CYCLES+WAKE_CYCLES+2);
    localparam [2:0] POWER=0, WAKE=1, SELECT=2, CONVERT=3, GAP=4;
    reg [2:0] state;
    reg [CW-1:0] timer;
    reg [11:0] pending_x;
    reg eoc_previous;
    wire eoc_rise=adc_eoc && !eoc_previous;
    always @(posedge clk_adc or negedge rst_adc_n) begin
        if(!rst_adc_n) begin
            state<=POWER;timer<=0;adc_pd<=1;adc_soc<=0;adc_channel<=1;
            pending_x<=0;pair_x<=0;pair_y<=0;pair_valid<=0;fault<=0;eoc_previous<=0;
        end else begin
            pair_valid<=0;adc_soc<=0;eoc_previous<=adc_eoc;
            case(state)
                POWER:begin
                    adc_pd<=1;
                    if(timer==WAKE_CYCLES-1) begin timer<=0;adc_pd<=0;state<=WAKE;end
                    else timer<=timer+1'b1;
                end
                WAKE:begin
                    if(timer==WAKE_CYCLES-1) begin timer<=0;adc_channel<=1;state<=SELECT;end
                    else timer<=timer+1'b1;
                end
                SELECT:begin
                    // SELECT also gives channel selection a full clock of setup.
                    if(!adc_eoc) begin adc_soc<=1;timer<=0;state<=CONVERT;end
                    else if(timer==TIMEOUT_CYCLES-1) begin
                        fault<=1;timer<=0;adc_pd<=1;state<=POWER;
                    end else timer<=timer+1'b1;
                end
                CONVERT:begin
                    timer<=timer+1'b1;
                    // Never accept stale/early EOC; official conversion is 16 cycles.
                    if(eoc_rise && timer>=16) begin
                        if(adc_channel==1) pending_x<=adc_dout;
                        else begin pair_x<=pending_x;pair_y<=adc_dout;pair_valid<=1;end
                        state<=GAP;
                    end else if(timer==TIMEOUT_CYCLES-1) begin
                        fault<=1;timer<=0;adc_pd<=1;state<=POWER;adc_channel<=1;
                    end
                end
                GAP:begin
                    if(timer==PERIOD_CYCLES-2) begin
                        timer<=0;adc_channel<=adc_channel==1 ? 3'd2:3'd1;state<=SELECT;
                    end else timer<=timer+1'b1;
                end
                default:begin state<=POWER;timer<=0;adc_pd<=1;fault<=1;end
            endcase
        end
    end
endmodule

// Atomic bundled-data mailbox: data is held until the returned acknowledgement.
// ADC acquisition continues even if a consumer stalls; a busy mailbox drops a pair.
module joystick_pair_cdc(
    input wire clk_adc,rst_adc_n,
    input wire [11:0] pair_x,pair_y,
    input wire pair_valid,
    input wire clk_sys,rst_sys_n,
    output reg [11:0] x_raw,y_raw,
    output reg sample_valid
);
    reg [23:0] held_pair;
    reg request,acknowledge;
    (* async_reg="true" *) reg ack_meta,ack_sync,request_meta,request_sync;
    always @(posedge clk_adc or negedge rst_adc_n) begin
        if(!rst_adc_n) begin held_pair<=0;request<=0;ack_meta<=0;ack_sync<=0;end
        else begin
            ack_meta<=acknowledge;ack_sync<=ack_meta;
            if(pair_valid && request==ack_sync) begin held_pair<={pair_x,pair_y};request<=!request;end
        end
    end
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            request_meta<=0;request_sync<=0;acknowledge<=0;x_raw<=0;y_raw<=0;sample_valid<=0;
        end else begin
            request_meta<=request;request_sync<=request_meta;sample_valid<=0;
            if(request_sync!=acknowledge) begin
                {x_raw,y_raw}<=held_pair;sample_valid<=1;acknowledge<=request_sync;
            end
        end
    end
endmodule
