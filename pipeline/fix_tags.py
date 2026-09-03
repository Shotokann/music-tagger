#!/usr/bin/env python3
"""
Fix music library tags using folder structure as source of truth.

Fixes:
  - Album tag: derived from album folder name, year prefixes stripped
  - Album tag: disc folder suffixes stripped (e.g., "[Disc 1]")
  - Year tag (TDRC): extracted from folder name where present
  - Artist/AlbumArtist: set from artist folder name

Usage:
  python -m pipeline.fix_tags                    # Dry run (preview)
  python -m pipeline.fix_tags --apply            # Apply changes
  python -m pipeline.fix_tags --artist "Adele"   # Filter to one artist
"""

import os
import re
import sys
import io
import argparse
from mutagen.id3 import ID3, ID3NoHeaderError, TIT2, TPE1, TPE2, TALB, TRCK, TDRC

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline.config import MUSIC_DIR

# Force UTF-8 output on Windows
if sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

EXTENSIONS = {".mp3"}

# Regex: disc folder patterns
DISC_FOLDER_RE = re.compile(
    r"(?i)^(?:.*\s)?(?:Disc|CD|Part)\s*#?\s*(\d+)(?:\s.*)?$"
)


def extract_year(folder_name):
    """Extract a 4-digit year from folder name patterns like:
    '2008 - 19', '[1998] Album', '(2004) Album', '1991 Kruzifixion (demo)'
    """
    m = re.match(r"^\[?(\d{4})\]?\s*-?\s*", folder_name)
    if m:
        year = int(m.group(1))
        if 1900 <= year <= 2030:
            return str(year)
    m = re.match(r"^\((\d{4})\)\s*", folder_name)
    if m:
        year = int(m.group(1))
        if 1900 <= year <= 2030:
            return str(year)
    return None


def clean_album_name(folder_name):
    """Strip year prefixes and disc suffixes from album folder name."""
    name = folder_name

    # Strip year prefixes: [YYYY], (YYYY), YYYY -, YYYY<space>
    name = re.sub(r"^\[\d{4}\]\s*-?\s*", "", name)
    name = re.sub(r"^\(\d{4}\)\s*-?\s*", "", name)
    name = re.sub(r"^\d{4}\s*-\s*", "", name)
    name = re.sub(r"^\d{4}\s+", "", name)

    # Strip disc suffixes: [Disc 1], (CD 2), etc.
    name = re.sub(r"\s*[\[\(](?:Disc|CD|Part)\s*#?\s*\d+[\]\)]$", "", name, flags=re.IGNORECASE)

    return name.strip()


def is_disc_folder(name):
    return bool(DISC_FOLDER_RE.match(name))


def get_track_title(filename):
    """Extract title from filename by stripping track number prefix and extension."""
    name = os.path.splitext(filename)[0]

    # Pattern: "NN. Title", "NN - Title", "NN Title", "NN_Title"
    name = re.sub(r"^\d+[\s.\-_]+", "", name)

    return name.strip()


def process_library(music_dir, apply=False, artist_filter=None):
    stats = {
        "total": 0,
        "album_fixed": 0,
        "year_added": 0,
        "artist_fixed": 0,
        "album_artist_fixed": 0,
        "title_fixed": 0,
        "already_correct": 0,
        "errors": 0,
    }

    changes_log = []

    for artist_name in sorted(os.listdir(music_dir)):
        artist_path = os.path.join(music_dir, artist_name)
        if not os.path.isdir(artist_path):
            continue

        if artist_filter and artist_name.lower() != artist_filter.lower():
            continue

        for album_folder in sorted(os.listdir(artist_path)):
            album_path = os.path.join(artist_path, album_folder)
            if not os.path.isdir(album_path):
                continue

            # Determine clean album name and year
            # If this IS a disc folder directly under artist, use artist folder context
            if is_disc_folder(album_folder):
                # Disc folder directly under artist — unusual, skip or use artist as album
                clean_album = artist_name
                year = None
            else:
                clean_album = clean_album_name(album_folder)
                year = extract_year(album_folder)

            # Process files in this folder and any disc subfolders
            folders_to_scan = [(album_path, album_folder)]

            # Check for disc subfolders
            for sub in sorted(os.listdir(album_path)):
                sub_path = os.path.join(album_path, sub)
                if os.path.isdir(sub_path) and is_disc_folder(sub):
                    folders_to_scan.append((sub_path, sub))

            for scan_path, scan_folder in folders_to_scan:
                for filename in sorted(os.listdir(scan_path)):
                    ext = os.path.splitext(filename)[1].lower()
                    if ext not in EXTENSIONS:
                        continue

                    filepath = os.path.join(scan_path, filename)
                    stats["total"] += 1

                    try:
                        try:
                            tags = ID3(filepath)
                        except ID3NoHeaderError:
                            tags = ID3()

                        file_changes = []

                        # Fix album tag
                        current_album = str(tags.get("TALB", "")).strip()
                        if current_album != clean_album:
                            file_changes.append(f'TALB: "{current_album}" -> "{clean_album}"')
                            if apply:
                                tags.delall("TALB")
                                tags.add(TALB(encoding=3, text=clean_album))

                        # Fix year tag
                        current_year = str(tags.get("TDRC", "")).strip()
                        if year and current_year != year:
                            file_changes.append(f'TDRC: "{current_year}" -> "{year}"')
                            if apply:
                                tags.delall("TDRC")
                                tags.add(TDRC(encoding=3, text=year))

                        # Fix artist
                        current_artist = str(tags.get("TPE1", "")).strip()
                        if current_artist != artist_name:
                            file_changes.append(f'TPE1: "{current_artist}" -> "{artist_name}"')
                            if apply:
                                tags.delall("TPE1")
                                tags.add(TPE1(encoding=3, text=artist_name))
                            stats["artist_fixed"] += 1

                        # Fix album artist
                        current_album_artist = str(tags.get("TPE2", "")).strip()
                        if current_album_artist != artist_name:
                            file_changes.append(f'TPE2: "{current_album_artist}" -> "{artist_name}"')
                            if apply:
                                tags.delall("TPE2")
                                tags.add(TPE2(encoding=3, text=artist_name))
                            stats["album_artist_fixed"] += 1

                        # Fix title (from filename)
                        expected_title = get_track_title(filename)
                        current_title = str(tags.get("TIT2", "")).strip()
                        if not current_title:
                            file_changes.append(f'TIT2: "" -> "{expected_title}"')
                            if apply:
                                tags.delall("TIT2")
                                tags.add(TIT2(encoding=3, text=expected_title))
                            stats["title_fixed"] += 1

                        if file_changes:
                            rel_path = os.path.relpath(filepath, music_dir)
                            changes_log.append((rel_path, file_changes))

                            if "TALB" in file_changes[0]:
                                stats["album_fixed"] += 1
                            if any("TDRC" in c for c in file_changes):
                                stats["year_added"] += 1

                            if apply:
                                tags.save(filepath, v2_version=4)
                        else:
                            stats["already_correct"] += 1

                    except Exception as e:
                        stats["errors"] += 1
                        print(f"  ERROR: {filepath}: {e}", file=sys.stderr)

    return stats, changes_log


def main():
    parser = argparse.ArgumentParser(description="Fix music library tags from folder structure")
    parser.add_argument("--apply", action="store_true", help="Apply changes (default: dry run)")
    parser.add_argument("--artist", type=str, default=None, help="Filter to specific artist")
    parser.add_argument("--verbose", action="store_true", help="Show every file change")
    args = parser.parse_args()

    mode = "APPLY" if args.apply else "DRY RUN"
    print(f"{'=' * 70}")
    print(f"Music Tag Fixer - {mode}")
    print(f"Library: {MUSIC_DIR}")
    if args.artist:
        print(f"Artist filter: {args.artist}")
    print(f"{'=' * 70}")
    print()

    stats, changes_log = process_library(
        MUSIC_DIR, apply=args.apply, artist_filter=args.artist
    )

    # Print changes grouped by album
    if args.verbose or not args.apply:
        current_album_path = None
        for rel_path, changes in changes_log:
            album_path = os.path.dirname(rel_path)
            if album_path != current_album_path:
                current_album_path = album_path
                print(f"\n  {album_path}/")

            filename = os.path.basename(rel_path)
            # Compact display: just show the tag changes
            change_str = " | ".join(changes)
            print(f"    {filename}: {change_str}")

    # Summary
    print(f"\n{'=' * 70}")
    print(f"Summary ({mode}):")
    print(f"  Total files scanned:  {stats['total']}")
    print(f"  Already correct:      {stats['already_correct']}")
    print(f"  Album tag fixed:      {stats['album_fixed']}")
    print(f"  Year tag added:       {stats['year_added']}")
    print(f"  Artist fixed:         {stats['artist_fixed']}")
    print(f"  Album artist fixed:   {stats['album_artist_fixed']}")
    print(f"  Title fixed:          {stats['title_fixed']}")
    print(f"  Errors:               {stats['errors']}")
    print(f"{'=' * 70}")

    if not args.apply and (stats["album_fixed"] or stats["year_added"] or stats["artist_fixed"]):
        print(f"\nThis was a DRY RUN. Run with --apply to write changes.")


if __name__ == "__main__":
    main()
