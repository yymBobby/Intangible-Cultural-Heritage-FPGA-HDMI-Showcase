`timescale 1ns/1ps
// Logical 192-slot font interface. Keep one-cycle 32-bit row reads unchanged.
// OSD_FONT_BITS and this adapter are maintained RTL using the vendor BRAM primitive.
module OSD_FONT_ROM(output wire [31:0] doa,input wire [12:0] addra,input wire clka);
    wire [15:0] lo,hi;
    OSD_FONT_BITS inst(.clka(clka),.clkb(clka),.addra({addra,1'b0}),.addrb({addra,1'b1}),.doa(lo),.dob(hi));
    assign doa={hi,lo};
endmodule
