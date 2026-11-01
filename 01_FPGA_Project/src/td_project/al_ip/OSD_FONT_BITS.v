`timescale 1ns/1ps
// Physical 16-bit DP ROM: two adjacent halfwords reconstruct one 32-bit row.
// Native 2048x16 BRAM32K granularity makes 12288 halfwords exactly 6 blocks.
module OSD_FONT_BITS(
    input wire clka,clkb,
    input wire [13:0] addra,addrb,
    output wire [15:0] doa,dob
);
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(14),.DATA_DEPTH_A(12288),
        .DATA_WIDTH_B(16),.ADDR_WIDTH_B(14),.DATA_DEPTH_B(12288),
        .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .IMPLEMENT("32K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
        .INIT_FILE("../../../tools/font_rom/release_alarm_192/font_rom_16.mif"),.FILL_ALL("NONE")) memory(
        .dia(16'd0),.dib(16'd0),.addra(addra),.addrb(addrb),
        .cea(1'b1),.ceb(1'b1),.ocea(1'b0),.oceb(1'b0),.clka(clka),.clkb(clkb),
        .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(doa),.dob(dob));
endmodule
