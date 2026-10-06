#!/usr/bin/env python3
"""Generates Sources/ImageCratWinSupport/EmbeddedSamples.swift: a tiny PSD, a 16-bit grayscale PSD and a PNG, written
here with Python's standard library only (independent of the Swift writers), plus the pixel values the Windows
self-check expects after decoding them. Run from the repository root: python3 scripts/gen_selfcheck_samples.py"""
import struct, zlib, os

def packbits(row):
    out = bytearray(); i = 0; n = len(row)
    while i < n:
        run = 1
        while i + run < n and run < 128 and row[i + run] == row[i]: run += 1
        if run >= 2:
            out += bytes([(257 - run) & 0xFF, row[i]]); i += run; continue
        start = i; lit = 0
        while i < n and lit < 128:
            if i + 1 < n and row[i] == row[i + 1]: break
            i += 1; lit += 1
        out += bytes([lit - 1]) + bytes(row[start:start + lit])
    return bytes(out)

def pascal(s, pad):
    b = s.encode('utf-8')[:255]; out = bytes([len(b)]) + b
    while len(out) % pad: out += b'\0'
    return out

def block(key, body):
    if len(body) % 2: body += b'\0'
    return b'8BIM' + key + struct.pack('>I', len(body)) + body

def unicode_name(s):
    u = s.encode('utf-16-be'); return struct.pack('>I', len(u) // 2) + u

W, H = 24, 16
def bg(x, y): return (x * 10, y * 15, 128, 255)
BOX = (4, 4, 8, 6)          # x, y, w, h
BOX_OPACITY = 128
def box_px(x, y): return (255, 0, 0, 255)

def composite(x, y):
    r, g, b, _ = bg(x, y)
    bx, by, bw, bh = BOX
    if bx <= x < bx + bw and by <= y < by + bh:
        a = BOX_OPACITY
        r = (255 * a + r * (255 - a) + 127) // 255
        g = (0 * a + g * (255 - a) + 127) // 255
        b = (0 * a + b * (255 - a) + 127) // 255
    return (r, g, b, 255)

def channel_rle(plane, w, h):
    rows = [packbits(plane[y * w:(y + 1) * w]) for y in range(h)]
    return struct.pack('>H', 1) + b''.join(struct.pack('>H', len(r)) for r in rows) + b''.join(rows)

def layer(name, rect, px, opacity=255, extra=b'', flags=0x08, chans=True, blend=b'norm'):
    x, y, w, h = rect
    data = []
    for cid, k in ((0, 0), (1, 1), (2, 2), (-1, 3)):
        plane = bytes(px[i * 4 + k] for i in range(w * h)) if chans else b''
        data.append((cid, channel_rle(plane, w, h) if w * h else struct.pack('>H', 0)))
    rec = struct.pack('>iiii', y, x, y + h, x + w) + struct.pack('>H', len(data))
    for cid, d in data: rec += struct.pack('>hI', cid, len(d))
    rec += b'8BIM' + blend + bytes([opacity, 0, flags, 0])
    ex = struct.pack('>I', 0) + struct.pack('>I', 0) + pascal(name, 4) + block(b'luni', unicode_name(name)) + extra
    rec += struct.pack('>I', len(ex)) + ex
    return rec, b''.join(d for _, d in data)

def rgba(w, h, f):
    out = bytearray()
    for yy in range(h):
        for xx in range(w): out += bytes(f(xx, yy))
    return bytes(out)

def psd_rgb():
    recs = []
    # file order: bottom first
    recs.append(layer('Background', (0, 0, W, H), rgba(W, H, bg)))
    recs.append(layer('</Layer group>', (0, 0, 0, 0), b'', extra=block(b'lsct', struct.pack('>I', 3)), flags=0x18))
    bx, by, bw, bh = BOX
    recs.append(layer('Red box', BOX, rgba(bw, bh, box_px), opacity=BOX_OPACITY))
    recs.append(layer('Shapes', (0, 0, 0, 0), b'', extra=block(b'lsct', struct.pack('>I', 1) + b'8BIMpass'), flags=0x18, blend=b'pass'))
    li = struct.pack('>h', len(recs)) + b''.join(r for r, _ in recs) + b''.join(d for _, d in recs)
    if len(li) % 2: li += b'\0'
    lmi = struct.pack('>I', len(li)) + li + struct.pack('>I', 0)
    res = b'8BIM' + struct.pack('>H', 1005) + b'\0\0' + struct.pack('>I', 16) + struct.pack('>IHHIHH', 150 << 16, 1, 2, 150 << 16, 1, 2)
    out = b'8BPS' + struct.pack('>H', 1) + b'\0' * 6 + struct.pack('>HIIHH', 3, H, W, 8, 3)
    out += struct.pack('>I', 0) + struct.pack('>I', len(res)) + res + struct.pack('>I', len(lmi)) + lmi
    comp = rgba(W, H, composite)
    rows = []
    for k in range(3):
        plane = bytes(comp[i * 4 + k] for i in range(W * H))
        rows += [packbits(plane[y * W:(y + 1) * W]) for y in range(H)]
    out += struct.pack('>H', 1) + b''.join(struct.pack('>H', len(r)) for r in rows) + b''.join(rows)
    return out

def psd_gray16():
    w, h = 8, 8
    out = b'8BPS' + struct.pack('>H', 1) + b'\0' * 6 + struct.pack('>HIIHH', 1, h, w, 16, 1)
    out += struct.pack('>I', 0) + struct.pack('>I', 0) + struct.pack('>I', 0)
    out += struct.pack('>H', 0)
    for y in range(h):
        for x in range(w): out += struct.pack('>H', (x * 8 + y) * 1000)
    return out

def png():
    w, h = 6, 4
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type: none
        for x in range(w): raw += bytes((x * 40, y * 60, 200, 255 if x < 3 else 100))
    def chunk(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')

def swift_bytes(name, b):
    lines = []
    for i in range(0, len(b), 24):
        lines.append('        ' + ', '.join('0x%02X' % v for v in b[i:i + 24]) + ',')
    return '    static let %s: [UInt8] = [\n%s\n    ]\n' % (name, '\n'.join(lines))

p1, p2, p3 = psd_rgb(), psd_gray16(), png()
c = composite(6, 5); c2 = composite(0, 0); c3 = composite(23, 15)
src = '''// GENERATED by scripts/gen_selfcheck_samples.py (Python standard library only). Do not edit.
// Small files decoded by the Windows self-check: they were written without the Swift writers, so decoding them
// checks the readers against an independent implementation.

enum EmbeddedSamples {
    /// 24×16 RGB, 8-bit, RLE: "Background" (gradient r = 10x, g = 15y, b = 128), group "Shapes" (pass through) holding
    /// "Red box" (255,0,0 at 4,4 size 8×6, opacity 128); 150 ppi; composite RLE without transparency.
%s
    /// Composite pixels the decoder must produce: (x, y, r, g, b, a).
    static let rgbExpected: [(Int, Int, UInt8, UInt8, UInt8, UInt8)] = [(6, 5, %d, %d, %d, %d), (0, 0, %d, %d, %d, %d), (23, 15, %d, %d, %d, %d)]

    /// 8×8 grayscale, 16-bit, raw: sample (x, y) = (8x + y) × 1000.
%s
    /// 6×4 RGBA PNG: (x, y) = (40x, 60y, 200, x < 3 ? 255 : 100).
%s}
''' % (swift_bytes('psdRGB', p1), *c, *c2, *c3, swift_bytes('psdGray16', p2), swift_bytes('png', p3))
path = os.path.join('Sources', 'ImageCratWinSupport', 'EmbeddedSamples.swift')
open(path, 'w').write(src)
print('wrote', path, len(p1), len(p2), len(p3))
