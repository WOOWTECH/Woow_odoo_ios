#!/usr/bin/env python3
"""Offline, stdlib-only RGBA PNG → Apporo brand assets: the opaque white app icon (unchanged) and
the login logo as a round badge (owner 2026-10-08: "Logo都要是圓型外框"), one image for both
appearances like WoowLogo. The badge replaces the I16 transparent light-mark dark variant."""
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

    return encode_png(width, height, 2, pixels)


# Round login badge — shared spec with the Android port; keep both in step.
BADGE_SIDE = 1024
BADGE_FILL_RGB = (0xFF, 0xFF, 0xFF)
BADGE_RING_RGB = (0xD9, 0xD9, 0xD9)
BADGE_RING_FRACTION = 0.03   # inner-edge ring width / side
BADGE_MARK_FRACTION = 0.60   # scaled source canvas / side, centred
BADGE_SUPERSAMPLE = 4        # 4×4 samples per pixel on the anti-aliased edges


def white_composite(rows):
    """RGBA rows → flat RGB bytearray composited over #FFFFFF (no dark alpha fringes)."""
    out = bytearray()
    for row in rows:
        for offset in range(0, len(row), 4):
            r, g, b, a = row[offset:offset + 4]
            out.extend((c * a + 255 * (255 - a) + 127) // 255 for c in (r, g, b))
    return out


def bilinear_axis(dst, src):
    """Per destination index: (i0, i1, weight of i1), pixel-centre aligned, edge-clamped."""
    taps = []
    for i in range(dst):
        pos = min(max((i + 0.5) * src / dst - 0.5, 0.0), src - 1.0)
        i0 = int(pos)
        taps.append((i0, min(i0 + 1, src - 1), pos - i0))
    return taps


def circle_badge_png(data, side=BADGE_SIDE):
    """White disc (diameter = side) with a #D9D9D9 inner-edge ring (3 % of side) and the white-
    composited source mark scaled bilinearly to 60 % of side, centred, uncropped and not recoloured.
    Outside the disc alpha is 0; disc and ring edges are anti-aliased by 4×4 supersampling."""
    width, height, channels, rows = read_png(data)
    if (width, height, channels) != (1024, 1024, 4):
        raise ValueError("Expected the approved 1024×1024 RGBA mark")
    src = white_composite(rows)
    mark = round(side * BADGE_MARK_FRACTION)
    origin = (side - mark) // 2
    xs, ys = bilinear_axis(mark, width), bilinear_axis(mark, height)

    def inner(x, y):
        mx, my = x - origin, y - origin
        if not (0 <= mx < mark and 0 <= my < mark):
            return BADGE_FILL_RGB
        x0, x1, fx = xs[mx]
        y0, y1, fy = ys[my]
        p00, p01, p10, p11 = ((yy * width + xx) * 3 for yy, xx in ((y0, x0), (y0, x1), (y1, x0), (y1, x1)))
        return tuple(round((src[p00 + c] * (1 - fx) + src[p01 + c] * fx) * (1 - fy)
                           + (src[p10 + c] * (1 - fx) + src[p11 + c] * fx) * fy) for c in range(3))

    centre = side / 2
    outer_r = side / 2
    inner_r = outer_r - side * BADGE_RING_FRACTION
    margin = 0.75  # > half a pixel diagonal: beyond it a pixel is wholly on one side of an edge
    n = BADGE_SUPERSAMPLE
    subs = [(i + 0.5) / n for i in range(n)]
    pixels = bytearray()
    for y in range(side):
        pixels.append(0)
        for x in range(side):
            d = ((x + 0.5 - centre) ** 2 + (y + 0.5 - centre) ** 2) ** 0.5
            if d - margin >= outer_r:
                pixels.extend((0, 0, 0, 0))
            elif d + margin <= inner_r:
                pixels.extend((*inner(x, y), 255))
            elif inner_r + margin <= d <= outer_r - margin:
                pixels.extend((*BADGE_RING_RGB, 255))
            else:
                ring = fill = 0
                for sy in subs:
                    for sx in subs:
                        ds = ((x + sx - centre) ** 2 + (y + sy - centre) ** 2) ** 0.5
                        if ds < inner_r:
                            fill += 1
                        elif ds < outer_r:
                            ring += 1
                covered = ring + fill
                if not covered:
                    pixels.extend((0, 0, 0, 0))
                    continue
                body = inner(x, y)
                rgb = ((ring * BADGE_RING_RGB[c] + fill * body[c] + covered // 2) // covered for c in range(3))
                pixels.extend((*rgb, (covered * 255 + n * n // 2) // (n * n)))
    return encode_png(side, side, 6, pixels)


def encode_png(width, height, color_type, filtered_rows):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(filtered_rows, 9)) + chunk(b"IEND", b"")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    source = args.source.read_bytes()
    icon = opaque_white_png(source)
    badge = circle_badge_png(source)
    outputs = []
    for asset, filename, image, output, operation in [
        ("ApporoAppIcon.appiconset", "ApporoAppIcon.png", {"idiom": "universal", "platform": "ios", "size": "1024x1024"}, icon,
         "RGBA alpha-composite over #FFFFFF; RGB opaque PNG; no resizing or cropping"),
        ("ApporoLogo.imageset", "ApporoLogo.png", {"idiom": "universal"}, badge,
         "round badge, one image for light and dark: RGBA PNG; disc diameter = side, fill #%s, alpha 0 outside; "
         "inner-edge ring %g%% of side, #%s; source alpha-composited over #FFFFFF then bilinearly scaled to %g%% of side, "
         "centred, not cropped or recoloured; disc/ring edges anti-aliased with %d×%d supersampling" % (
             bytes(BADGE_FILL_RGB).hex().upper(), BADGE_RING_FRACTION * 100, bytes(BADGE_RING_RGB).hex().upper(),
             BADGE_MARK_FRACTION * 100, BADGE_SUPERSAMPLE, BADGE_SUPERSAMPLE)),
    ]:
        folder = ROOT / "odoo/Assets.xcassets" / asset
        folder.mkdir(parents=True, exist_ok=True)
        folder.joinpath(filename).write_bytes(output)
        folder.joinpath("Contents.json").write_text(json.dumps({"images": [dict(image, filename=filename)], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
        outputs.append({"path": str((folder / filename).relative_to(ROOT)), "width": 1024, "height": 1024, "operation": operation, "sha256": hashlib.sha256(output).hexdigest()})
    # The I16 dark variant (transparent, #E6E6E6 mark) is superseded by the badge; drop a stale copy.
    ROOT.joinpath("odoo/Assets.xcassets/ApporoLogo.imageset/ApporoLogo-dark.png").unlink(missing_ok=True)
    manifest = {"source": str(args.source), "source_sha256": hashlib.sha256(source).hexdigest(), "outputs": outputs}
    (ROOT / "BrandResources/asset-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
