#!/usr/bin/env python3
"""PC-only ICHSHOW3 v0.1 draft builder/verifier. Never writes a TF device."""
from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "media_pack"))
from build_media_image import (PackError, load_font_map, make_text_resource,
                              validate_bmp_bytes, validate_wav_bytes, validate_text_bytes)

SECTOR = 512
PAYLOAD_LBA = 2048
FONT_ID = 0xCBE17BCF
GLYPHS = 175
FONT_RELEASE_SHA256 = "cbe17bcffcc83efc70249a9bc8c58144128a67fd49ab971922761d8f29c9805b"
NAMES = ("京剧", "醒狮", "古琴", "打铁花")
HEADER = struct.Struct("<8s14I")
THEME = struct.Struct("<4B7I")
PICTURE = struct.Struct("<4BIIHH4I")
HEADER_FIXED = (b"ICHSHOW3", 3, 512, 4, 4, 32, 32, 1, 2, 2, 2048)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def u32(value, label: str, minimum: int = 0) -> int:
    if type(value) is not int or not minimum <= value <= 0xFFFFFFFF:
        raise PackError(f"{label}: expected integer {minimum}..4294967295")
    return value


def sectors(length: int) -> int:
    return (length + 511) // 512


def check_range(lba: int, length: int, total: int) -> int:
    u32(lba, "resource LBA", PAYLOAD_LBA)
    u32(length, "resource bytes", 1)
    u32(total, "total sectors", PAYLOAD_LBA + 1)
    end = lba + sectors(length)  # Python integers preserve the 33rd bit.
    if end > total:
        raise PackError("resource range exceeds total sectors / 32-bit address space")
    return end


def read_json(path: Path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise PackError("duplicate JSON key: " + key)
            result[key] = value
        return result
    def finite(value):
        raise PackError("nonstandard JSON numeric constant: " + value)
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=unique,
                          parse_constant=finite)
    except (OSError, ValueError) as exc:
        raise PackError(f"cannot read JSON {path}: {exc}") from exc


def keys(item, allowed: set[str], required: set[str], label: str) -> None:
    if not isinstance(item, dict) or set(item) - allowed or required - set(item):
        raise PackError(label + ": missing/unknown fields")


def compact_font(glyph_map: Path):
    read_json(glyph_map)  # Reject duplicate keys and nonstandard numbers too.
    font = load_font_map(glyph_map)
    if ((font.font_set_id, font.glyph_count, font.capacity) != (FONT_ID, GLYPHS, 192)
            or font.release_sha256 is None
            or font.release_sha256.lower() != FONT_RELEASE_SHA256):
        raise PackError("requires exact compact font release 0xCBE17BCF / 175 glyphs / 192 slots")
    return font


def load_config(config: Path, glyph_map: Path):
    font = compact_font(glyph_map)
    raw = read_json(config)
    keys(raw, {"schema", "font_set_id", "glyph_count", "themes"},
         {"schema", "font_set_id", "glyph_count", "themes"}, "config")
    if (raw["schema"] != "ICHSHOW3_CONFIG_V1" or raw["font_set_id"] != "0xCBE17BCF"
            or type(raw["glyph_count"]) is not int or raw["glyph_count"] != GLYPHS):
        raise PackError("config schema/font version mismatch")
    if not isinstance(raw["themes"], list) or len(raw["themes"]) != 4:
        raise PackError("exactly four themes required")
    resources, dwell = [], []
    inputs = {config.resolve(), glyph_map.resolve(), glyph_map.with_name("font_rom.bin").resolve(),
              glyph_map.with_name("manifest.json").resolve()}

    def media(value, label):
        if not isinstance(value, str) or not value.strip():
            raise PackError(label + ": media path required")
        path = (config.parent / value).resolve()
        inputs.add(path)
        try:
            return path, path.read_bytes()
        except OSError as exc:
            raise PackError(f"{label}: cannot read {path}: {exc}") from exc

    for theme_id, item in enumerate(raw["themes"]):
        allowed = {"theme_id", "name", "audio", "text", "text_file", "image_dwell_ms", "images"}
        keys(item, allowed, {"theme_id", "name", "audio", "image_dwell_ms", "images"}, "theme")
        if u32(item["theme_id"], "theme_id") != theme_id or item["name"] != NAMES[theme_id]:
            raise PackError("theme name/order/ID mismatch")
        dwell.append(u32(item["image_dwell_ms"], "image_dwell_ms", 1))
        images = item["images"]
        if not isinstance(images, list) or len(images) != 4:
            raise PackError(f"theme {theme_id}: exactly four images required")
        for image_index, image in enumerate(images):
            keys(image, {"image_index", "image"}, {"image_index", "image"}, "image")
            if u32(image["image_index"], "image_index") != image_index:
                raise PackError("image_index must be ordered 0..3, no duplicates")
            path, data = media(image["image"], "BMP")
            validate_bmp_bytes(data, str(path))
            resources.append(dict(theme_id=theme_id, image_index=image_index, kind="image",
                                  resource_id=theme_id * 4 + image_index, source_path=str(path), data=data))
        path, data = media(item["audio"], "WAV")
        validate_wav_bytes(data, str(path))
        resources.append(dict(theme_id=theme_id, image_index=None, kind="audio",
                              resource_id=0x40 + theme_id, source_path=str(path), data=data))
        if ("text" in item) == ("text_file" in item):
            raise PackError("use exactly one of text/text_file")
        if "text_file" in item:
            path, data = media(item["text_file"], "subtitle source")
            try:
                text = data.decode("utf-8-sig")
            except UnicodeError as exc:
                raise PackError("subtitle source must be UTF-8") from exc
            source_path = str(path)
        else:
            text, source_path = item["text"], None
        data = make_text_resource(text, font, f"theme {theme_id}")
        resources.append(dict(theme_id=theme_id, image_index=None, kind="text",
                              resource_id=0x80 + theme_id, source_path=source_path, data=data))
    return resources, dwell, inputs


def zero_range(raw, start: int, end: int) -> bool:
    """Scan padding without allocating a potentially huge gap/tail copy."""
    return all(not any(raw[position:min(position + 65536, end)])
               for position in range(start, end, 65536))


def same_value(wanted, actual) -> bool:
    # Python normally equates False with 0, True with 1, and 3.0 with 3.
    return type(wanted) is type(actual) and wanted == actual


def inspect_image(path: Path, report: Path | None = None, glyph_map: Path | None = None) -> dict:
    with path.open("rb") as handle:
        if handle.seek(0, 2) < (PAYLOAD_LBA + 1) * SECTOR:
            raise PackError("image size is truncated or not sector aligned")
        with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as raw:
            return inspect_mapped(raw, report, glyph_map)


def inspect_mapped(raw, report=None, glyph_map=None) -> dict:
    """Verify one mapped file, keeping the same view alive during extraction."""
    if len(raw) < (PAYLOAD_LBA + 1) * SECTOR or len(raw) % SECTOR:
        raise PackError("image size is truncated or not sector aligned")
    head = HEADER.unpack_from(raw)
    if head[:11] != HEADER_FIXED:
        raise PackError("ICHSHOW3 version/fixed header mismatch; v2 is not accepted")
    total, crc, font_id, glyph_count = head[11:]
    if total * SECTOR != len(raw):
        raise PackError("total sectors differs from file length")
    if (font_id, glyph_count) != (FONT_ID, GLYPHS):
        raise PackError("image requires compact font 0xCBE17BCF / 175 glyphs")
    if (not zero_range(raw, 64, 512) or not zero_range(raw, 640, 1024)
            or not zero_range(raw, 1536, PAYLOAD_LBA * SECTOR)):
        raise PackError("nonzero header/directory/reserved padding")
    if zlib.crc32(raw[512:1536]) & 0xFFFFFFFF != crc:
        raise PackError("directory CRC mismatch")
    font = compact_font(glyph_map) if glyph_map else None
    by_id, themes, ordered_ranges = {}, [], []

    def resource(rid, theme_id, image_index, kind, lba, length):
        end = check_range(lba, length, total)
        if any(lba < previous_end and previous_start < end
               for previous_start, previous_end, _ in ordered_ranges):
            raise PackError("resource ranges overlap")
        if kind == "text" and (not 24 <= length <= 152 or length % 2):
            raise PackError("subtitle length outside 24..152")
        data = raw[lba * SECTOR:lba * SECTOR + length]
        if not zero_range(raw, lba * SECTOR + length, end * SECTOR):
            raise PackError("nonzero resource tail padding")
        label = f"resource 0x{rid:02X}"
        if kind == "image":
            validate_bmp_bytes(data, label)
        elif kind == "audio":
            validate_wav_bytes(data, label)
        else:
            tokens = validate_text_bytes(data, FONT_ID, GLYPHS, label)
        info = dict(resource_id=rid, theme_id=theme_id, image_index=image_index,
                    kind=kind, lba=lba, bytes=length, sha256=digest(data))
        if kind == "text":
            info["token_count"] = len(tokens)
            if font:
                reverse = {value: key for key, value in font.char_to_id.items()}
                decoded = "".join(reverse[token] for token in tokens)
                info["decoded_rows"] = [decoded[i:i + 16] for i in range(0, len(tokens), 16)]
        by_id[rid] = info
        ordered_ranges.append((lba, end, rid))
        return info

    for theme_id in range(4):
        values = THEME.unpack_from(raw, 512 + theme_id * 32)
        ident, flags, count, reserved, first, audio_lba, audio_bytes, text_lba, text_bytes, dwell, tail = values
        if (ident, flags, count, reserved, first, tail) != (theme_id, 3, 4, 0, theme_id * 4, 0) or not dwell:
            raise PackError("theme record identity/flags/range/reserved field mismatch")
        images = []
        for image_index in range(4):
            values = PICTURE.unpack_from(raw, 1024 + (theme_id * 4 + image_index) * 32)
            ident, index, flags, reserved, lba, length, width, height, override, text_ref, r0, r1 = values
            if (ident, index, flags, reserved, width, height, override, text_ref, r0, r1) != (
                    theme_id, image_index, 1, 0, 640, 480, 0, theme_id, 0, 0):
                raise PackError("image record identity/dimensions/text reference/reserved field mismatch")
            images.append(resource(theme_id * 4 + image_index, theme_id, image_index, "image", lba, length))
        audio = resource(0x40 + theme_id, theme_id, None, "audio", audio_lba, audio_bytes)
        text = resource(0x80 + theme_id, theme_id, None, "text", text_lba, text_bytes)
        themes.append(dict(theme_id=theme_id, name=NAMES[theme_id], image_dwell_ms=dwell,
                           images=images, audio=audio, text=text))
    cursor = PAYLOAD_LBA
    for start, end, rid in sorted(ordered_ranges):
        if start < cursor:
            raise PackError("resource ranges overlap")
        if not zero_range(raw, cursor * SECTOR, start * SECTOR):
            raise PackError("nonzero unallocated payload gap")
        cursor = end
    if not zero_range(raw, cursor * SECTOR, len(raw)):
        raise PackError("nonzero unallocated image tail")
    result = dict(schema="ICHSHOW3_MANIFEST_V1", version=3, contract="C-v0.1-draft",
                  image_sha256=digest(raw), image_total_sectors=total,
                  directory_crc32=f"0x{crc:08X}", font_set_id="0xCBE17BCF", glyph_count=175,
                  theme_count=4, picture_count=16, resource_count=24, themes=themes,
                  resources=sorted(by_id.values(), key=lambda item: item["resource_id"]))
    if report:
        expected = read_json(report)
        if not isinstance(expected, dict):
            raise PackError("manifest must be a JSON object")
        for field in ("schema", "version", "contract", "image_sha256", "font_set_id", "glyph_count",
                      "theme_count", "picture_count", "resource_count", "image_total_sectors",
                      "directory_crc32"):
            if not same_value(expected.get(field), result[field]):
                raise PackError("manifest mismatch: " + field)
        records = expected.get("resources")
        if not isinstance(records, list) or len(records) != 24:
            raise PackError("manifest requires exactly 24 resources")
        for record, actual in zip(records, result["resources"]):
            if not isinstance(record, dict) or any(key not in record or not same_value(record[key], actual[key]) for key in (
                    "resource_id", "theme_id", "image_index", "kind", "lba", "bytes", "sha256")):
                raise PackError("manifest resource mismatch")
            if "token_count" in record and not same_value(record["token_count"], actual.get("token_count")):
                raise PackError("manifest subtitle token count mismatch")
        expected_themes = expected.get("themes")
        if not isinstance(expected_themes, list) or len(expected_themes) != 4:
            raise PackError("manifest requires four themes")
        for wanted, actual in zip(expected_themes, result["themes"]):
            if not isinstance(wanted, dict) or any(not same_value(wanted.get(key), actual[key]) for key in (
                    "theme_id", "name", "image_dwell_ms")):
                raise PackError("manifest theme mismatch")
            for key in ("images", "audio", "text"):
                left = wanted.get(key)
                right = actual[key]
                if key == "images":
                    if not isinstance(left, list) or len(left) != 4:
                        raise PackError("manifest theme images mismatch")
                    pairs = zip(left, right)
                else:
                    pairs = [(left, right)]
                for value, correct in pairs:
                    if not isinstance(value, dict) or any(k not in value or not same_value(value[k], correct[k]) for k in (
                            "resource_id", "theme_id", "image_index", "kind", "lba", "bytes", "sha256")):
                        raise PackError("manifest theme association mismatch")
                    if "token_count" in value and not same_value(value["token_count"], correct.get("token_count")):
                        raise PackError("manifest subtitle token count mismatch")
    return result


def write_new(path: Path, data: bytes) -> None:
    write_parts(path, (data,))


def write_parts(path: Path, parts) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    created = False
    try:
        with path.open("xb") as handle:
            created = True
            for data in parts:
                if handle.write(data) != len(data):
                    raise OSError("short write: " + str(path))
    except BaseException:
        if created:
            path.unlink()
        raise


def extract(path: Path, directory: Path, report=None, glyph_map=None) -> dict:
    if directory.exists():
        raise PackError("extraction requires a new directory")
    with path.open("rb") as handle:
        if handle.seek(0, 2) < (PAYLOAD_LBA + 1) * SECTOR:
            raise PackError("image size is truncated or not sector aligned")
        with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as raw:
            result = inspect_mapped(raw, report, glyph_map)
            directory.mkdir(parents=True)  # Exclusive directory creation.
            created = []
            try:
                for item in result["resources"]:
                    suffix = {"image": "bmp", "audio": "wav", "text": "ichtxt"}[item["kind"]]
                    name = f"theme_{item['theme_id']:02d}"
                    if item["image_index"] is not None:
                        name += f"_image_{item['image_index']:02d}"
                    else:
                        name += "_" + item["kind"]
                    data = raw[item["lba"] * SECTOR:item["lba"] * SECTOR + item["bytes"]]
                    if digest(data) != item["sha256"]:
                        raise PackError("image changed during extraction")
                    target = directory / (name + "." + suffix)
                    write_new(target, data)
                    created.append(target)
                if digest(raw) != result["image_sha256"]:
                    raise PackError("image changed during extraction")
                target = directory / "readback.json"
                write_new(target, json_bytes(result))
                created.append(target)
                return result
            except BaseException:
                # Delete only this invocation's files; never recursively delete.
                for target in reversed(created):
                    target.unlink(missing_ok=True)
                try:
                    directory.rmdir()
                except OSError:
                    pass  # Preserve any unrelated file placed here concurrently.
                raise


def json_bytes(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def build(config: Path, glyph_map: Path, output: Path, report: Path) -> dict:
    config_hash, map_hash = digest(config.read_bytes()), digest(glyph_map.read_bytes())
    resources, dwell, inputs = load_config(config.resolve(), glyph_map.resolve())
    if digest(config.read_bytes()) != config_hash or digest(glyph_map.read_bytes()) != map_hash:
        raise PackError("config/font mapping changed while loading inputs")
    output, report = output.resolve(), report.resolve()
    if output == report or output in inputs or report in inputs or output.exists() or report.exists():
        raise PackError("output/report must be distinct new files, never input paths")
    tables = bytearray(1024)
    lba = PAYLOAD_LBA
    for item in resources:
        item["lba"], item["bytes"] = lba, u32(len(item["data"]), "resource bytes", 1)
        lba += sectors(item["bytes"])
        u32(lba, "total sectors", PAYLOAD_LBA + 1)
    by_id = {item["resource_id"]: item for item in resources}
    for theme_id in range(4):
        audio, text = by_id[0x40 + theme_id], by_id[0x80 + theme_id]
        THEME.pack_into(tables, theme_id * 32, theme_id, 3, 4, 0, theme_id * 4,
                        audio["lba"], audio["bytes"], text["lba"], text["bytes"], dwell[theme_id], 0)
        for image_index in range(4):
            image = by_id[theme_id * 4 + image_index]
            PICTURE.pack_into(tables, 512 + (theme_id * 4 + image_index) * 32,
                             theme_id, image_index, 1, 0, image["lba"], image["bytes"],
                             640, 480, 0, theme_id, 0, 0)
    raw = bytearray(PAYLOAD_LBA * SECTOR)
    HEADER.pack_into(raw, 0, *HEADER_FIXED, lba, zlib.crc32(tables) & 0xFFFFFFFF, FONT_ID, GLYPHS)
    raw[512:1536] = tables
    def parts():
        yield raw
        for item in resources:
            yield item["data"]
            yield bytes((-item["bytes"]) % SECTOR)
    created = []
    try:
        # Exclusive creation prevents accidental overwrite, including races.
        write_parts(output, parts())
        created.append(output)
        checked = inspect_image(output, glyph_map=glyph_map)
        for item in checked["resources"]:
            source = by_id[item["resource_id"]]
            if item["sha256"] != digest(source["data"]):
                raise PackError("build readback differs from input resource")
            item["source_path"] = source["source_path"]
        checked["tool_sha256"] = digest(Path(__file__).read_bytes())
        checked["config_sha256"] = config_hash
        checked["glyph_map_sha256"] = map_hash
        write_new(report, json_bytes(checked))
        created.append(report)
        inspect_image(output, report, glyph_map)
        return checked
    except BaseException:
        # Only remove files created by this invocation, never a pre-existing input.
        for path in reversed(created):
            path.unlink()
        raise


def resolve_block(checked: dict, client: str, resource_id: int, block_index: int) -> dict:
    u32(resource_id, "resource_id")
    u32(block_index, "block_index")
    if resource_id > 255 or client not in ("img", "aud"):
        raise PackError("illegal client/resource ID")
    item = next((item for item in checked["resources"] if item["resource_id"] == resource_id), None)
    if item is None or (item["kind"] == "audio") != (client == "aud"):
        raise PackError("resource missing or wrong client")
    offset = block_index * SECTOR
    if offset >= item["bytes"]:
        raise PackError("file block out of range")
    physical_lba = item["lba"] + block_index
    if physical_lba >= checked["image_total_sectors"] or physical_lba > 0xFFFFFFFF:
        raise PackError("physical address overflow")
    return dict(lba=physical_lba, valid_bytes=min(SECTOR, item["bytes"] - offset),
                file_last=offset + SECTOR >= item["bytes"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="command", required=True)
    builder = subs.add_parser("build")
    builder.add_argument("config", type=Path)
    builder.add_argument("output", type=Path)
    builder.add_argument("--glyph-map", type=Path, required=True)
    builder.add_argument("--report", type=Path)
    verifier = subs.add_parser("verify")
    verifier.add_argument("image", type=Path)
    verifier.add_argument("--report", type=Path)
    verifier.add_argument("--glyph-map", type=Path)
    verifier.add_argument("--extract-dir", type=Path)
    verifier.add_argument("--verification-json", type=Path,
                          help="write full readback results to a NEW JSON file")
    args = parser.parse_args()
    try:
        if args.command == "build":
            result = build(args.config, args.glyph_map, args.output,
                           args.report or args.output.with_suffix(".manifest.json"))
        else:
            if args.verification_json and args.verification_json.exists():
                raise PackError("verification JSON must be a new file")
            if args.extract_dir:
                result = extract(args.image, args.extract_dir, args.report, args.glyph_map)
            else:
                result = inspect_image(args.image, args.report, args.glyph_map)
            if args.verification_json:
                write_new(args.verification_json, json_bytes(result))
    except (OSError, ValueError) as exc:
        print("FAIL: " + str(exc), file=sys.stderr)
        return 1
    print("PASS: ICHSHOW3 draft, 4 themes / 16 images / 4 audio / 4 text")
    if args.command == "verify" and args.report is None:
        print("NOTICE: structure only; no manifest reference for original BMP/WAV content")
    print("Image SHA256: " + result["image_sha256"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
