// Procedural BMP fixture, independent coordinate-based expected image.
// Including module provides fixture_offset, fixture_tail, fixture_variant.
function automatic [31:0] fixture_word(input integer row,input integer col);
    reg [7:0] r,g,b;
    begin r=(row*7+col*3+19)&255;g=(row*11+col+83)&255;b=(row+col*13+137)&255;
        fixture_word={r,g,b,8'h00};end
endfunction
function automatic [7:0] fixture_byte(input integer position);
    integer value,k,n;reg [31:0] word_value;
    begin
        value=0;
        case(position)
            0:value=8'h42;1:value=8'h4d;
            2,3,4,5:value=(fixture_offset+921600+fixture_tail)>>((position-2)*8);
            10,11,12,13:value=fixture_offset>>((position-10)*8);
            14:value=40;18:value=640&255;19:value=640>>8;
            22:value=480&255;23:value=480>>8;26:value=1;28:value=24;
            default: ;
        endcase
        if(position>=fixture_offset && position<fixture_offset+921600) begin
            k=position-fixture_offset;n=k/3;
            word_value=fixture_word(479-n/640,n%640);
            case(k%3) 0:value=word_value[15:8];1:value=word_value[23:16];2:value=word_value[31:24];endcase
        end
        case(fixture_variant)
            1:if(position==0)value=0;
            2:if(position==14)value=108;
            3:if(position==18)value=0;
            4:if(position>=22 && position<=25)value=32'hfffffe20>>((position-22)*8);
            5:if(position==26)value=2;
            6:if(position==28)value=32;
            7:if(position==30)value=1;
            8:if(position==2)value=value^1;
            9:if(position>=10 && position<=13)value=32'd40>>((position-10)*8);
            10:if(position>=10 && position<=13)value=(fixture_offset+10)>>((position-10)*8);
            11:if(position==34)value=1;
            12:if(position==6)value=1;
            13:if(position>=10 && position<=13)value=32'hfffffff0>>((position-10)*8);
            14:if(position==20)value=1; // Example 5 ignores width upper 16 bits.
            15:if(position==24)value=1; // Example 5 ignores height upper 16 bits.
            16:begin // Fields intentionally not checked by the legacy policy.
                if(position==2)value=value^1;
                if(position==6)value=1;
                if(position==14)value=108;
                if(position==20 || position==24)value=1;
                if(position==26)value=2;
                if(position==34)value=1;
            end
            default: ;
        endcase
        fixture_byte=value[7:0];
    end
endfunction
