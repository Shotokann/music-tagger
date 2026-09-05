"""Small generated audio containers for mutation tests."""

import struct

from mutagen.id3 import ID3
from mutagen.mp4 import MP4

from pipeline.utils.tag_io import write_tags


def make_mp3(path, **tags):
    # MPEG-1 Layer III, 32 kbps, 44.1 kHz. Mutagen requires a second sync
    # header to validate the first 104-byte frame, so include two tiny frames.
    frame = bytes.fromhex("FFFB1000") + bytes(100)
    path.write_bytes(frame * 2)
    ID3().save(path, v2_version=4)
    if tags:
        write_tags(str(path), tags)
    return path


def _box(kind: bytes, payload: bytes = b"") -> bytes:
    return struct.pack(">I4s", len(payload) + 8, kind) + payload


def _full_box(kind: bytes, payload: bytes = b"", flags: int = 0) -> bytes:
    return _box(kind, struct.pack(">I", flags) + payload)


def make_m4a(path, **tags):
    """Build a tiny parseable MP4 audio container without external encoders."""
    ftyp = _box(b"ftyp", b"M4A \x00\x00\x02\x00M4A isomiso2")
    mvhd = _full_box(
        b"mvhd",
        struct.pack(">IIII", 0, 0, 1000, 0)
        + struct.pack(">I", 0x00010000)
        + struct.pack(">H", 0x0100)
        + bytes(10)
        + struct.pack(">9I", 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000)
        + bytes(24)
        + struct.pack(">I", 2),
    )
    tkhd = _full_box(
        b"tkhd",
        struct.pack(">IIIII", 0, 0, 1, 0, 0)
        + bytes(8)
        + struct.pack(">HHHH", 0, 0, 0x0100, 0)
        + struct.pack(">9I", 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000)
        + bytes(8),
        flags=3,
    )
    mdhd = _full_box(b"mdhd", struct.pack(">IIIIHH", 0, 0, 44100, 0, 0, 0))
    hdlr = _full_box(b"hdlr", bytes(4) + b"soun" + bytes(12) + b"SoundHandler\x00")
    smhd = _full_box(b"smhd", bytes(4))
    url = _full_box(b"url ", flags=1)
    dref = _full_box(b"dref", struct.pack(">I", 1) + url)
    dinf = _box(b"dinf", dref)
    esds = _full_box(b"esds", bytes.fromhex("031900010004114015000000000000000000000005021210060102"))
    mp4a = _box(
        b"mp4a",
        bytes(6)
        + struct.pack(">H", 1)
        + bytes(8)
        + struct.pack(">HHHHI", 2, 16, 0, 0, 44100 << 16)
        + esds,
    )
    stsd = _full_box(b"stsd", struct.pack(">I", 1) + mp4a)
    empty_table = struct.pack(">I", 0)
    stbl = _box(
        b"stbl",
        stsd
        + _full_box(b"stts", empty_table)
        + _full_box(b"stsc", empty_table)
        + _full_box(b"stsz", bytes(4) + empty_table)
        + _full_box(b"stco", empty_table),
    )
    minf = _box(b"minf", smhd + dinf + stbl)
    mdia = _box(b"mdia", mdhd + hdlr + minf)
    trak = _box(b"trak", tkhd + mdia)
    moov = _box(b"moov", mvhd + trak)
    path.write_bytes(ftyp + moov + _box(b"free", bytes(32)) + _box(b"mdat"))

    # Exercise mutagen's implicit filename save path as part of the fixture contract.
    mp4 = MP4(path)
    mp4.add_tags()
    mp4.save()
    if tags:
        write_tags(str(path), tags)
    return path
