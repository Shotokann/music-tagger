"""
Track info extraction, safe filename generation, and naming patterns.
Ported from v5: Get-TrackInfo, Get-TitleFromFilename, Get-SafeFileName, Get-TrackNumberWidth.
"""

import os
import re
from ..config import DISC_FOLDER_RE


def is_disc_folder(folder_name: str) -> bool:
    return bool(DISC_FOLDER_RE.match(folder_name))


def get_disc_number(folder_name: str) -> int:
    """Extract disc number from folder name, or 0 if not a disc folder."""
    m = DISC_FOLDER_RE.match(folder_name)
    return int(m.group(1)) if m else 0


def get_track_info(filename: str, folder_name: str = "") -> dict:
    """
    Extract track and disc number from filename.
    Returns dict with 'track' and 'disc' keys.
    Ported from v5 Get-TrackInfo.
    """
    result = {"track": 0, "disc": 0}

    if folder_name:
        result["disc"] = get_disc_number(folder_name)

    name = os.path.splitext(filename)[0]

    # Disc-track format: "1-06 Title" (disc 1, track 6)
    m = re.match(r"^([1-9])-(\d+)[\s\-\._]", name)
    if m:
        result["disc"] = int(m.group(1))
        result["track"] = int(m.group(2))
        return result

    # Simple track number: "06 Title", "06. Title", "06-Title"
    m = re.match(r"^(\d+)[\s\.\-_]", name)
    if m:
        result["track"] = int(m.group(1))
        return result

    # Artist-prefixed: "Ensiferum - 01 Intro"
    m = re.match(r"^[^-]+-\s*(\d+)[\s\.\-_]", name)
    if m:
        result["track"] = int(m.group(1))
        return result

    return result


def get_track_number_width(filename: str) -> int:
    """Get track number padding width from original filename."""
    name = os.path.splitext(filename)[0]

    # Disc-track: "1-06"
    m = re.match(r"^[1-9]-(\d+)[\s\-\._]", name)
    if m:
        return len(m.group(1))

    # Simple: "06", "006"
    m = re.match(r"^(\d+)[\s\.\-_]", name)
    if m:
        return len(m.group(1))

    # Artist-prefixed
    m = re.match(r"^[^-]+-\s*(\d+)[\s\.\-_]", name)
    if m:
        return len(m.group(1))

    return 2  # default


def get_title_from_filename(filename: str) -> str:
    """
    Extract title portion from filename, stripping track numbers and artist prefixes.
    Ported from v5 Get-TitleFromFilename.
    """
    name = os.path.splitext(filename)[0]

    # Pattern 1: "Artist - NN Title"
    m = re.match(r"^.+?\s+-\s+\d+[\s\.\-_]+(.+)$", name)
    if m:
        return m.group(1).strip()

    # Pattern 2: "NN-Artist-Title"
    m = re.match(r"^\d+-[^-]+-(.+)$", name)
    if m:
        return m.group(1).strip()

    # Pattern 3: disc-track prefix "1-06 Title"
    name = re.sub(r"^[1-9]-\d+[\s\-\._]+", "", name)

    # Pattern 4: simple track number "06 Title"
    name = re.sub(r"^\d+[\s\.\-_]+", "", name)

    return name.strip()


# Windows-unsafe character replacements (fullwidth Unicode equivalents)
_UNSAFE_CHARS = {
    "<": "\uff1c",   # fullwidth less-than
    ">": "\uff1e",   # fullwidth greater-than
    ":": "\uff1a",   # fullwidth colon
    '"': "\uff02",   # fullwidth quotation
    "/": "\u2044",   # fraction slash
    "|": "\uff5c",   # fullwidth vertical line
    "?": "\uff1f",   # fullwidth question mark
    "*": "\uff0a",   # fullwidth asterisk
}


def get_safe_filename(filename: str) -> str:
    """Replace Windows-unsafe characters with fullwidth equivalents."""
    safe = filename
    for char, replacement in _UNSAFE_CHARS.items():
        safe = safe.replace(char, replacement)
    return safe


def build_target_filename(
    track_num: int,
    title: str,
    ext: str,
    pad_width: int = 2,
) -> str:
    """Build the target filename: 'NN Title.ext'."""
    safe_title = get_safe_filename(title)
    padded = str(track_num).zfill(pad_width)
    return f"{padded} {safe_title}{ext}"
