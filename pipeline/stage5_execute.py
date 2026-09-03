#!/usr/bin/env python3
"""
Stage 5: Execution
Applies approved changes: writes tags and renames files.
Supports --dry-run, --apply, and --rollback modes.
Output: data/execution_log.json + data/backup_manifest.json
"""

import argparse
import io
import json
import os
import sys
import time

if sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline.config import DATA_DIR
from pipeline.utils.tag_io import read_tags, write_tags


def execute_dry_run(approved: dict) -> dict:
    """Show what would happen without making changes."""
    log = {"mode": "dry_run", "entries": [], "stats": {
        "would_tag": 0, "would_rename": 0, "would_skip": 0,
    }}

    for c in approved["changes"]:
        if not c.get("approved") or not c.get("has_changes"):
            log["stats"]["would_skip"] += 1
            continue

        entry = {
            "file_path": c["file_path"],
            "actions": [],
        }

        if c.get("tag_changes") and c.get("can_write_tags"):
            log["stats"]["would_tag"] += 1
            entry["actions"].append({
                "type": "tag_write",
                "changes": c["tag_changes"],
            })

        if c.get("rename"):
            log["stats"]["would_rename"] += 1
            entry["actions"].append({
                "type": "rename",
                "from": c["rename"]["from"],
                "to": c["rename"]["to"],
            })

        if entry["actions"]:
            log["entries"].append(entry)

    return log


def create_backup_manifest(approved: dict) -> list:
    """Read current state of all files that will be modified."""
    manifest = []

    for c in approved["changes"]:
        if not c.get("approved") or not c.get("has_changes"):
            continue

        filepath = c["file_path"]
        if not os.path.exists(filepath):
            continue

        try:
            current_tags = read_tags(filepath)
        except Exception:
            current_tags = {}

        manifest.append({
            "file_path": filepath,
            "original_filename": c["filename"],
            "original_tags": current_tags,
            "backup_timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        })

    return manifest


def execute_apply(approved: dict) -> dict:
    """Apply all approved changes."""
    log = {"mode": "apply", "entries": [], "stats": {
        "tags_written": 0, "files_renamed": 0, "errors": 0, "skipped": 0,
    }}

    for c in approved["changes"]:
        if not c.get("approved") or not c.get("has_changes"):
            log["stats"]["skipped"] += 1
            continue

        filepath = c["file_path"]
        entry = {
            "file_path": filepath,
            "actions": [],
            "errors": [],
        }

        # Write tags first
        if c.get("tag_changes") and c.get("can_write_tags"):
            try:
                # Convert tag_changes to write format
                tags_to_write = {}
                for tag_key, diff in c["tag_changes"].items():
                    tags_to_write[tag_key] = diff["to"]

                write_tags(filepath, tags_to_write)
                entry["actions"].append({"type": "tag_write", "status": "success"})
                log["stats"]["tags_written"] += 1
            except Exception as e:
                entry["errors"].append(f"Tag write failed: {e}")
                log["stats"]["errors"] += 1

        # Then rename
        if c.get("rename"):
            try:
                dir_path = os.path.dirname(filepath)
                new_path = os.path.join(dir_path, c["rename"]["to"])

                if os.path.exists(new_path) and new_path != filepath:
                    entry["errors"].append(f"Target exists: {c['rename']['to']}")
                    log["stats"]["errors"] += 1
                else:
                    # Use the potentially-updated filepath (tags already written to original)
                    current_path = filepath
                    os.rename(current_path, new_path)
                    entry["actions"].append({
                        "type": "rename",
                        "from": c["rename"]["from"],
                        "to": c["rename"]["to"],
                        "status": "success",
                    })
                    log["stats"]["files_renamed"] += 1
            except Exception as e:
                entry["errors"].append(f"Rename failed: {e}")
                log["stats"]["errors"] += 1

        log["entries"].append(entry)

        # Small delay for OneDrive sync
        time.sleep(0.02)

    return log


def execute_rollback(manifest: list) -> dict:
    """Rollback changes using backup manifest."""
    log = {"mode": "rollback", "entries": [], "stats": {
        "tags_restored": 0, "files_renamed_back": 0, "errors": 0,
    }}

    for entry in manifest:
        original_path = entry["file_path"]
        original_filename = entry["original_filename"]
        original_tags = entry.get("original_tags", {})

        # Find the file (might have been renamed)
        dir_path = os.path.dirname(original_path)
        current_path = original_path

        if not os.path.exists(current_path):
            # Try to find by original filename
            candidate = os.path.join(dir_path, original_filename)
            if os.path.exists(candidate):
                current_path = candidate
            else:
                # Search directory for the file
                found = False
                if os.path.exists(dir_path):
                    for f in os.listdir(dir_path):
                        full = os.path.join(dir_path, f)
                        if os.path.isfile(full):
                            # Could be the renamed version
                            current_path = full
                            found = True
                            break
                if not found:
                    log["stats"]["errors"] += 1
                    log["entries"].append({
                        "original": original_path,
                        "error": "File not found for rollback",
                    })
                    continue

        rollback_entry = {"original": original_path, "current": current_path, "actions": []}

        # Restore tags
        if original_tags and current_path.lower().endswith((".mp3", ".m4a")):
            try:
                # Extract writable tags from original
                tags_to_restore = {}
                for key in ("title", "artist", "album_artist", "album", "track", "year", "disc"):
                    val = original_tags.get(key, "")
                    if val:
                        tags_to_restore[key] = val

                if tags_to_restore:
                    write_tags(current_path, tags_to_restore)
                    rollback_entry["actions"].append("tags_restored")
                    log["stats"]["tags_restored"] += 1
            except Exception as e:
                rollback_entry["error"] = f"Tag restore failed: {e}"
                log["stats"]["errors"] += 1

        # Restore filename
        current_filename = os.path.basename(current_path)
        if current_filename != original_filename:
            try:
                target = os.path.join(dir_path, original_filename)
                os.rename(current_path, target)
                rollback_entry["actions"].append("renamed_back")
                log["stats"]["files_renamed_back"] += 1
            except Exception as e:
                rollback_entry["error"] = f"Rename rollback failed: {e}"
                log["stats"]["errors"] += 1

        log["entries"].append(rollback_entry)

    return log


def main():
    parser = argparse.ArgumentParser(description="Stage 5: Execute changes")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dry-run", action="store_true", help="Show what would happen")
    group.add_argument("--apply", action="store_true", help="Apply approved changes")
    group.add_argument("--rollback", action="store_true", help="Rollback using backup manifest")
    args = parser.parse_args()

    approved_path = os.path.join(DATA_DIR, "approved_plan.json")
    manifest_path = os.path.join(DATA_DIR, "backup_manifest.json")
    log_path = os.path.join(DATA_DIR, "execution_log.json")

    if args.rollback:
        if not os.path.exists(manifest_path):
            print("ERROR: backup_manifest.json not found. Nothing to rollback.")
            sys.exit(1)
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)

        print("=" * 70)
        print("Stage 5: ROLLBACK")
        print("=" * 70)

        log = execute_rollback(manifest)

        with open(log_path, "w", encoding="utf-8") as f:
            json.dump(log, f, indent=2, ensure_ascii=False)

        print(f"  Tags restored:     {log['stats']['tags_restored']}")
        print(f"  Files renamed back:{log['stats']['files_renamed_back']}")
        print(f"  Errors:            {log['stats']['errors']}")
        print("=" * 70)
        return

    if not os.path.exists(approved_path):
        print("ERROR: approved_plan.json not found. Run stage4_validate.py first.")
        sys.exit(1)

    with open(approved_path, "r", encoding="utf-8") as f:
        approved = json.load(f)

    if args.dry_run:
        print("=" * 70)
        print("Stage 5: DRY RUN")
        print("=" * 70)

        log = execute_dry_run(approved)

        # Show sample of what would happen
        for entry in log["entries"][:30]:
            print(f"  {os.path.basename(entry['file_path'])}")
            for action in entry["actions"]:
                if action["type"] == "rename":
                    print(f"    RENAME: {action['from']} -> {action['to']}")
                elif action["type"] == "tag_write":
                    for tag, diff in action["changes"].items():
                        print(f"    {tag}: \"{diff['from'][:30]}\" -> \"{diff['to'][:30]}\"")

        if len(log["entries"]) > 30:
            print(f"  ... and {len(log['entries']) - 30} more files")

        print()
        print(f"  Would write tags:  {log['stats']['would_tag']}")
        print(f"  Would rename:      {log['stats']['would_rename']}")
        print(f"  Would skip:        {log['stats']['would_skip']}")

        # Save dry-run marker
        marker = os.path.join(DATA_DIR, ".dry-run-complete")
        with open(marker, "w") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S"))

        with open(log_path, "w", encoding="utf-8") as f:
            json.dump(log, f, indent=2, ensure_ascii=False)

        print(f"  Log: {log_path}")
        print("=" * 70)
        print()
        print("Run with --apply to execute these changes.")

    elif args.apply:
        # Check dry-run was done
        marker = os.path.join(DATA_DIR, ".dry-run-complete")
        if not os.path.exists(marker):
            print("ERROR: Run --dry-run first before --apply.")
            sys.exit(1)

        print("=" * 70)
        print("Stage 5: APPLYING CHANGES")
        print("=" * 70)

        start = time.time()

        # Create backup manifest first
        print("Creating backup manifest...", flush=True)
        manifest = create_backup_manifest(approved)
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)
        print(f"  Backed up {len(manifest)} file states to {manifest_path}")
        print()

        # Apply changes
        print("Applying changes...")
        log = execute_apply(approved)

        with open(log_path, "w", encoding="utf-8") as f:
            json.dump(log, f, indent=2, ensure_ascii=False)

        elapsed = time.time() - start
        print()
        print(f"  Tags written:      {log['stats']['tags_written']}")
        print(f"  Files renamed:     {log['stats']['files_renamed']}")
        print(f"  Errors:            {log['stats']['errors']}")
        print(f"  Skipped:           {log['stats']['skipped']}")
        print(f"  Time elapsed:      {elapsed:.0f}s")
        print(f"  Log:               {log_path}")
        print(f"  Backup:            {manifest_path}")
        print("=" * 70)

        if log["stats"]["errors"] > 0:
            print()
            print("ERRORS DETECTED. Review execution_log.json for details.")
            print("Use --rollback to revert all changes if needed.")


if __name__ == "__main__":
    main()
