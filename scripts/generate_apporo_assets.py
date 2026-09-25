#!/usr/bin/env python3
"""Offline, stdlib-only RGBA PNG → opaque white Apporo mark assets."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]


def read_png(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Not a PNG")
    pos, payload = 8, bytearray()
    while pos < len(data):
        size = struct.unpack(">I", data[pos:pos + 4])[0]
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + size]
        crc = struct.unpack(">I", data[pos + 8 + size:pos + 12 + size])[0]
        if zlib.crc32(kind + body) != crc:
            raise ValueError("PNG CRC mismatch")
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or color not in (2, 6) or compression or filtering or interlace:
                raise ValueError("Only noninterlaced 8-bit RGB/RGBA supported")
        elif kind == b"IDAT":
            payload.extend(body)
        pos += size + 12
    channels = 4 if color == 6 else 3
    raw = zlib.decompress(payload)
    stride = width * channels
    if len(raw) != (stride + 1) * height:
        raise ValueError("Unexpected pixel length")
    previous, rows = bytearray(stride), []
    for y in range(height):
        offset = y * (stride + 1)
        kind = raw[offset]
        row = bytearray(raw[offset + 1:offset + stride + 1])
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            up = previous[x]
            upper_left = previous[x - channels] if x >= channels else 0
            if kind == 0:
                predictor = 0
            elif kind == 1:
                predictor = left
            elif kind == 2:
                predictor = up
            elif kind == 3:
                predictor = (left + up) // 2
            elif kind == 4:
                p = left + up - upper_left
                distances = [abs(p - left), abs(p - up), abs(p - upper_left)]
                predictor = [left, up, upper_left][distances.index(min(distances))]
            else:
                raise ValueError("Invalid PNG filter")
            row[x] = (row[x] + predictor) & 255
        rows.append(bytes(row))
        previous = row
    return width, height, channels, rows


def opaque_white_png(data):
    width, height, channels, rows = read_png(data)
    if (width, height, channels) != (1024, 1024, 4):
        raise ValueError("Expected the approved 1024×1024 RGBA mark")
    pixels = bytearray()
    for row in rows:
        pixels.append(0)
        for offset in range(0, len(row), 4):
            r, g, b, a = row[offset:offset + 4]
            pixels.extend((c * a + 255 * (255 - a) + 127) // 255 for c in (r, g, b))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels, 9)) + chunk(b"IEND", b"")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    source = args.source.read_bytes()
    output = opaque_white_png(source)
    outputs = []
    for asset, filename, image in [
        ("ApporoAppIcon.appiconset", "ApporoAppIcon.png", {"idiom": "universal", "platform": "ios", "size": "1024x1024"}),
        ("ApporoLogo.imageset", "ApporoLogo.png", {"idiom": "universal"}),
    ]:
        folder = ROOT / "odoo/Assets.xcassets" / asset
        folder.mkdir(parents=True, exist_ok=True)
        folder.joinpath(filename).write_bytes(output)
        folder.joinpath("Contents.json").write_text(json.dumps({"images": [dict(image, filename=filename)], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
        outputs.append({"path": str((folder / filename).relative_to(ROOT)), "width": 1024, "height": 1024, "sha256": hashlib.sha256(output).hexdigest()})
    manifest = {"source": str(args.source), "source_sha256": hashlib.sha256(source).hexdigest(), "operation": "RGBA alpha-composite over #FFFFFF; RGB opaque PNG; no resizing or cropping", "outputs": outputs}
    (ROOT / "BrandResources/asset-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
