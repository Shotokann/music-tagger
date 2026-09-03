"""
Unified tag read/write for MP3, M4A, WAV via mutagen.
"""

import os
from mutagen import File as MutagenFile
from mutagen.id3 import ID3, ID3NoHeaderError, TIT2, TPE1, TPE2, TALB, TRCK, TDRC, TPOS
from mutagen.mp4 import MP4


# ID3 tag key -> friendly name mapping
ID3_KEYS = {
    "TIT2": "title",
    "TPE1": "artist",
    "TPE2": "album_artist",
    "TALB": "album",
    "TRCK": "track",
    "TDRC": "year",
    "TPOS": "disc",
}

# MP4 atom -> friendly name mapping
MP4_KEYS = {
    "\xa9nam": "title",
    "\xa9ART": "artist",
    "aART": "album_artist",
    "\xa9alb": "album",
    "trkn": "track",
    "\xa9day": "year",
    "disk": "disc",
}


def read_tags(filepath: str) -> dict:
    """
    Read tags from any supported audio file.
    Returns dict with friendly keys: title, artist, album_artist, album, track, year, disc.
    Also includes 'has_apic' (bool) for MP3 album art presence, and 'raw' with raw tag data.
    """
    ext = os.path.splitext(filepath)[1].lower()
    result = {
        "title": "",
        "artist": "",
        "album_artist": "",
        "album": "",
        "track": "",
        "year": "",
        "disc": "",
        "has_apic": False,
        "format": ext,
        "raw": {},
    }

    try:
        if ext == ".mp3":
            try:
                tags = ID3(filepath)
            except ID3NoHeaderError:
                return result

            for frame_id, friendly in ID3_KEYS.items():
                frame = tags.get(frame_id)
                if frame:
                    result[friendly] = str(frame).strip()
                    result["raw"][frame_id] = str(frame).strip()

            # Check for album art
            result["has_apic"] = any(k.startswith("APIC") for k in tags.keys())

            # Capture any other text frames
            for key in tags.keys():
                if key not in result["raw"]:
                    try:
                        result["raw"][key] = str(tags[key]).strip()
                    except Exception:
                        pass

        elif ext in (".m4a", ".m4p"):
            try:
                tags = MP4(filepath)
            except Exception:
                return result

            for atom, friendly in MP4_KEYS.items():
                val = tags.tags.get(atom) if tags.tags else None
                if val:
                    if atom in ("trkn", "disk") and isinstance(val, list) and val:
                        # tuple format: [(track, total)]
                        result[friendly] = str(val[0][0]) if isinstance(val[0], tuple) else str(val[0])
                        result["raw"][atom] = str(val)
                    else:
                        result[friendly] = str(val[0]) if isinstance(val, list) and val else str(val)
                        result["raw"][atom] = result[friendly]

            result["has_apic"] = bool(tags.tags and tags.tags.get("covr"))

        elif ext == ".wav":
            mf = MutagenFile(filepath)
            if mf and mf.tags:
                for key in mf.tags.keys():
                    result["raw"][key] = str(mf.tags[key])

        elif ext == ".flac":
            mf = MutagenFile(filepath)
            if mf and mf.tags:
                tag_map = {
                    "title": "title", "artist": "artist",
                    "albumartist": "album_artist", "album": "album",
                    "tracknumber": "track", "date": "year",
                    "discnumber": "disc",
                }
                for vorbis_key, friendly in tag_map.items():
                    vals = mf.tags.get(vorbis_key)
                    if vals:
                        result[friendly] = vals[0]
                        result["raw"][vorbis_key] = vals[0]

    except Exception as e:
        result["error"] = str(e)

    return result


def write_mp3_tags(filepath: str, tags: dict) -> None:
    """
    Write tags to an MP3 file (ID3v2.4, UTF-8).
    tags: dict with keys like 'title', 'artist', 'album', 'year', 'track', 'disc', 'album_artist'.
    Only writes keys that are present in the dict. Does NOT remove other existing tags.
    """
    try:
        id3 = ID3(filepath)
    except ID3NoHeaderError:
        id3 = ID3()

    tag_map = {
        "title": lambda v: TIT2(encoding=3, text=v),
        "artist": lambda v: TPE1(encoding=3, text=v),
        "album_artist": lambda v: TPE2(encoding=3, text=v),
        "album": lambda v: TALB(encoding=3, text=v),
        "track": lambda v: TRCK(encoding=3, text=v),
        "year": lambda v: TDRC(encoding=3, text=v),
        "disc": lambda v: TPOS(encoding=3, text=v),
    }

    frame_ids = {
        "title": "TIT2", "artist": "TPE1", "album_artist": "TPE2",
        "album": "TALB", "track": "TRCK", "year": "TDRC", "disc": "TPOS",
    }

    for key, value in tags.items():
        if key in tag_map and value:
            frame_id = frame_ids[key]
            id3.delall(frame_id)
            id3.add(tag_map[key](value))

    id3.save(filepath, v2_version=4)


def write_m4a_tags(filepath: str, tags: dict) -> None:
    """Write tags to an M4A file."""
    mp4 = MP4(filepath)
    if mp4.tags is None:
        mp4.add_tags()

    atom_map = {
        "title": "\xa9nam",
        "artist": "\xa9ART",
        "album_artist": "aART",
        "album": "\xa9alb",
        "year": "\xa9day",
    }

    for key, value in tags.items():
        if key in atom_map and value:
            mp4.tags[atom_map[key]] = [value]
        elif key == "track" and value:
            # Track format: [(track_num, total)]
            parts = value.split("/")
            track_num = int(parts[0])
            total = int(parts[1]) if len(parts) > 1 else 0
            mp4.tags["trkn"] = [(track_num, total)]
        elif key == "disc" and value:
            parts = value.split("/")
            disc_num = int(parts[0])
            total = int(parts[1]) if len(parts) > 1 else 0
            mp4.tags["disk"] = [(disc_num, total)]

    mp4.save()


def write_tags(filepath: str, tags: dict) -> None:
    """Write tags to any supported audio file."""
    ext = os.path.splitext(filepath)[1].lower()
    if ext == ".mp3":
        write_mp3_tags(filepath, tags)
    elif ext == ".m4a":
        write_m4a_tags(filepath, tags)
    # WAV and FLAC: skip tag writing (rename only)
