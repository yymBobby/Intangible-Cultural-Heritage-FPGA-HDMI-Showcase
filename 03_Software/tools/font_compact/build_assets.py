"""Build 175 text glyphs + warning icon in 192 slots from frozen old bitmaps."""
from pathlib import Path
import hashlib,json,struct,zipfile
P=Path(__file__).resolve().parents[2]
F=P/'tools/font_rom/release_alarm_192';F.mkdir(exist_ok=True)
draft=P/'inputs/font176/glyph_selection.json'
read=lambda p:json.loads(p.read_text(encoding='utf-8-sig'))
sha=lambda b:hashlib.sha256(b).hexdigest()
old=P/'tools/font_rom/release_32x32_192'
old_rows=[int(x,16) for x in (old/'font_rom.hex').read_text().split()]
d=read(draft);assert d['used']==176 and d['character_count']==175
rows=[];glyphs=[];migration=[]
for g in d['glyphs']:
 i=g['glyph_id'];assert i==len(rows)//32
 rows.extend(old_rows[g['old_id']*32:(g['old_id']+1)*32])
 migration.append({'old_id':g['old_id'],'new_id':i,'char':g['char']})
 if g['char'] is not None:glyphs.append({'glyph_id':i,'char':g['char'],'unicode':f"U+{ord(g['char']):04X}"})
assert len(glyphs)==175
rows += [0]*((192-176)*32)
raw=b''.join(struct.pack('<I',x) for x in rows)
meta={'width':32,'height':32,'capacity':192,'glyph_count':175,'row_order':'top_to_bottom','left_pixel_bit':31,
 'glyphs':glyphs,'icons':[{'glyph_id':175,'name':'warning_triangle'}]}
digest=sha(json.dumps(meta,ensure_ascii=False,sort_keys=True).encode()+raw)
font_id=int(digest[:8],16) or 1
meta.update(font_set_id=font_id,sha256=digest)
mapping={g['char']:g['glyph_id'] for g in glyphs}
contract={'font_set_id':font_id,'font_set_id_hex':f'0x{font_id:08X}','glyph_count':175,'used_glyphs':176,'capacity':192,
 'icon_glyph':175,'space_glyph':mapping[' '],'comma_glyph':mapping['，'],'period_glyph':mapping['。'],
 'logical_depth':6144,'physical_depth':12288,'rom_sha256':sha(raw),'release_sha256':digest,'alarm_text':'展品离位'}
for name,data in [('glyph_map.json',meta),('manifest.json',dict(contract,width=32,height=32,rom_width=32,rom_depth=6144,
 allocated_bytes=len(raw),physical_rom_width=16,physical_rom_depth=12288,board_tested=False)),
 ('font_contract.json',contract),('mapping_migration.json',migration),('menu_extension.json',{'capacity':192,'tf_glyph_count':175,'ui_glyph_count':176,'ui_glyphs':[],'alarm_icon_id':175,'prefix_unchanged':False})]:
 if name=='manifest.json':data['sha256']=digest
 (F/name).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
(F/'font_rom.bin').write_bytes(raw)
(F/'font_rom.hex').write_text(''.join(f'{x:08X}\n' for x in rows),encoding='ascii')
(F/'font_rom.mem').write_text(''.join(f'{x:032b}\n' for x in rows),encoding='ascii')
for width,values,name in [(32,rows,'font_rom.mif'),(16,[v for x in rows for v in (x&65535,x>>16)],'font_rom_16.mif')]:
 text=f'WIDTH={width};\nDEPTH={len(values)};\nADDRESS_RADIX=HEX;\nDATA_RADIX=HEX;\nCONTENT BEGIN\n'
 text+=''.join(f'{i:04X} : {x:0{width//4}X};\n' for i,x in enumerate(values))+'END;\n'
 (F/name).write_text(text,encoding='ascii')
# Decode the original packed words, then regenerate them with the new IDs.
with zipfile.ZipFile(P/'inputs/font176/menu_template.zip') as z:
 menu=z.read('src/user_source/hdl_source/OSD/menu_text_lut.vh').decode('utf8')
import re
def replace_word(m):
 prefix,width,label=m[1],int(m[2]),m[4]
 value=sum(mapping[c]<<(8*i) for i,c in enumerate(label))
 return f"{prefix}{width}'h{value:0{width//4}x}; // {label}"
menu=re.sub(r"(\d+'d\d+:(?:menu_text_word|menu_value_word)=)(\d+)'h([\da-fA-F]+);\s*//\s*([^\r\n]+)",replace_word,menu)
menu=menu.replace('FONT_SET_ID=7F318820',f'FONT_SET_ID={font_id:08X}')
for name,char in [('SLASH','/'),('PLUS','+'),('MINUS','-'),('ZERO','0')]:
 menu=re.sub(rf"(GLYPH_{name}=8'd)\d+",lambda m:m[1]+str(mapping[char]),menu)
(F/'menu_text_lut.vh').write_text(menu,encoding='utf8')
word=sum(mapping[c]<<(8*i) for i,c in enumerate('展品离位'))
(F/'alarm_text_lut.vh').write_text(f"// Generated short alarm: 展品离位; font {font_id:08X}.\nlocalparam [127:0] ALARM_TEXT_WORD=128'h{word:032x};\nlocalparam [7:0] ALARM_ICON_GLYPH=8'd175;\n",encoding='utf8')
assert len(rows)==6144 and len(raw)==24576 and not any(rows[176*32:])
for g in d['glyphs']:assert rows[g['glyph_id']*32:(g['glyph_id']+1)*32]==old_rows[g['old_id']*32:(g['old_id']+1)*32]
print(json.dumps(contract,ensure_ascii=False),flush=True)
