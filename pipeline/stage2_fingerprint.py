#!/usr/bin/env python3
"""
Stage 2: Targeted Fingerprinting
Only fingerprints files in anomaly and not-found albums.
Output: data/fingerprints.json (updates resolved.json entries)
"""

import io
import json
import os
import sys
import time

# Force UTF-8 output on Windows
if sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline.config import DATA_DIR, FINGERPRINTABLE_EXTENSIONS
from pipeline.utils.fingerprint import fingerprint_and_lookup


def main():
    start = time.time()

    # Load resolved data
    resolved_path = os.path.join(DATA_DIR, "resolved.json")
    if not os.path.exists(resolved_path):
        print("ERROR: resolved.json not found. Run stage1_resolve.py first.")
        sys.exit(1)

    with open(resolved_path, "r", encoding="utf-8") as f:
        resolved_data = json.load(f)

    # Load inventory for file paths
    inventory_path = os.path.join(DATA_DIR, "inventory.json")
    with open(inventory_path, "r", encoding="utf-8") as f:
        inventory = json.load(f)

    # Find albums that need fingerprinting
    target_albums = []
    for result in resolved_data["results"]:
        if result["status"] in ("anomaly", "not_found"):
            album_key = result["album_key"]
            if album_key in inventory["albums"]:
                target_albums.append((result, inventory["albums"][album_key]))

    if not target_albums:
        print("No anomaly or not-found albums to fingerprint.")
        _save_fingerprints(os.path.join(DATA_DIR, "fingerprints.json"), [])
        return

    print("=" * 70)
    print("Stage 2: Targeted Fingerprinting")
    print("=" * 70)
    print(f"Albums to fingerprint: {len(target_albums)}")
    total_files = sum(len(a[1]["files"]) for a in target_albums)
    print(f"Total files: {total_files}")
    print()

    fingerprint_results = []
    files_processed = 0
    files_matched = 0
    files_failed = 0

    for album_result, album_data in target_albums:
        album_key = album_result["album_key"]
        print(f"[{album_result['status'].upper()}] {album_key}")

        album_fingerprints = {
            "album_key": album_key,
            "original_status": album_result["status"],
            "files": [],
        }

        for file_entry in album_data["files"]:
            filepath = file_entry["path"]
            ext = file_entry["extension"]

            if ext not in FINGERPRINTABLE_EXTENSIONS:
                print(f"    SKIP (format): {file_entry['filename']}")
                continue

            if file_entry.get("is_drm"):
                print(f"    SKIP (DRM): {file_entry['filename']}")
                continue

            files_processed += 1
            print(f"    Fingerprinting: {file_entry['filename']}...", end=" ", flush=True)

            match = fingerprint_and_lookup(filepath)

            if match and match["score"] >= 0.8:
                files_matched += 1
                print(f"MATCH ({match['score']:.0%}) - {match['artist']} - {match['title']}")
                album_fingerprints["files"].append({
                    "filename": file_entry["filename"],
                    "path": filepath,
                    "match": {
                        "score": match["score"],
                        "recording_id": match["recording_id"],
                        "title": match["title"],
                        "artist": match["artist"],
                        "releases": match.get("releases", []),
                    },
                })
            elif match:
                print(f"LOW ({match['score']:.0%}) - {match.get('title', '?')}")
                album_fingerprints["files"].append({
                    "filename": file_entry["filename"],
                    "path": filepath,
                    "match": {
                        "score": match["score"],
                        "recording_id": match["recording_id"],
                        "title": match["title"],
                        "artist": match["artist"],
                        "releases": match.get("releases", []),
                    },
                })
            else:
                files_failed += 1
                print("NO MATCH")
                album_fingerprints["files"].append({
                    "filename": file_entry["filename"],
                    "path": filepath,
                    "match": None,
                })

        fingerprint_results.append(album_fingerprints)
        print()

        # Incremental save after each album
        output_path = os.path.join(DATA_DIR, "fingerprints.json")
        _save_fingerprints(output_path, fingerprint_results)

    # Final save
    output_path = os.path.join(DATA_DIR, "fingerprints.json")

    elapsed = time.time() - start
    print("=" * 70)
    print("Stage 2: Fingerprinting Complete")
    print("=" * 70)
    print(f"  Albums processed:  {len(target_albums)}")
    print(f"  Files processed:   {files_processed}")
    print(f"  Files matched:     {files_matched}")
    print(f"  Files unmatched:   {files_failed}")
    print(f"  Time elapsed:      {elapsed:.0f}s ({elapsed/60:.1f} min)")
    print(f"  Output:            {output_path}")
    print("=" * 70)


def _save_fingerprints(path: str, results: list):
    output = {"results": results, "count": len(results)}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
