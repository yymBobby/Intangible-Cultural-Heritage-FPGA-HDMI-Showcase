#!/usr/bin/env python3
"""Build and verify the raw ICHSHOW2 TF-card image used by this project.

The image is intentionally a raw sector image, not a FAT file.  This tool never
writes a physical drive.  It validates all first-version media constraints before
producing an image so an invalid BMP, WAV, subtitle, or font map fails early.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys
import tempfile
import unicodedata
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


SECTOR_BYTES = 512
HEADER_LBA = 0
INDEX_LBA = 1
INDEX_SECTORS = 2
INDEX_BYTES = INDEX_SECTORS * SECTOR_BYTES
PAYLOAD_LBA = 2048
ENTRY_BYTES = 64
MAX_THEMES = 16
TEXT_MAGIC = b"ICHTXT02"
IMAGE_MAGIC = b"ICHSHOW2"


class PackError(ValueError):
    """A user-facing input or image-format error."""


@dataclass(frozen=True)
class FontMap:
    width: int
    height: int
    capacity: int
    glyph_count: int
    font_set_id: int
    release_sha256: Optional[str]
    char_to_id: Dict[str, int]
    source_path: Path


@dataclass
class ThemePayload:
    theme_id: int
    name: str
    image_path: Path
    image_data: bytes
    audio_path: Optional[Path]
    audio_data: Optional[bytes]
    text_path: Optional[Path]
    text_data: bytes
    display_time_ms: int
    image_lba: int = 0
    audio_lba: int = 0
    text_lba: int = 0


def _u32(value: Any, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise PackError(f"{field} 必须是整数")
    if not minimum <= value <= 0xFFFFFFFF:
        raise PackError(f"{field} 必须在 {minimum}..4294967295 范围内")
    return value


def _read_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as exc:
        raise PackError(f"找不到文件：{path}") from exc
    except UnicodeDecodeError as exc:
        raise PackError(f"JSON 文件必须是 UTF-8：{path}") from exc
    except json.JSONDecodeError as exc:
        raise PackError(f"JSON 格式错误：{path}:{exc.lineno}:{exc.colno} {exc.msg}") from exc
    except OSError as exc:
        raise PackError(f"无法读取 JSON 文件：{path}（{exc}）") from exc
    if not isinstance(value, dict):
        raise PackError(f"JSON 顶层必须是对象：{path}")
    return value


def load_font_map(path: Path) -> FontMap:
    raw = _read_json(path)
    required = (
        "width", "height", "capacity", "glyph_count", "row_order",
        "left_pixel_bit", "font_set_id", "glyphs",
    )
    missing = [key for key in required if key not in raw]
    if missing:
        raise PackError(f"字库映射缺少字段：{', '.join(missing)}")

    width = _u32(raw["width"], "glyph_map.width", minimum=1)
    height = _u32(raw["height"], "glyph_map.height", minimum=1)
    capacity = _u32(raw["capacity"], "glyph_map.capacity", minimum=1)
    glyph_count = _u32(raw["glyph_count"], "glyph_map.glyph_count", minimum=1)
    font_set_id = _u32(raw["font_set_id"], "glyph_map.font_set_id", minimum=1)
    glyphs = raw["glyphs"]

    if (width, height) != (32, 32):
        raise PackError(f"当前接口只接受 32x32 字模，实际为 {width}x{height}")
    if raw["row_order"] != "top_to_bottom":
        raise PackError("glyph_map.row_order 必须为 top_to_bottom，与 OSD ROM 行序一致")
    if _u32(raw["left_pixel_bit"], "glyph_map.left_pixel_bit") != 31:
        raise PackError("glyph_map.left_pixel_bit 必须为 31，与 OSD ROM 位序一致")
    if capacity > 512 or glyph_count > capacity:
        raise PackError("glyph_count 必须不大于 capacity，且 capacity 不能超过 512")
    if not isinstance(glyphs, list) or len(glyphs) != glyph_count:
        raise PackError("glyphs 列表长度必须等于 glyph_count")

    char_to_id: Dict[str, int] = {}
    ids = set()
    for index, item in enumerate(glyphs):
        if not isinstance(item, dict):
            raise PackError(f"glyphs[{index}] 必须是对象")
        glyph_id = _u32(item.get("glyph_id"), f"glyphs[{index}].glyph_id")
        char = item.get("char")
        if not isinstance(char, str) or len(char) != 1:
            raise PackError(f"glyphs[{index}].char 必须恰好包含一个 Unicode 字符")
        if glyph_id >= glyph_count:
            raise PackError(f"glyph_id {glyph_id} 超出有效范围 0..{glyph_count - 1}")
        if glyph_id in ids or char in char_to_id:
            raise PackError(f"字库映射存在重复编号或字符：{glyph_id} / {char!r}")
        ids.add(glyph_id)
        char_to_id[char] = glyph_id

    if ids != set(range(glyph_count)):
        raise PackError("glyph_id 必须从 0 到 glyph_count-1 连续编号")
    if char_to_id.get(" ") != 0:
        raise PackError("接口要求半角空格的 glyph_id 固定为 0")

    declared_digest = raw.get("sha256")
    if declared_digest is not None:
        if (
            not isinstance(declared_digest, str)
            or len(declared_digest) != 64
            or any(char not in "0123456789abcdefABCDEF" for char in declared_digest)
        ):
            raise PackError("glyph_map.sha256 必须是 64 位十六进制字符串")
        rom_path = path.parent / "font_rom.bin"
        try:
            rom_data = rom_path.read_bytes()
        except FileNotFoundError as exc:
            raise PackError(f"字库映射声明了 sha256，但缺少配套字模：{rom_path}") from exc
        except OSError as exc:
            raise PackError(f"无法读取配套字模：{rom_path}（{exc}）") from exc
        if len(rom_data) != capacity * width * height // 8:
            raise PackError("font_rom.bin 长度与 glyph_map 的字形尺寸/容量不一致")
        metadata = dict(raw)
        metadata.pop("font_set_id", None)
        metadata.pop("sha256", None)
        actual_digest = hashlib.sha256(
            json.dumps(metadata, ensure_ascii=False, sort_keys=True).encode("utf-8") + rom_data
        ).hexdigest()
        if actual_digest.lower() != declared_digest.lower():
            raise PackError("glyph_map.json 与同目录 font_rom.bin 不是同一次发布的配套文件")

        # font_set_id 是 A 发布的版本号；当前生成器使用 SHA 前 32 位，
        # 但协议也允许 A 人工指定非零值。若有发布清单，额外核对版本号。
        manifest_path = path.parent / "manifest.json"
        if manifest_path.exists():
            manifest = _read_json(manifest_path)
            manifest_id = _u32(manifest.get("font_set_id"), "manifest.font_set_id", minimum=1)
            manifest_digest = manifest.get("sha256")
            if manifest_id != font_set_id or not isinstance(manifest_digest, str) or manifest_digest.lower() != declared_digest.lower():
                raise PackError("manifest.json 与 glyph_map.json 的字库版本或 SHA-256 不一致")

    return FontMap(width, height, capacity, glyph_count, font_set_id, declared_digest, char_to_id, path)


def layout_subtitle(text: str, font: FontMap, label: str) -> List[int]:
    if not isinstance(text, str):
        raise PackError(f"{label} 的 text 必须是字符串")

    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if normalized.endswith("\n"):
        normalized = normalized[:-1]

    tokens: List[int] = []
    row = 0
    col = 0
    missing: List[str] = []

    for char in normalized:
        if char == "\n":
            if col == 16:
                row += 1
                col = 0
            else:
                padding = 16 - col
                if len(tokens) + padding > 64:
                    raise PackError(f"{label} 超过 4 行 x 16 列")
                tokens.extend([0] * padding)
                row += 1
                col = 0
            if row > 4:
                raise PackError(f"{label} 超过 4 行 x 16 列")
            continue

        if unicodedata.category(char).startswith("C"):
            raise PackError(f"{label} 含不允许的控制字符 U+{ord(char):04X}")
        if col == 16:
            row += 1
            col = 0
        if row >= 4 or len(tokens) >= 64:
            raise PackError(f"{label} 超过 4 行 x 16 列")
        glyph_id = font.char_to_id.get(char)
        if glyph_id is None:
            missing.append(f"{char}(U+{ord(char):04X})")
        else:
            tokens.append(glyph_id)
        col += 1

    if missing:
        unique = list(dict.fromkeys(missing))
        raise PackError(f"{label} 的字库缺字：{', '.join(unique)}")
    if len(tokens) > 64:
        raise PackError(f"{label} 超过 64 个字模编号")
    return tokens


def make_text_resource(text: str, font: FontMap, label: str) -> bytes:
    tokens = layout_subtitle(text, font, label)
    payload = b"".join(struct.pack("<H", token) for token in tokens)
    header = struct.pack(
        "<8sHBBIHBBI",
        TEXT_MAGIC,
        2,
        font.width,
        font.height,
        font.font_set_id,
        len(tokens),
        16,
        4,
        zlib.crc32(payload) & 0xFFFFFFFF,
    )
    if len(header) != 24:
        raise AssertionError("internal ICHTXT02 header size error")
    return header + payload


def validate_bmp_bytes(data: bytes, label: str) -> None:
    if len(data) < 54 or data[:2] != b"BM":
        raise PackError(f"{label} 不是有效的 BMP 文件")
    file_size = struct.unpack_from("<I", data, 2)[0]
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    dib_size = struct.unpack_from("<I", data, 14)[0]
    width, height, planes, bit_count, compression = struct.unpack_from("<iiHHI", data, 18)

    if file_size != len(data):
        raise PackError(f"{label} 的 BMP 文件头长度 {file_size} 与实际长度 {len(data)} 不一致")
    if dib_size != 40:
        raise PackError(f"{label} 只支持 40 字节 BITMAPINFOHEADER，实际为 {dib_size}")
    if (width, height) != (640, 480):
        raise PackError(f"{label} 第一版只支持正高度 640x480，实际为 {width}x{height}")
    if planes != 1 or bit_count != 24 or compression != 0:
        raise PackError(f"{label} 必须为 planes=1、24-bit、BI_RGB 无压缩 BMP")
    if pixel_offset < 54 or pixel_offset > len(data):
        raise PackError(f"{label} 的 bfOffBits={pixel_offset} 非法")
    row_bytes = ((width * 3 + 3) // 4) * 4
    required_end = pixel_offset + row_bytes * height
    if required_end > len(data):
        raise PackError(f"{label} 像素数据截断：至少需要 {required_end} 字节")


def validate_wav_bytes(data: bytes, label: str) -> None:
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise PackError(f"{label} 不是 RIFF/WAVE 文件")
    riff_size = struct.unpack_from("<I", data, 4)[0]
    if riff_size + 8 != len(data):
        raise PackError(f"{label} 的 RIFF 长度与实际文件长度不一致")

    offset = 12
    fmt_count = 0
    data_count = 0
    fmt_seen = False
    while offset < len(data):
        if offset + 8 > len(data):
            raise PackError(f"{label} 的 RIFF chunk 头截断")
        chunk_id = data[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", data, offset + 4)[0]
        payload_start = offset + 8
        payload_end = payload_start + chunk_size
        if payload_end > len(data):
            raise PackError(f"{label} 的 {chunk_id!r} chunk 超出文件边界")

        if chunk_id == b"fmt ":
            fmt_count += 1
            if fmt_count > 1:
                raise PackError(f"{label} 第一版要求恰好一个 fmt chunk")
            if chunk_size < 16:
                raise PackError(f"{label} 的 fmt chunk 少于 16 字节")
            audio_format, channels, sample_rate, byte_rate, block_align, bits = struct.unpack_from(
                "<HHIIHH", data, payload_start
            )
            if (audio_format, channels, sample_rate, byte_rate, block_align, bits) != (
                1,
                2,
                48_000,
                192_000,
                4,
                16,
            ):
                raise PackError(
                    f"{label} 必须是 PCM、48kHz、16-bit、双声道；"
                    f"实际 format={audio_format}, channels={channels}, rate={sample_rate}, "
                    f"byte_rate={byte_rate}, align={block_align}, bits={bits}"
                )
            fmt_seen = True
        elif chunk_id == b"data":
            data_count += 1
            if not fmt_seen:
                raise PackError(f"{label} 的 data chunk 出现在 fmt chunk 之前")
            if data_count > 1:
                raise PackError(f"{label} 第一版要求恰好一个 data chunk")
            if chunk_size == 0 or chunk_size % 4:
                raise PackError(f"{label} 的 PCM data 长度必须大于 0 且为 4 的整数倍")

        offset = payload_end + (chunk_size & 1)
        if offset > len(data):
            raise PackError(f"{label} 缺少 RIFF 奇数字节 chunk 的填充字节")

    if fmt_count != 1 or data_count != 1:
        raise PackError(f"{label} 必须恰好包含一个 fmt chunk 和一个 data chunk")


def validate_text_bytes(data: bytes, font_set_id: int, glyph_count: int, label: str) -> List[int]:
    if len(data) < 24:
        raise PackError(f"{label} 少于 24 字节")
    magic, version, width, height, text_font_id, count, columns, rows, crc = struct.unpack_from(
        "<8sHBBIHBBI", data, 0
    )
    if magic != TEXT_MAGIC or version != 2:
        raise PackError(f"{label} 的魔数或版本错误")
    if (width, height, columns, rows) != (32, 32, 16, 4):
        raise PackError(f"{label} 的字形或排版参数必须是 32x32、16列x4行")
    if text_font_id != font_set_id:
        raise PackError(f"{label} 的 font_set_id 与镜像头不一致")
    if count > 64 or len(data) != 24 + count * 2:
        raise PackError(f"{label} 的 token_count 或实际长度错误")
    payload = data[24:]
    if (zlib.crc32(payload) & 0xFFFFFFFF) != crc:
        raise PackError(f"{label} 的编号载荷 CRC-32 错误")
    tokens = list(struct.unpack(f"<{count}H", payload)) if count else []
    if any(token >= glyph_count for token in tokens):
        raise PackError(f"{label} 含超出 glyph_count={glyph_count} 的编号")
    return tokens


def _resolve_media_path(config_dir: Path, value: Any, field: str) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise PackError(f"{field} 必须是非空路径字符串")
    path = Path(value)
    return (config_dir / path).resolve() if not path.is_absolute() else path.resolve()


def _load_text(theme: Dict[str, Any], config_dir: Path, label: str) -> Tuple[str, Optional[Path]]:
    has_text = "text" in theme
    has_file = "text_file" in theme
    if has_text == has_file:
        raise PackError(f"{label} 必须且只能提供 text 或 text_file 之一")
    if has_text:
        value = theme["text"]
        if not isinstance(value, str):
            raise PackError(f"{label}.text 必须是字符串")
        return value, None
    path = _resolve_media_path(config_dir, theme["text_file"], f"{label}.text_file")
    try:
        return path.read_text(encoding="utf-8-sig"), path
    except FileNotFoundError as exc:
        raise PackError(f"找不到字幕文本：{path}") from exc
    except UnicodeDecodeError as exc:
        raise PackError(f"字幕文本必须是 UTF-8：{path}") from exc


def load_themes(config_path: Path, font: FontMap) -> List[ThemePayload]:
    raw = _read_json(config_path)
    themes = raw.get("themes")
    if not isinstance(themes, list) or not 1 <= len(themes) <= MAX_THEMES:
        raise PackError("themes 必须包含 1..16 个主题")

    config_dir = config_path.parent.resolve()
    result: List[ThemePayload] = []
    for expected_id, theme in enumerate(themes):
        if not isinstance(theme, dict):
            raise PackError(f"themes[{expected_id}] 必须是对象")
        theme_id = _u32(theme.get("theme_id"), f"themes[{expected_id}].theme_id")
        if theme_id != expected_id:
            raise PackError(f"主题必须从 0 连续编号；第 {expected_id} 条的 theme_id={theme_id}")
        name = theme.get("name", f"theme-{theme_id}")
        if not isinstance(name, str) or not name:
            raise PackError(f"themes[{theme_id}].name 必须是非空字符串")
        display_time_ms = _u32(theme.get("display_time_ms", 0), f"themes[{theme_id}].display_time_ms")

        image_path = _resolve_media_path(config_dir, theme.get("image"), f"themes[{theme_id}].image")
        try:
            image_data = image_path.read_bytes()
        except FileNotFoundError as exc:
            raise PackError(f"找不到 BMP：{image_path}") from exc
        validate_bmp_bytes(image_data, f"主题 {theme_id} {name} 的 BMP")

        audio_value = theme.get("audio")
        audio_path: Optional[Path] = None
        audio_data: Optional[bytes] = None
        if audio_value is not None:
            audio_path = _resolve_media_path(config_dir, audio_value, f"themes[{theme_id}].audio")
            try:
                audio_data = audio_path.read_bytes()
            except FileNotFoundError as exc:
                raise PackError(f"找不到 WAV：{audio_path}") from exc
            validate_wav_bytes(audio_data, f"主题 {theme_id} {name} 的 WAV")

        subtitle, text_path = _load_text(theme, config_dir, f"主题 {theme_id} {name}")
        text_data = make_text_resource(subtitle, font, f"主题 {theme_id} {name}")
        result.append(
            ThemePayload(
                theme_id,
                name,
                image_path,
                image_data,
                audio_path,
                audio_data,
                text_path,
                text_data,
                display_time_ms,
            )
        )
    return result


def _sectors_for(size: int) -> int:
    return (size + SECTOR_BYTES - 1) // SECTOR_BYTES


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _write_payload(handle: Any, data: bytes) -> None:
    handle.write(data)
    padding = (-len(data)) % SECTOR_BYTES
    if padding:
        handle.write(b"\x00" * padding)


def _write_report(path: Path, report: Dict[str, Any]) -> None:
    temp_name: Optional[str] = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="\n", delete=False,
            dir=path.parent, prefix=path.name + ".", suffix=".tmp",
        ) as handle:
            temp_name = handle.name
            json.dump(report, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)


def build_image(config_path: Path, glyph_map_path: Path, output_path: Path, report_path: Path, force: bool) -> Dict[str, Any]:
    font = load_font_map(glyph_map_path)
    themes = load_themes(config_path, font)
    output_path = output_path.resolve()
    report_path = report_path.resolve()
    protected_paths = {config_path.resolve(), glyph_map_path.resolve()}
    font_rom_path = glyph_map_path.resolve().parent / "font_rom.bin"
    if font_rom_path.exists():
        protected_paths.add(font_rom_path.resolve())
    manifest_path = glyph_map_path.resolve().parent / "manifest.json"
    if manifest_path.exists():
        protected_paths.add(manifest_path.resolve())

    if output_path == report_path:
        raise PackError("镜像与报告不能使用同一个输出路径")
    source_paths = {theme.image_path for theme in themes}
    source_paths.update(theme.audio_path for theme in themes if theme.audio_path is not None)
    source_paths.update(theme.text_path for theme in themes if theme.text_path is not None)
    if (
        output_path in source_paths
        or report_path in source_paths
        or output_path in protected_paths
        or report_path in protected_paths
    ):
        raise PackError("输出路径不能覆盖配置、字库发布文件或输入素材")
    if not force and (output_path.exists() or report_path.exists()):
        raise PackError("输出文件已存在；确认后使用 --force 覆盖")

    next_lba = PAYLOAD_LBA
    for theme in themes:
        for data, kind in ((theme.image_data, "BMP"), (theme.text_data, "字幕")):
            if len(data) > 0xFFFFFFFF:
                raise PackError(f"主题 {theme.theme_id} 的 {kind} 超过 32 位长度字段范围")
        if theme.audio_data is not None and len(theme.audio_data) > 0xFFFFFFFF:
            raise PackError(f"主题 {theme.theme_id} 的 WAV 超过 32 位长度字段范围")
        theme.image_lba = next_lba
        next_lba += _sectors_for(len(theme.image_data))
        if theme.audio_data is not None:
            theme.audio_lba = next_lba
            next_lba += _sectors_for(len(theme.audio_data))
        theme.text_lba = next_lba
        next_lba += _sectors_for(len(theme.text_data))
        if next_lba > 0xFFFFFFFF:
            raise PackError("镜像扇区数超过 ICHSHOW2 的 32 位 LBA 范围")
    image_total_sectors = next_lba

    index = bytearray(INDEX_BYTES)
    for theme in themes:
        flags = 0x01 | 0x04 | (0x02 if theme.audio_data is not None else 0)
        entry = bytearray(ENTRY_BYTES)
        struct.pack_into(
            "<BBBBIIIIIII",
            entry,
            0,
            theme.theme_id,
            flags,
            0,
            0,
            theme.image_lba,
            len(theme.image_data),
            theme.audio_lba,
            len(theme.audio_data) if theme.audio_data is not None else 0,
            theme.display_time_ms,
            theme.text_lba,
            len(theme.text_data),
        )
        start = theme.theme_id * ENTRY_BYTES
        index[start : start + ENTRY_BYTES] = entry
    header = bytearray(SECTOR_BYTES)
    struct.pack_into(
        "<8sIIIIIIIIIII",
        header,
        0,
        IMAGE_MAGIC,
        2,
        SECTOR_BYTES,
        len(themes),
        ENTRY_BYTES,
        INDEX_LBA,
        INDEX_SECTORS,
        PAYLOAD_LBA,
        image_total_sectors,
        zlib.crc32(index) & 0xFFFFFFFF,
        font.font_set_id,
        font.glyph_count,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    temp_name: Optional[str] = None
    verified: Optional[Dict[str, Any]] = None
    try:
        with tempfile.NamedTemporaryFile("wb", delete=False, dir=output_path.parent, prefix=output_path.name + ".", suffix=".tmp") as handle:
            temp_name = handle.name
            handle.write(header)
            handle.write(index)
            reserved_bytes = (PAYLOAD_LBA - INDEX_LBA - INDEX_SECTORS) * SECTOR_BYTES
            zero_block = b"\x00" * (1024 * 1024)
            while reserved_bytes:
                chunk = min(reserved_bytes, len(zero_block))
                handle.write(zero_block[:chunk])
                reserved_bytes -= chunk
            for theme in themes:
                _write_payload(handle, theme.image_data)
                if theme.audio_data is not None:
                    _write_payload(handle, theme.audio_data)
                _write_payload(handle, theme.text_data)
        verified = inspect_image(Path(temp_name))
        for theme, checked in zip(themes, verified["themes"]):
            if checked["image_sha256"] != _sha256(theme.image_data):
                raise PackError(f"主题 {theme.theme_id} 的 BMP 镜像回读与输入不一致")
            if checked["text_sha256"] != _sha256(theme.text_data):
                raise PackError(f"主题 {theme.theme_id} 的字幕镜像回读与输入不一致")
            expected_audio_sha = _sha256(theme.audio_data) if theme.audio_data is not None else None
            if checked["audio_sha256"] != expected_audio_sha:
                raise PackError(f"主题 {theme.theme_id} 的 WAV 镜像回读与输入不一致")
        os.replace(temp_name, output_path)
        temp_name = None
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)

    if verified is None:
        raise AssertionError("internal image verification did not run")
    report: Dict[str, Any] = {
        "format": "ICHSHOW2",
        "version": 2,
        "image": str(output_path),
        "image_bytes": verified["image_total_sectors"] * SECTOR_BYTES,
        "image_sha256": verified["image_sha256"],
        "font_map": str(font.source_path.resolve()),
        "font_set_id": f"0x{font.font_set_id:08X}",
        "font_release_sha256": font.release_sha256,
        "glyph_count": font.glyph_count,
        "theme_count": len(themes),
        "verified": True,
        "themes": [],
    }
    for theme, checked in zip(themes, verified["themes"]):
        item = {
            "theme_id": theme.theme_id,
            "name": theme.name,
            "display_time_ms": theme.display_time_ms,
            "image": {
                "resource_id": theme.theme_id * 2,
                "source": str(theme.image_path),
                "start_lba": theme.image_lba,
                "bytes": len(theme.image_data),
                "sha256": _sha256(theme.image_data),
            },
            "audio": None,
            "text": {
                "resource_id": 0x80 + theme.theme_id,
                "start_lba": theme.text_lba,
                "bytes": len(theme.text_data),
                "token_count": checked["text_token_count"],
                "sha256": _sha256(theme.text_data),
            },
        }
        if theme.audio_data is not None and theme.audio_path is not None:
            item["audio"] = {
                "resource_id": theme.theme_id * 2 + 1,
                "source": str(theme.audio_path),
                "start_lba": theme.audio_lba,
                "bytes": len(theme.audio_data),
                "sha256": _sha256(theme.audio_data),
            }
        report["themes"].append(item)

    _write_report(report_path, report)
    return report


def _resource_bytes(image: bytes, lba: int, length: int, label: str) -> bytes:
    start = lba * SECTOR_BYTES
    end = start + length
    if lba < PAYLOAD_LBA or length <= 0 or end > len(image):
        raise PackError(f"{label} 的 LBA/长度越界")
    padded_end = start + _sectors_for(length) * SECTOR_BYTES
    if padded_end > len(image):
        raise PackError(f"{label} 的扇区范围越界")
    if any(image[end:padded_end]):
        raise PackError(f"{label} 的末扇区填充必须全零")
    return image[start:end]


def inspect_image(
    path: Path, extract_dir: Optional[Path] = None, report_path: Optional[Path] = None
) -> Dict[str, Any]:
    try:
        image = path.read_bytes()
    except FileNotFoundError as exc:
        raise PackError(f"找不到镜像：{path}") from exc
    if len(image) < PAYLOAD_LBA * SECTOR_BYTES or len(image) % SECTOR_BYTES:
        raise PackError("镜像长度必须是 512 的整数倍，且至少包含保留区")

    fields = struct.unpack_from("<8sIIIIIIIIIII", image, 0)
    (
        magic,
        version,
        sector_bytes,
        theme_count,
        entry_bytes,
        index_lba,
        index_sectors,
        payload_lba,
        total_sectors,
        index_crc,
        font_set_id,
        glyph_count,
    ) = fields
    if magic != IMAGE_MAGIC or version != 2:
        raise PackError("镜像魔数或版本错误；v2 读取端必须拒绝 ICHSHOW1/v1")
    if (sector_bytes, entry_bytes, index_lba, index_sectors, payload_lba) != (
        SECTOR_BYTES,
        ENTRY_BYTES,
        INDEX_LBA,
        INDEX_SECTORS,
        PAYLOAD_LBA,
    ):
        raise PackError("镜像固定布局字段错误")
    if not 1 <= theme_count <= MAX_THEMES or not 1 <= glyph_count <= 512 or font_set_id == 0:
        raise PackError("theme_count、glyph_count 或 font_set_id 非法")
    if total_sectors * SECTOR_BYTES != len(image):
        raise PackError("image_total_sectors 与镜像实际长度不一致")
    if any(image[52:SECTOR_BYTES]):
        raise PackError("LBA 0 保留字节必须全零")

    index_start = INDEX_LBA * SECTOR_BYTES
    index = image[index_start : index_start + INDEX_BYTES]
    if (zlib.crc32(index) & 0xFFFFFFFF) != index_crc:
        raise PackError("资源表 CRC-32 错误")
    if any(index[theme_count * ENTRY_BYTES :]):
        raise PackError("未使用的资源记录必须全零")
    reserved_start = (INDEX_LBA + INDEX_SECTORS) * SECTOR_BYTES
    reserved_end = PAYLOAD_LBA * SECTOR_BYTES
    if any(image[reserved_start:reserved_end]):
        raise PackError("LBA 3..2047 保留区必须全零")

    ranges: List[Tuple[int, int, str]] = []
    result: Dict[str, Any] = {
        "path": str(path.resolve()),
        "image_sha256": _sha256(image),
        "theme_count": theme_count,
        "font_set_id": f"0x{font_set_id:08X}",
        "glyph_count": glyph_count,
        "image_total_sectors": total_sectors,
        "themes": [],
    }
    extracted: List[Tuple[Path, bytes]] = []

    for expected_id in range(theme_count):
        entry = index[expected_id * ENTRY_BYTES : (expected_id + 1) * ENTRY_BYTES]
        values = struct.unpack_from("<BBBBIIIIIII", entry, 0)
        theme_id, flags, reserved2, reserved3, image_lba, image_bytes, audio_lba, audio_bytes, dwell_ms, text_lba, text_bytes = values
        if theme_id != expected_id or reserved2 or reserved3 or any(entry[32:]):
            raise PackError(f"主题 {expected_id} 的编号或保留字段错误")
        if flags & ~0x07 or not (flags & 0x01) or not (flags & 0x04):
            raise PackError(f"主题 {expected_id} 的 flags 非法")
        has_audio = bool(flags & 0x02)
        if has_audio != bool(audio_bytes) or (not has_audio and audio_lba != 0):
            raise PackError(f"主题 {expected_id} 的音频 flags 与地址/长度不一致")
        if not 24 <= text_bytes <= 152:
            raise PackError(f"主题 {expected_id} 的字幕长度超出 24..152")

        bmp = _resource_bytes(image, image_lba, image_bytes, f"主题 {expected_id} BMP")
        text = _resource_bytes(image, text_lba, text_bytes, f"主题 {expected_id} 字幕")
        validate_bmp_bytes(bmp, f"主题 {expected_id} BMP")
        tokens = validate_text_bytes(text, font_set_id, glyph_count, f"主题 {expected_id} 字幕")
        ranges.append((image_lba, image_lba + _sectors_for(image_bytes), f"theme {expected_id} image"))
        ranges.append((text_lba, text_lba + _sectors_for(text_bytes), f"theme {expected_id} text"))

        audio = None
        if has_audio:
            audio = _resource_bytes(image, audio_lba, audio_bytes, f"主题 {expected_id} WAV")
            validate_wav_bytes(audio, f"主题 {expected_id} WAV")
            ranges.append((audio_lba, audio_lba + _sectors_for(audio_bytes), f"theme {expected_id} audio"))

        result["themes"].append(
            {
                "theme_id": theme_id,
                "flags": flags,
                "display_time_ms": dwell_ms,
                "image_lba": image_lba,
                "image_bytes": image_bytes,
                "audio_lba": audio_lba,
                "audio_bytes": audio_bytes,
                "text_lba": text_lba,
                "text_bytes": text_bytes,
                "text_token_count": len(tokens),
                "image_sha256": _sha256(bmp),
                "audio_sha256": _sha256(audio) if audio is not None else None,
                "text_sha256": _sha256(text),
            }
        )
        if extract_dir is not None:
            extracted.append((extract_dir / f"theme_{theme_id:02d}_image.bmp", bmp))
            extracted.append((extract_dir / f"theme_{theme_id:02d}_text.ichtxt", text))
            if audio is not None:
                extracted.append((extract_dir / f"theme_{theme_id:02d}_audio.wav", audio))

    ranges.sort()
    for index_in_ranges, (start, end, label) in enumerate(ranges):
        if start < PAYLOAD_LBA or end > total_sectors or start >= end:
            raise PackError(f"{label} 的扇区范围非法")
        if index_in_ranges and start < ranges[index_in_ranges - 1][1]:
            raise PackError(f"资源扇区范围重叠：{ranges[index_in_ranges - 1][2]} 与 {label}")

    if report_path is not None:
        verify_report(result, report_path)

    if extract_dir is not None:
        if extract_dir.exists() and not extract_dir.is_dir():
            raise PackError(f"提取路径不是文件夹：{extract_dir}")
        existing = [target for target, _ in extracted if target.exists()]
        if existing:
            raise PackError(f"提取目标已存在，未覆盖：{existing[0]}")
        extract_dir.mkdir(parents=True, exist_ok=True)
        for target, data in extracted:
            target.write_bytes(data)
    return result


def verify_report(checked: Dict[str, Any], report_path: Path) -> None:
    report = _read_json(report_path)
    expected_sha = report.get("image_sha256")
    if report.get("format") != "ICHSHOW2" or report.get("version") != 2:
        raise PackError("报告的镜像格式或版本不正确")
    if (
        not isinstance(expected_sha, str)
        or len(expected_sha) != 64
        or any(char not in "0123456789abcdefABCDEF" for char in expected_sha)
    ):
        raise PackError("报告缺少有效的 image_sha256")
    expected_bytes = report.get("image_bytes")
    if isinstance(expected_bytes, bool) or not isinstance(expected_bytes, int):
        raise PackError("报告缺少有效的 image_bytes")
    if expected_bytes != checked["image_total_sectors"] * SECTOR_BYTES:
        raise PackError("镜像长度与报告不一致")
    if expected_sha.lower() != checked["image_sha256"]:
        raise PackError("镜像 SHA-256 与报告不一致；素材内容可能被修改")


def default_glyph_map_path() -> Path:
    return Path(__file__).resolve().parents[1] / "font_rom" / "release_32x32_192" / "glyph_map.json"


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="构建和校验 ICHSHOW2 v2 原始 TF 卡镜像")
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build", help="按配置构建镜像并自动回读校验")
    build.add_argument("config", type=Path, help="主题配置 JSON")
    build.add_argument("output", type=Path, help="输出 .img 路径")
    build.add_argument("--glyph-map", type=Path, default=default_glyph_map_path(), help="A 发布的 glyph_map.json")
    build.add_argument("--report", type=Path, default=None, help="校验报告 JSON；默认与镜像同名 .report.json")
    build.add_argument("--force", action="store_true", help="覆盖已存在的镜像和报告")

    verify = subparsers.add_parser("verify", help="独立校验已有镜像")
    verify.add_argument("image", type=Path, help="待校验 .img")
    verify.add_argument("--report", type=Path, default=None, help="可选：与构建报告中的 SHA-256 比对")
    verify.add_argument("--extract-dir", type=Path, default=None, help="可选：回读提取每个资源")
    return parser.parse_args(argv)


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "build":
            report_path = args.report or args.output.with_suffix(".report.json")
            report = build_image(args.config, args.glyph_map, args.output, report_path, args.force)
            print(f"[成功] 镜像已生成并通过回读校验：{report['image']}")
            print(f"[成功] 主题数：{report['theme_count']}，SHA-256：{report['image_sha256']}")
            print(f"[成功] 报告：{report_path.resolve()}")
        else:
            result = inspect_image(args.image, args.extract_dir, args.report)
            print(
                f"[成功] ICHSHOW2 镜像校验通过：主题 {result['theme_count']} 个，"
                f"font_set_id={result['font_set_id']}，glyph_count={result['glyph_count']}"
            )
            if args.extract_dir is not None:
                print(f"[成功] 资源已提取到：{args.extract_dir.resolve()}")
        return 0
    except PackError as exc:
        print(f"[错误] {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"[系统错误] 文件读写失败：{exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
