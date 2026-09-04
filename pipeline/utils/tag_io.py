"""Unified tag access for the audio containers supported by the pipeline."""

import os
import re
from mutagen import File as MutagenFile
from mutagen.id3 import ID3, ID3NoHeaderError, TIT2, TPE1, TPE2, TALB, TRCK, TDRC, TPOS
from mutagen.mp4 import MP4


class TagIOError(Exception):
    """Base class for tag I/O contract failures."""


class UnsupportedFormatError(TagIOError):
    """Raised when a caller requests mutation of an unsupported container."""


class TagValueError(TagIOError):
    """Raised when a track or disc value is not ``N`` or ``N/M``."""


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

_RUN_TEMP_RE = re.compile(
    r"(?P<extension>\.[^.\\/]+)\.\d{8}T\d{6}-[0-9a-f]{8}\.tmp$"
)


def _effective_extension(filepath: str) -> str:
    """Return the container suffix, including a strict Stage 5 temp name."""
    extension = os.path.splitext(filepath)[1].lower()
    if extension != ".tmp":
        return extension
    match = _RUN_TEMP_RE.search(filepath)
    return match.group("extension").lower() if match else extension


def read_tags(filepath: str) -> dict:
    """
    Read tags from any supported audio file.
    Returns dict with friendly keys: title, artist, album_artist, album, track, year, disc.
    Also includes 'has_apic' (bool) for MP3 album art presence, and 'raw' with raw tag data.
    """
    ext = _effective_extension(filepath)
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
            except Exception as error:
                result["error"] = str(error)
                return result

            for atom, friendly in MP4_KEYS.items():
                val = tags.tags.get(atom) if tags.tags else None
                if val:
                    if atom in ("trkn", "disk") and isinstance(val, list) and val:
                        # tuple format: [(track, total)]
                        if isinstance(val[0], tuple):
                            number, total = val[0]
                            result[friendly] = f"{number}/{total}" if total > 0 else str(number)
                        else:
                            result[friendly] = str(val[0])
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


def _apply_mp3(filepath: str, set_values: dict, delete_keys: list[str]) -> None:
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

    for key in delete_keys:
        frame_id = frame_ids.get(key)
        if frame_id:
            id3.delall(frame_id)

    for key, value in set_values.items():
        if key in tag_map and value:
            frame_id = frame_ids[key]
            id3.delall(frame_id)
            id3.add(tag_map[key](value))

    id3.save(filepath, v2_version=4)


def parse_track_value(value: str) -> tuple[int, int]:
    """Parse ``N`` or ``N/M`` for MP4 track and disc atoms."""
    parts = str(value).split("/")
    if len(parts) not in (1, 2) or any(not part.isdigit() for part in parts):
        raise TagValueError(f"Invalid track/disc value: {value!r}")
    number = int(parts[0])
    total = int(parts[1]) if len(parts) == 2 else 0
    if number < 1 or (len(parts) == 2 and total < 1):
        raise TagValueError(f"Invalid track/disc value: {value!r}")
    return number, total


def _apply_m4a(filepath: str, set_values: dict, delete_keys: list[str]) -> None:
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

    key_to_atom = {**atom_map, "track": "trkn", "disc": "disk"}
    for key in delete_keys:
        atom = key_to_atom.get(key)
        if atom and atom in mp4.tags:
            del mp4.tags[atom]

    for key, value in set_values.items():
        if key in atom_map and value:
            mp4.tags[atom_map[key]] = [value]
        elif key == "track" and value:
            track_num, total = parse_track_value(value)
            mp4.tags["trkn"] = [(track_num, total)]
        elif key == "disc" and value:
            disc_num, total = parse_track_value(value)
            mp4.tags["disk"] = [(disc_num, total)]

    mp4.save()


_WRITERS = {
    ".mp3": _apply_mp3,
    ".m4a": _apply_m4a,
}


def apply_tags(filepath: str, set_values: dict, delete_keys: list[str]) -> None:
    """Set and delete selected tags in one container save."""
    ext = _effective_extension(filepath)
    writer = _WRITERS.get(ext)
    if writer is None:
        raise UnsupportedFormatError(f"Tag writing is unsupported for {ext or 'this file'}")
    writer(filepath, set_values, delete_keys)


def write_mp3_tags(filepath: str, tags: dict) -> None:
    """Compatibility wrapper for callers that explicitly write MP3 tags."""
    _apply_mp3(filepath, tags, [])


def write_m4a_tags(filepath: str, tags: dict) -> None:
    """Compatibility wrapper for callers that explicitly write M4A tags."""
    _apply_m4a(filepath, tags, [])


def write_tags(filepath: str, tags: dict) -> None:
    """Write non-empty tag values without deleting other tags."""
    apply_tags(filepath, tags, [])


def delete_tags(filepath: str, keys: list[str]) -> None:
    """Delete selected friendly-name tags in one container save."""
    apply_tags(filepath, {}, keys)


def verify_container(filepath: str) -> bool:
    """Return whether mutagen can parse the container (not its full audio payload)."""
    try:
        return MutagenFile(filepath) is not None
    except Exception:
        return False
