#!/usr/bin/env python3
"""Verifikasi game.rbxl per DESIGN.md 20.2 (Stage 1 rebuild).
Format terverifikasi dari file hasil Rojo 7.7.1:
- Header 32 byte ("<roblox!" + version + field header).
- Chunk header 16 byte (type[4] + compressedLen + uncompressedLen + reserved).
- Payload chunk terkompresi LZ4 block mentah (bukan zstd — Rojo 7.7.1
  meng-emit LZ4; dibuktikan: lz4.block.decompress sukses untuk semua chunk
  dan source script terbaca di hasil decompress).
- Chunk: INST, PROP, PRNT, END. SSTR TIDAK di-emit Rojo bila tidak ada
  shared string (kontrol: obby-lompatan/game.rbxl hasil Rojo juga 0 SSTR)
  — dilaporkan apa adanya, bukan diklaim ada.
- END chunk: header clen=0/ulen=9, payload 9 byte `</roblox>` sebagai
  trailing bytes di EOF.
- Source script di dalam rbxl COCOK dengan file src/ (byte-per-byte,
  dicari di PROP chunk yang sudah di-decompress).
"""
import glob
import struct
import sys

import lz4.block

path = sys.argv[1] if len(sys.argv) > 1 else "game.rbxl"
data = open(path, "rb").read()
print(f"file: {path}  size: {len(data)} bytes")
assert data[:8] == b"<roblox!", f"bad magic: {data[:8]!r}"
print("magic OK (<roblox!), header 32 byte")
off = 32
chunks = []
while off < len(data):
    assert off + 16 <= len(data), f"truncated chunk header at {off}"
    # Tipe chunk 4 byte; "END" ditulis "END\x00" (3 huruf + NUL).
    ctype = data[off:off + 4].decode("latin1").rstrip("\x00")
    clen, ulen, _reserved = struct.unpack("<III", data[off + 4:off + 16])
    payload = data[off + 16:off + 16 + clen]
    assert len(payload) == clen, f"truncated payload {ctype}"
    if ctype == "END":
        assert clen == 0 and ulen == 9, f"END header aneh: clen={clen} ulen={ulen}"
        trailing = data[off + 16:off + 25]
        assert trailing == b"</roblox>", f"END trailing: {trailing!r}"
        assert off + 25 == len(data), "ada byte setelah </roblox>"
        chunks.append((ctype, clen, ulen, b"</roblox>"))
        print("chunk END: header clen=0 ulen=9, trailing 9 byte </roblox> di EOF OK")
        off += 25
        break
    if clen == ulen:
        raw = payload
    else:
        raw = lz4.block.decompress(payload, uncompressed_size=ulen)
        assert len(raw) == ulen, f"{ctype}: decompressed {len(raw)} != {ulen}"
    chunks.append((ctype, clen, ulen, raw))
    off += 16 + clen

assert off == len(data), f"sisa byte tak terparse: {len(data) - off}"
types = [c[0] for c in chunks]
from collections import Counter
print("jumlah chunk:", dict(Counter(types)))
for need in ("INST", "PROP", "PRNT", "END"):
    print(f"chunk {need}: {'ADA' if need in types else 'HILANG'}")
    assert need in types, f"missing chunk {need}"
print("chunk SSTR:", "ADA" if "SSTR" in types else "TIDAK ADA (Rojo tidak meng-emit SSTR bila tidak ada shared string; kontrol obby-lompatan/game.rbxl juga 0 SSTR)")

prop_blob = b"".join(c[3] for c in chunks if c[0] == "PROP")
missing = []
for src in sorted(glob.glob("src/**/*.luau", recursive=True)):
    content = open(src, "rb").read()
    found = content in prop_blob
    print(f"source cocok: {src} ({len(content)} byte) -> {'YA' if found else 'TIDAK'}")
    if not found:
        missing.append(src)
assert not missing, f"source tidak ditemukan di rbxl: {missing}"
print("VERIFIKASI RBXL: LOLOS (INST/PROP/PRNT/END lengkap, END </roblox> di EOF, semua source src/ cocok byte-per-byte)")
