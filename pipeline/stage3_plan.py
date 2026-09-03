#!/usr/bin/env python3
"""
Stage 3: Change Plan Generation
Merges inventory + resolved + fingerprints into a per-file change plan.
Output: data/change_plan.json
"""

import io
import json
import os
import sys
import time

if sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline.config import DATA_DIR, WRITABLE_EXTENSIONS
from pipeline.utils.filename import (
    get_track_info, get_title_from_filename, get_track_number_width,
    build_target_filename, is_disc_folder,
)
from pipeline.utils.matching import (
    find_best_title_match, clean_album_name, extract_year,
)


def generate_plan(inventory: dict, resolved_data: dict, fingerprints: dict) -> dict:
    """Generate the complete change plan."""
    # Index resolved by album_key
    resolved_index = {r["album_key"]: r for r in resolved_data.get("results", [])}

    # Index fingerprints by album_key -> filename -> match
    fp_index = {}
    for fp_album in fingerprints.get("results", []):
        album_key = fp_album["album_key"]
        fp_index[album_key] = {}
        for fp_file in fp_album.get("files", []):
            fp_index[album_key][fp_file["filename"]] = fp_file.get("match")

    changes = []
    stats = {
        "total_files": 0,
        "has_tag_changes": 0,
        "has_rename": 0,
        "has_both": 0,
        "no_change": 0,
        "skipped_drm": 0,
        "skipped_no_match": 0,
        "confidence_high": 0,
        "confidence_medium": 0,
        "confidence_low": 0,
    }

    for album_key, album_data in inventory["albums"].items():
        artist = album_data["artist"]
        album_folder = album_data["album_folder"]
        resolved = resolved_index.get(album_key)

        if not resolved:
            continue

        status = resolved.get("status", "")
        track_listing = resolved.get("track_listing") or {}
        # Convert string keys back to int where possible
        int_listing = {}
        for k, v in track_listing.items():
            try:
                int_listing[int(k)] = v
            except ValueError:
                int_listing[k] = v  # disc-track keys stay as strings

        mb_title = resolved.get("mb_release_title", "")
        mb_date = resolved.get("mb_release_date", "")
        mb_year = mb_date[:4] if mb_date and len(mb_date) >= 4 else None
        match_score = resolved.get("match_score")
        media_count = resolved.get("media_count", 1)

        # Determine target album name
        if status in ("matched", "anomaly") and mb_title:
            target_album = mb_title
        else:
            target_album = clean_album_name(album_folder)

        # Determine target year
        target_year = mb_year or album_data.get("year_from_folder") or ""

        for file_entry in album_data["files"]:
            stats["total_files"] += 1
            filepath = file_entry["path"]
            filename = file_entry["filename"]
            ext = file_entry["extension"]

            # Skip DRM files
            if file_entry.get("is_drm"):
                stats["skipped_drm"] += 1
                continue

            # Skip non-writable formats for tag changes
            can_write_tags = ext in WRITABLE_EXTENSIONS

            # Determine confidence
            if match_score is not None:
                if match_score >= 0.85:
                    confidence = "high"
                    stats["confidence_high"] += 1
                elif match_score >= 0.70:
                    confidence = "medium"
                    stats["confidence_medium"] += 1
                else:
                    confidence = "low"
                    stats["confidence_low"] += 1
            else:
                confidence = "low"
                stats["confidence_low"] += 1

            # Determine source
            source = "metadata"
            fp_match = fp_index.get(album_key, {}).get(filename)
            if fp_match and fp_match.get("score", 0) >= 0.8:
                source = "fingerprint"

            # Find target title
            folder_name = os.path.basename(os.path.dirname(filepath))
            track_info = get_track_info(filename, folder_name)
            track_num = track_info["track"]
            disc_num = track_info["disc"]
            pad_width = file_entry["parsed"]["pad_width"]

            target_title = None

            if status in ("matched", "anomaly") and int_listing:
                # Try disc-specific key first
                if disc_num > 0:
                    key = f"{disc_num}-{track_num}"
                    target_title = int_listing.get(key)
                if target_title is None and track_num > 0:
                    target_title = int_listing.get(track_num)

                # Fallback: title-based matching
                if target_title is None:
                    file_title = get_title_from_filename(filename)
                    tm = find_best_title_match(file_title, int_listing, 0.70)
                    if tm:
                        target_title = tm[0]

                # Fingerprint override
                if fp_match and fp_match.get("score", 0) >= 0.8:
                    target_title = fp_match.get("title") or target_title

            if target_title is None and status in ("skipped", "not_found"):
                # No MB data - use filename-derived title
                target_title = get_title_from_filename(filename)
                stats["skipped_no_match"] += 1

            if target_title is None:
                target_title = get_title_from_filename(filename)

            # Build tag changes
            current_tags = file_entry.get("current_tags", {})
            tag_changes = {}

            tag_targets = {
                "artist": artist,
                "album_artist": artist,
                "album": target_album,
                "title": target_title,
                "year": target_year,
            }

            # Track number with total
            if track_num > 0:
                total_tracks = len([f for f in album_data["files"]
                                    if not f.get("is_drm")])
                tag_targets["track"] = f"{track_num}/{total_tracks}" if total_tracks else str(track_num)

            # Disc number
            if disc_num > 0 and media_count > 1:
                tag_targets["disc"] = f"{disc_num}/{media_count}"
            elif disc_num > 0:
                tag_targets["disc"] = str(disc_num)

            for tag_key, target_val in tag_targets.items():
                if not target_val:
                    continue
                current_val = current_tags.get(tag_key, "")
                if str(current_val).strip() != str(target_val).strip():
                    tag_changes[tag_key] = {
                        "from": str(current_val).strip(),
                        "to": str(target_val).strip(),
                    }

            # Build rename
            rename = None
            if track_num > 0 and target_title:
                target_filename = build_target_filename(track_num, target_title, ext, pad_width)
                if target_filename != filename:
                    rename = {"from": filename, "to": target_filename}
            elif target_title and not track_num:
                # No track number, but we have a title - just check if rename needed
                from pipeline.utils.filename import get_safe_filename
                safe_title = get_safe_filename(target_title)
                target_filename = f"{safe_title}{ext}"
                if target_filename != filename:
                    rename = {"from": filename, "to": target_filename}

            has_tag_changes = bool(tag_changes) and can_write_tags
            has_rename = rename is not None
            has_changes = has_tag_changes or has_rename

            if has_tag_changes and has_rename:
                stats["has_both"] += 1
            elif has_tag_changes:
                stats["has_tag_changes"] += 1
            elif has_rename:
                stats["has_rename"] += 1
            else:
                stats["no_change"] += 1

            change_entry = {
                "file_path": filepath,
                "filename": filename,
                "album_key": album_key,
                "extension": ext,
                "confidence": confidence,
                "source": source,
                "has_changes": has_changes,
                "tag_changes": tag_changes if has_tag_changes else {},
                "rename": rename,
                "can_write_tags": can_write_tags,
            }

            changes.append(change_entry)

    return {"changes": changes, "stats": stats}


def main():
    start = time.time()

    # Load inputs
    inventory_path = os.path.join(DATA_DIR, "inventory.json")
    resolved_path = os.path.join(DATA_DIR, "resolved.json")
    fingerprints_path = os.path.join(DATA_DIR, "fingerprints.json")

    if not os.path.exists(inventory_path):
        print("ERROR: inventory.json not found.")
        sys.exit(1)
    if not os.path.exists(resolved_path):
        print("ERROR: resolved.json not found.")
        sys.exit(1)

    with open(inventory_path, "r", encoding="utf-8") as f:
        inventory = json.load(f)
    with open(resolved_path, "r", encoding="utf-8") as f:
        resolved_data = json.load(f)

    fingerprints = {}
    if os.path.exists(fingerprints_path):
        with open(fingerprints_path, "r", encoding="utf-8") as f:
            fingerprints = json.load(f)

    print("=" * 70)
    print("Stage 3: Change Plan Generation")
    print("=" * 70)

    plan = generate_plan(inventory, resolved_data, fingerprints)
    stats = plan["stats"]

    # Save
    output_path = os.path.join(DATA_DIR, "change_plan.json")
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(plan, f, indent=2, ensure_ascii=False)

    elapsed = time.time() - start
    print(f"  Total files:       {stats['total_files']}")
    print(f"  Tag changes only:  {stats['has_tag_changes']}")
    print(f"  Rename only:       {stats['has_rename']}")
    print(f"  Both:              {stats['has_both']}")
    print(f"  No change:         {stats['no_change']}")
    print(f"  Skipped (DRM):     {stats['skipped_drm']}")
    print(f"  Skipped (no match):{stats['skipped_no_match']}")
    print(f"  Confidence: high={stats['confidence_high']} medium={stats['confidence_medium']} low={stats['confidence_low']}")
    print(f"  Time elapsed:      {elapsed:.1f}s")
    print(f"  Output:            {output_path}")
    print("=" * 70)


if __name__ == "__main__":
    main()
