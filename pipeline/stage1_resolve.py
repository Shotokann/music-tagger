#!/usr/bin/env python3
"""
Stage 1: MusicBrainz Resolution
For each album in the inventory, find the best matching MusicBrainz release.
Supports incremental resume: skips already-resolved albums.
Output: data/resolved.json
"""

import io
import json
import os
import re
import sys
import time

# Force UTF-8 output on Windows (prevents charmap encoding errors with Unicode MB data)
if sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline.config import (
    DATA_DIR, MATCH_THRESHOLD, MAX_CANDIDATES,
    is_skip_artist, is_skip_album, get_hardcoded_release_id,
)
from pipeline.utils.mb_client import (
    multi_strategy_search, get_release_by_id, build_track_listing,
    rank_releases,
)
from pipeline.utils.matching import (
    clean_album_name, title_similarity, normalize_title, get_core_title,
    remove_diacritics, find_best_title_match,
)
from pipeline.utils.filename import get_track_info, get_title_from_filename


def measure_release_match(track_listing: dict, files: list) -> float:
    """
    Measure how well a track listing matches actual files.
    Returns score 0.0 to 1.0.
    Ported from v5 Measure-ReleaseMatch.
    """
    match_count = 0
    total_checked = 0

    for f in files:
        folder_name = os.path.basename(os.path.dirname(f["path"]))
        track_info = get_track_info(f["filename"], folder_name)
        track_num = track_info["track"]
        disc_num = track_info["disc"]

        if track_num <= 0:
            # No track number - try title-based matching
            total_checked += 1
            file_title = get_title_from_filename(f["filename"])
            title_match = find_best_title_match(file_title, track_listing, 0.70)
            if title_match:
                match_count += 1
            continue

        total_checked += 1

        # Look up MB title
        mb_title = None
        if disc_num > 0:
            key = f"{disc_num}-{track_num}"
            mb_title = track_listing.get(key)
        if mb_title is None:
            mb_title = track_listing.get(track_num)

        if not mb_title:
            continue

        # Compare titles
        file_title = get_title_from_filename(f["filename"])
        sim = title_similarity(file_title, mb_title)

        if sim >= 0.75:
            match_count += 1

    if total_checked == 0:
        return 0.0
    return match_count / total_checked


def evaluate_candidates(
    candidates: list,
    files: list,
    artist: str,
    album: str,
    verbose: bool = True,
) -> dict | None:
    """
    Evaluate ranked release candidates against actual files.
    Returns best result dict or None.
    Ported from v5 Get-BestMatchingRelease.
    """
    best_result = None
    best_score = -1.0
    checked = 0

    for release, rank_score, total_tracks in candidates:
        if checked >= MAX_CANDIDATES:
            break

        status = release.get("status", "")
        if status == "Bootleg":
            continue

        release_id = release.get("id", "")
        release_data = get_release_by_id(release_id)
        checked += 1

        if not release_data:
            continue

        track_listing = build_track_listing(release_data)
        match_score = measure_release_match(track_listing, files)

        if verbose:
            media_list = release_data.get("medium-list", [])
            disc_info = f"{len(media_list)} discs, " if len(media_list) > 1 else ""
            track_count = sum(len(m.get("track-list", [])) for m in media_list)
            status_tag = f" [{status}]" if status and status != "Official" else ""
            print(f"    Candidate {checked}: {release.get('title', '?')}{status_tag} "
                  f"({disc_info}{track_count} tracks) - {match_score:.0%} match")

        if match_score > best_score:
            best_score = match_score
            best_result = {
                "release_id": release_id,
                "release_title": release_data.get("title", ""),
                "release_status": release_data.get("status", ""),
                "track_listing": track_listing,
                "match_score": match_score,
                "media_count": len(release_data.get("medium-list", [])),
                "release_date": release_data.get("date", ""),
            }

        if match_score >= MATCH_THRESHOLD:
            if verbose:
                print(f"    Accepted: {match_score:.0%} match")
            best_result["is_anomaly"] = False
            return best_result

    if best_result:
        best_result["is_anomaly"] = True
        if verbose:
            print(f"    WARNING: Best match only {best_score:.0%} - flagging as anomaly")

    return best_result


def resolve_album(album_key: str, album_data: dict, verbose: bool = True) -> dict:
    """Resolve a single album against MusicBrainz."""
    artist = album_data["artist"]
    album_folder = album_data["album_folder"]
    clean_album = album_data["clean_album"]
    files = album_data["files"]
    file_count = len(files)

    result = {
        "album_key": album_key,
        "artist": artist,
        "album_folder": album_folder,
        "clean_album": clean_album,
        "file_count": file_count,
        "status": "pending",
        "skip_reason": None,
        "mb_release_id": None,
        "mb_release_title": None,
        "mb_release_date": None,
        "track_listing": None,
        "match_score": None,
        "is_anomaly": False,
        "media_count": 1,
    }

    # Check skip lists
    if is_skip_artist(artist):
        result["status"] = "skipped"
        result["skip_reason"] = "Artist in skip list"
        return result

    if is_skip_album(artist, album_folder):
        result["status"] = "skipped"
        result["skip_reason"] = "Album in skip list"
        return result

    # Check hardcoded release IDs
    hardcoded_id = get_hardcoded_release_id(artist, album_folder)
    if hardcoded_id is None:
        hardcoded_id = get_hardcoded_release_id(artist, clean_album)

    if hardcoded_id:
        if verbose:
            print(f"    Using hardcoded release ID: {hardcoded_id}")
        release_data = get_release_by_id(hardcoded_id)
        if release_data:
            track_listing = build_track_listing(release_data)
            result["status"] = "matched"
            result["mb_release_id"] = hardcoded_id
            result["mb_release_title"] = release_data.get("title", "")
            result["mb_release_date"] = release_data.get("date", "")
            result["track_listing"] = {str(k): v for k, v in track_listing.items()}
            result["match_score"] = 1.0  # hardcoded = trusted
            result["media_count"] = len(release_data.get("medium-list", []))
            return result

    # Multi-strategy search
    try:
        is_special = bool(re.search(
            r"(?i)(Special|Deluxe|Limited|Expanded|Extended)\s*(Edition|Ed\.?)?",
            album_folder
        ))

        all_releases = multi_strategy_search(artist, clean_album, file_count)

        if not all_releases:
            result["status"] = "not_found"
            if verbose:
                print("    Album not found in MusicBrainz")
            return result

        if verbose:
            print(f"    Found {len(all_releases)} unique releases, evaluating candidates...")

        ranked = rank_releases(all_releases, file_count, is_special)
        eval_result = evaluate_candidates(ranked, files, artist, album_folder, verbose)

        if eval_result:
            result["status"] = "anomaly" if eval_result["is_anomaly"] else "matched"
            result["mb_release_id"] = eval_result["release_id"]
            result["mb_release_title"] = eval_result["release_title"]
            result["mb_release_date"] = eval_result.get("release_date", "")
            result["match_score"] = eval_result["match_score"]
            result["media_count"] = eval_result.get("media_count", 1)
            # Convert keys to strings for JSON
            result["track_listing"] = {
                str(k): v for k, v in eval_result["track_listing"].items()
            }
        else:
            result["status"] = "not_found"

    except Exception as e:
        result["status"] = "error"
        result["skip_reason"] = str(e)
        if verbose:
            print(f"    ERROR: {e}")

    return result


def main():
    start = time.time()

    # Load inventory
    inventory_path = os.path.join(DATA_DIR, "inventory.json")
    if not os.path.exists(inventory_path):
        print("ERROR: inventory.json not found. Run stage0_inventory.py first.")
        sys.exit(1)

    with open(inventory_path, "r", encoding="utf-8") as f:
        inventory = json.load(f)

    albums = inventory["albums"]
    total = len(albums)

    # Load existing resolved data for resume
    resolved_path = os.path.join(DATA_DIR, "resolved.json")
    resolved = {}
    if os.path.exists(resolved_path):
        with open(resolved_path, "r", encoding="utf-8") as f:
            existing = json.load(f)
            resolved = {r["album_key"]: r for r in existing.get("results", [])}
        print(f"Resuming: {len(resolved)} albums already resolved")
        print()

    print("=" * 70)
    print("Stage 1: MusicBrainz Resolution")
    print("=" * 70)
    print(f"Albums to process: {total}")
    print()

    count = 0
    status_counts = {"matched": 0, "anomaly": 0, "skipped": 0, "not_found": 0, "error": 0}

    for album_key, album_data in albums.items():
        count += 1

        # Skip if already resolved
        if album_key in resolved:
            s = resolved[album_key].get("status", "")
            if s in status_counts:
                status_counts[s] += 1
            print(f"[{count}/{total}] {album_key} - already resolved ({s})")
            continue

        print(f"[{count}/{total}] {album_key}")

        result = resolve_album(album_key, album_data)
        resolved[album_key] = result

        s = result["status"]
        if s in status_counts:
            status_counts[s] += 1

        if s == "skipped":
            print(f"    Skipped: {result['skip_reason']}")
        elif s == "matched":
            print(f"    Matched: {result['mb_release_title']} ({result['match_score']:.0%})")
        elif s == "anomaly":
            print(f"    ANOMALY: {result['mb_release_title']} ({result['match_score']:.0%})")

        print()

        # Incremental save every 10 albums
        if count % 10 == 0:
            _save_resolved(resolved_path, resolved)

    # Final save
    _save_resolved(resolved_path, resolved)

    elapsed = time.time() - start
    print("=" * 70)
    print("Stage 1: MusicBrainz Resolution Complete")
    print("=" * 70)
    print(f"  Total albums:     {total}")
    print(f"  Matched:          {status_counts['matched']}")
    print(f"  Anomalies:        {status_counts['anomaly']}")
    print(f"  Skipped:          {status_counts['skipped']}")
    print(f"  Not found:        {status_counts['not_found']}")
    print(f"  Errors:           {status_counts['error']}")
    print(f"  Time elapsed:     {elapsed:.0f}s ({elapsed/60:.1f} min)")
    print(f"  Output:           {resolved_path}")
    print("=" * 70)


def _save_resolved(path: str, resolved: dict):
    """Save resolved data to JSON."""
    output = {
        "results": list(resolved.values()),
        "count": len(resolved),
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
