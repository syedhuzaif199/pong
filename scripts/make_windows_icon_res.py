#!/usr/bin/env python3
"""Build a Win32 .res containing an application icon, without rc.exe/windres.

The output contains RT_ICON resources plus one RT_GROUP_ICON resource and can be
passed directly to Odin's Windows-only -resource:<file.res> flag.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import struct

RT_ICON = 3
RT_GROUP_ICON = 14
LANG_EN_US = 0x0409
MEMORY_FLAGS = 0x1030  # MOVEABLE | PURE | DISCARDABLE, matching normal icon resources


def align4(data: bytearray) -> None:
    while len(data) & 3:
        data.append(0)


def ordinal(value: int) -> bytes:
    if not 0 <= value <= 0xFFFF:
        raise ValueError(f"resource ordinal out of range: {value}")
    return struct.pack("<HH", 0xFFFF, value)


def resource_entry(resource_type: int, resource_id: int, payload: bytes, *, flags: int = MEMORY_FLAGS, language: int = LANG_EN_US) -> bytes:
    # Numeric TYPE + numeric NAME yields the canonical 32-byte Win32 resource header.
    variable = ordinal(resource_type) + ordinal(resource_id)
    while (8 + len(variable)) & 3:
        variable += b"\0\0"
    trailer = struct.pack("<IHHII", 0, flags, language, 0, 0)
    header_size = 8 + len(variable) + len(trailer)
    header = struct.pack("<II", len(payload), header_size) + variable + trailer
    if header_size != 32:
        raise AssertionError(f"unexpected numeric resource header size: {header_size}")
    out = bytearray(header)
    out.extend(payload)
    align4(out)
    return bytes(out)


def null_resource() -> bytes:
    # Microsoft resource files begin with an empty resource definition.
    return resource_entry(0, 0, b"", flags=0, language=0)


def parse_ico(path: Path):
    raw = path.read_bytes()
    if len(raw) < 6:
        raise ValueError("ICO is too small")
    reserved, kind, count = struct.unpack_from("<HHH", raw, 0)
    if reserved != 0 or kind != 1 or count < 1:
        raise ValueError("not a valid icon (.ico) file")
    if len(raw) < 6 + 16 * count:
        raise ValueError("truncated ICO directory")

    entries = []
    for index in range(count):
        off = 6 + index * 16
        width, height, colors, reserved2, planes, bit_count, size, image_offset = struct.unpack_from("<BBBBHHII", raw, off)
        end = image_offset + size
        if image_offset < 6 + 16 * count or end > len(raw):
            raise ValueError(f"ICO image {index} points outside file")
        entries.append({
            "width": width,
            "height": height,
            "colors": colors,
            "reserved": reserved2,
            "planes": planes,
            "bit_count": bit_count,
            "size": size,
            "data": raw[image_offset:end],
        })
    return entries


def make_res(ico: Path, output: Path) -> None:
    entries = parse_ico(ico)
    out = bytearray(null_resource())

    # Each image is an individual RT_ICON resource.
    for resource_id, entry in enumerate(entries, start=1):
        out.extend(resource_entry(RT_ICON, resource_id, entry["data"]))

    # The group directory refers to those RT_ICON ids instead of file offsets.
    group = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
    for resource_id, entry in enumerate(entries, start=1):
        group.extend(struct.pack(
            "<BBBBHHIH",
            entry["width"],
            entry["height"],
            entry["colors"],
            entry["reserved"],
            entry["planes"],
            entry["bit_count"],
            entry["size"],
            resource_id,
        ))
    out.extend(resource_entry(RT_GROUP_ICON, 1, bytes(group)))

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("ico", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()
    make_res(args.ico, args.output)
    print(args.output)


if __name__ == "__main__":
    main()
