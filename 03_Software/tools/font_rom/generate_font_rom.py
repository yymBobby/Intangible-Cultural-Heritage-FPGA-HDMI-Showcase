#!/usr/bin/env python3
"""UTF-8 text -> fixed-size monochrome glyph ROM. See README.md."""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import sys
import unicodedata

try:
    from PIL import Image, ImageDraw, ImageFont
    from fontTools.ttLib import TTFont
except ImportError as exc:
    raise SystemExit('缺少依赖，请执行：python -m pip install Pillow fonttools') from exc

HERE = Path(__file__).resolve().parent


def arguments():
    p = argparse.ArgumentParser(description='生成中文单色字模；默认 32×32，每行一个 32 位 ROM 数据项。')
    p.add_argument('--text', type=Path, nargs='+', default=[HERE / 'characters.txt'], help='一个或多个 UTF-8 纯文本文件；不要直接输入完整 Markdown')
    p.add_argument('--font', type=Path, default=Path('C:/Windows/Fonts/msyh.ttc'), help='TTF/OTF/TTC 字体路径')
    p.add_argument('--font-index', type=int, default=0, help='TTC 内字体序号，默认 0')
    p.add_argument('--size', type=int, choices=[16, 32], default=32)
    p.add_argument('--padding', type=int, default=1, help='画布边缘留白像素；默认 1')
    p.add_argument('--threshold', type=int, default=128, help='灰度 >= 此值为笔画，范围 1..255')
    p.add_argument('--capacity', type=int, default=256, help='ROM 字形槽位数，默认 256，最大 512')
    p.add_argument('--base-map', type=Path, help='已有 glyph_map.json；保留旧编号，新字追加到末尾')
    p.add_argument('--output', type=Path, default=HERE / 'generated')
    return p.parse_args()


def collect(files):
    chars = set()
    for path in files:
        for ch in path.read_text(encoding='utf-8-sig'):
            if ch in '\r\n':
                continue
            if unicodedata.category(ch).startswith('C') or (ch.isspace() and ch != ' '):
                raise ValueError(f'{path}: 不支持控制字符/特殊空白 U+{ord(ch):04X}，请改为普通空格或换行')
            chars.add(ch)
    chars.discard(' ')
    return sorted(chars, key=ord)


def build_mapping(chars, base):
    previous = []
    if base:
        obj = json.loads(base.read_text(encoding='utf-8'))
        previous = obj['glyphs']
        if not previous or [g['glyph_id'] for g in previous] != list(range(len(previous))):
            raise ValueError('旧映射编号必须从 0 开始连续')
        if any(len(g['char']) != 1 for g in previous):
            raise ValueError('旧映射的每个字形必须是一个 Unicode 字符')
        if previous[0]['char'] != ' ' or len({g['char'] for g in previous}) != len(previous):
            raise ValueError('旧映射必须以空格为 0，且不能有重复字符')
    ordered = [g['char'] for g in previous] if previous else [' ']
    known = set(ordered)
    ordered += [c for c in chars if c not in known]
    return ordered


def rasterize(ch, font_path, font_index, size, padding, threshold):
    image = Image.new('L', (size, size), 0)
    if ch == ' ':
        return image
    # Start at the requested size, then reduce only if ink would exceed the cell.
    # This avoids silently clipping complex characters or punctuation.
    limit = size - 2 * padding
    for font_size in range(size, 0, -1):
        font = ImageFont.truetype(str(font_path), font_size, index=font_index)
        box = font.getbbox(ch, anchor='ls')
        if box[2] - box[0] <= limit and box[3] - box[1] <= limit:
            break
    x = (size - (box[2] - box[0])) // 2 - box[0]
    baseline = size - padding + min(font.getbbox('国', anchor='ls')[3], 0)
    # Chinese ideographs are centered. Other characters share a baseline, so
    # commas/periods retain their natural low position rather than being centered.
    if 0x3400 <= ord(ch) <= 0x9FFF:
        baseline = (size - (box[3] - box[1])) // 2 - box[1]
    baseline = max(padding - box[1], min(baseline, size - padding - box[3]))
    ImageDraw.Draw(image).text((x, baseline), ch, font=font, fill=255, anchor='ls')
    return image.point(lambda value: 255 if value >= threshold else 0)


def rows_of(image, size):
    rows = []
    for y in range(size):
        value = 0
        for x in range(size):
            value = (value << 1) | int(image.getpixel((x, y)) != 0)
        rows.append(value)
    return rows


def preview(images, chars, font_path, font_index, output):
    columns, cell_w, cell_h, scale = 12, 92, 113, 2
    height = 58 + math.ceil(len(chars) / columns) * cell_h
    result = Image.new('RGB', (columns * cell_w + 24, height), '#edf2f7')
    draw = ImageDraw.Draw(result)
    label_font = ImageFont.truetype(str(font_path), 13, index=font_index)
    draw.text((12, 12), '32x32 / 16x16 ROM preview: ID + character; nearest-neighbor zoom x2', fill='#20304a', font=label_font)
    for i, (im, ch) in enumerate(zip(images, chars)):
        x, y = 12 + (i % columns) * cell_w, 48 + (i // columns) * cell_h
        draw.rectangle((x, y, x + cell_w - 5, y + cell_h - 5), fill='white')
        tile = Image.new('RGB', im.size, 'white')
        tile.paste('#162a47', (0, 0, im.width, im.height), im)
        result.paste(tile.resize((im.width * scale, im.height * scale), Image.Resampling.NEAREST), (x + 9, y + 5))
        draw.text((x + 7, y + 76), f'{i:03d} {ch if ch != " " else "SPACE"}', font=label_font, fill='#20304a')
    result.save(output)


def main():
    a = arguments()
    if not 1 <= a.threshold <= 255 or not 0 <= a.padding < a.size // 2:
        raise ValueError('threshold 必须为 1..255；padding 必须 >=0 且小于字模宽度的一半')
    if not 1 <= a.capacity <= 512 or a.font_index < 0:
        raise ValueError('capacity 必须为 1..512；font-index 必须 >=0')
    chars = build_mapping(collect(a.text), a.base_map)
    if len(chars) > a.capacity:
        raise ValueError(f'需要 {len(chars)} 个字形，超过 capacity={a.capacity}；请增大容量或减少文案')
    # Check the actual cmap; do not silently accept the font's missing-glyph box.
    with TTFont(str(a.font), fontNumber=a.font_index) as font:
        cmap = font.getBestCmap() or {}
        missing = [ch for ch in chars if ch != ' ' and (ord(ch) not in cmap or cmap[ord(ch)] == '.notdef')]
    if missing:
        raise ValueError('字体缺字：' + ' '.join(f'{c}(U+{ord(c):04X})' for c in missing))
    images = [rasterize(ch, a.font, a.font_index, a.size, a.padding, a.threshold) for ch in chars]
    empty = [ch for ch, im in zip(chars, images) if ch != ' ' and not im.getbbox()]
    if empty:
        raise ValueError('二值化后为空字形，请检查字体和阈值：' + ''.join(empty))
    rows = [value for im in images for value in rows_of(im, a.size)]
    rows.extend([0] * ((a.capacity - len(chars)) * a.size))
    raw = b''.join(value.to_bytes(a.size // 8, 'little') for value in rows)
    metadata = {'width': a.size, 'height': a.size, 'capacity': a.capacity,
                'glyph_count': len(chars), 'row_order': 'top_to_bottom',
                'left_pixel_bit': a.size - 1,
                'glyphs': [{'glyph_id': i, 'char': ch, 'unicode': f'U+{ord(ch):04X}'} for i, ch in enumerate(chars)]}
    # The identifier changes if either glyph pixels or the ID mapping changes.
    digest = hashlib.sha256(json.dumps(metadata, ensure_ascii=False, sort_keys=True).encode('utf-8') + raw).hexdigest()
    metadata['font_set_id'] = int(digest[:8], 16) or 1
    metadata['sha256'] = digest
    a.output.mkdir(parents=True, exist_ok=True)
    (a.output / 'font_rom.hex').write_text(''.join(f'{v:0{a.size // 4}X}\n' for v in rows), encoding='ascii')
    (a.output / 'font_rom.mem').write_text(''.join(f'{v:0{a.size}b}\n' for v in rows), encoding='ascii')
    (a.output / 'font_rom.bin').write_bytes(raw)
    (a.output / 'glyph_map.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    with (a.output / 'glyph_map.csv').open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['glyph_id', 'char', 'unicode'])
        writer.writerows((g['glyph_id'], g['char'], g['unicode']) for g in metadata['glyphs'])
    preview(images, chars, a.font, a.font_index, a.output / 'preview.png')
    manifest = {k: metadata[k] for k in ('width', 'height', 'capacity', 'glyph_count', 'font_set_id', 'sha256')}
    manifest.update({'rom_depth': len(rows), 'rom_width': a.size, 'payload_bytes': len(chars) * a.size * a.size // 8,
                     'allocated_bytes': len(raw), 'font_file': str(a.font.resolve()), 'font_index': a.font_index,
                     'threshold': a.threshold, 'padding': a.padding,
                     'inputs': [str(p.resolve()) for p in a.text],
                     'font_file_sha256': hashlib.sha256(a.font.read_bytes()).hexdigest()})
    (a.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'生成成功：{len(chars)} 字形，ROM {len(rows)}×{a.size} bit，分配 {len(raw)} 字节')
    print(f'font_set_id=0x{metadata["font_set_id"]:08X}；输出：{a.output.resolve()}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as exc:
        print(f'生成失败：{exc}', file=sys.stderr)
        sys.exit(1)
