#!/usr/bin/env python3
"""
Stage 0: Inventory Scanner
Scans the music library and reads current tags from every file.
Output: data/inventory.json
"""

import json
import os
import sys
import time

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline.config import (
    MUSIC_DIR, DATA_DIR, SUPPORTED_EXTENSIONS, DISC_FOLDER_RE, SPECIAL_SUBFOLDERS_RE,
)
from pipeline.utils.tag_io import read_tags
from pipeline.utils.filename import (
    get_track_info, get_title_from_filename, get_track_number_width,
    is_disc_folder,
)
from pipeline.utils.matching import clean_album_name, extract_year


def scan_library(music_dir: str) -> dict:
    """
    Scan the entire music library.
    Returns dict with:
      - albums: dict of album_key -> {artist, album, files: [...]}
      - stats: counts by format, totals, etc.
    """
    albums = {}
    stats = {
        "total_files": 0,
        "by_format": {},
        "drm_files": 0,
        "artists": set(),
        "scan_errors": 0,
    }

    print(f"Scanning: {music_dir}")
    print()

    for artist_name in sorted(os.listdir(music_dir)):
        artist_path = os.path.join(music_dir, artist_name)
        if not os.path.isdir(artist_path):
            continue

        stats["artists"].add(artist_name)

        # Walk all files under this artist
        for root, dirs, files in os.walk(artist_path):
            # Skip loose files in folders that also contain disc subfolders
            has_disc_subfolders = any(is_disc_folder(d) for d in dirs)

            for filename in sorted(files):
                ext = os.path.splitext(filename)[1].lower()
                if ext not in SUPPORTED_EXTENSIONS:
                    continue

                if has_disc_subfolders:
                    # This file is loose alongside disc subfolders - skip
                    continue

                filepath = os.path.join(root, filename)
                stats["total_files"] += 1
                stats["by_format"][ext] = stats["by_format"].get(ext, 0) + 1

                is_drm = ext == ".m4p"
                if is_drm:
                    stats["drm_files"] += 1

                # Determine album grouping from folder structure
                rel_path = os.path.relpath(filepath, music_dir)
                parts = rel_path.replace("/", "\\").split("\\")

                if len(parts) >= 3:
                    parent_folder = parts[-2]  # immediate parent of file

                    # Check if parent is disc/special folder
                    if ((is_disc_folder(parent_folder) or
                         SPECIAL_SUBFOLDERS_RE.match(parent_folder)) and
                            len(parts) >= 4):
                        album_folder = parts[-3]  # grandparent
                    else:
                        album_folder = parent_folder
                elif len(parts) == 2:
                    album_folder = "Unknown"
                else:
                    album_folder = "Unknown"

                album_key = f"{artist_name}|{album_folder}"

                # Read current tags
                try:
                    current_tags = read_tags(filepath)
                except Exception as e:
                    current_tags = {"error": str(e)}
                    stats["scan_errors"] += 1

                # Parse filename structure
                folder_name = os.path.basename(os.path.dirname(filepath))
                track_info = get_track_info(filename, folder_name)
                title_from_file = get_title_from_filename(filename)
                pad_width = get_track_number_width(filename)

                file_entry = {
                    "path": filepath,
                    "filename": filename,
                    "extension": ext,
                    "size_bytes": os.path.getsize(filepath),
                    "is_drm": is_drm,
                    "current_tags": current_tags,
                    "parsed": {
                        "track_num": track_info["track"],
                        "disc_num": track_info["disc"],
                        "title_from_filename": title_from_file,
                        "pad_width": pad_width,
                    },
                }

                if album_key not in albums:
                    clean_album = clean_album_name(album_folder)
                    year = extract_year(album_folder)
                    albums[album_key] = {
                        "artist": artist_name,
                        "album_folder": album_folder,
                        "clean_album": clean_album,
                        "year_from_folder": year,
                        "files": [],
                    }

                albums[album_key]["files"].append(file_entry)

    # Convert set to count for JSON serialization
    stats["artist_count"] = len(stats["artists"])
    stats["album_count"] = len(albums)
    del stats["artists"]

    return {"albums": albums, "stats": stats}


def main():
    start = time.time()

    os.makedirs(DATA_DIR, exist_ok=True)

    result = scan_library(MUSIC_DIR)

    # Write output
    output_path = os.path.join(DATA_DIR, "inventory.json")
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)

    elapsed = time.time() - start
    stats = result["stats"]

    print("=" * 70)
    print("Stage 0: Inventory Complete")
    print("=" * 70)
    print(f"  Total files:      {stats['total_files']}")
    print(f"  Artists:          {stats['artist_count']}")
    print(f"  Albums:           {stats['album_count']}")
    print(f"  DRM files:        {stats['drm_files']}")
    print(f"  Scan errors:      {stats['scan_errors']}")
    print(f"  Format breakdown:")
    for ext, count in sorted(stats["by_format"].items()):
        print(f"    {ext}: {count}")
    print(f"  Time elapsed:     {elapsed:.1f}s")
    print(f"  Output:           {output_path}")
    print("=" * 70)


if __name__ == "__main__":
    main()
