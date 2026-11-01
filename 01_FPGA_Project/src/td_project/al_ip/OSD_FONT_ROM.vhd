library ieee;
use ieee.std_logic_1164.all;
entity OSD_FONT_ROM is
 port(doa:out std_logic_vector(31 downto 0);addra:in std_logic_vector(12 downto 0);clka:in std_logic);
end entity;
architecture rtl of OSD_FONT_ROM is
 component OSD_FONT_BITS is
  port(clka,clkb:in std_logic;addra,addrb:in std_logic_vector(13 downto 0);doa,dob:out std_logic_vector(15 downto 0));
 end component;
 signal lo,hi:std_logic_vector(15 downto 0);
begin
 inst:OSD_FONT_BITS port map(clka=>clka,clkb=>clka,addra=>addra & '0',addrb=>addra & '1',doa=>lo,dob=>hi);
 doa<=hi & lo;
end architecture;
