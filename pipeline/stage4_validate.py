#!/usr/bin/env python3
"""
Stage 4: Validation Report
Generates a human/AI-readable validation report from the change plan.
Output: data/validation_report.txt + data/approved_plan.json
"""

import io
import json
import os
import sys

if sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline.config import DATA_DIR


def generate_report(plan: dict) -> str:
    """Generate a text validation report."""
    lines = []
    changes = plan["changes"]
    stats = plan["stats"]

    lines.append("=" * 70)
    lines.append("VALIDATION REPORT - Music Library Tag & Rename Pipeline")
    lines.append("=" * 70)
    lines.append("")

    # Section 1: Summary
    lines.append("## SUMMARY")
    lines.append(f"  Total files:        {stats['total_files']}")
    total_changes = stats['has_tag_changes'] + stats['has_rename'] + stats['has_both']
    lines.append(f"  Files with changes: {total_changes}")
    lines.append(f"    Tag changes only: {stats['has_tag_changes']}")
    lines.append(f"    Rename only:      {stats['has_rename']}")
    lines.append(f"    Both:             {stats['has_both']}")
    lines.append(f"  No change needed:   {stats['no_change']}")
    lines.append(f"  Skipped (DRM):      {stats['skipped_drm']}")
    lines.append(f"  Confidence: high={stats['confidence_high']} medium={stats['confidence_medium']} low={stats['confidence_low']}")
    lines.append("")

    # Section 2: High-risk changes (low confidence or large renames)
    lines.append("## HIGH-RISK CHANGES (need review)")
    lines.append("")
    high_risk = [c for c in changes if c["confidence"] == "low" and c["has_changes"]]
    if high_risk:
        # Group by album
        albums = {}
        for c in high_risk:
            ak = c["album_key"]
            if ak not in albums:
                albums[ak] = []
            albums[ak].append(c)

        for ak, items in sorted(albums.items()):
            lines.append(f"  [{ak}] ({len(items)} files)")
            for c in items[:5]:  # Show first 5
                if c["rename"]:
                    lines.append(f"    RENAME: {c['rename']['from']}")
                    lines.append(f"         -> {c['rename']['to']}")
                if c["tag_changes"]:
                    for tag, diff in c["tag_changes"].items():
                        if diff["from"] != diff["to"]:
                            lines.append(f"    {tag}: \"{diff['from']}\" -> \"{diff['to']}\"")
            if len(items) > 5:
                lines.append(f"    ... and {len(items) - 5} more files")
            lines.append("")
    else:
        lines.append("  None - all changes are medium or high confidence.")
        lines.append("")

    # Section 3: Sample changes by album (first 3 per album for matched albums)
    lines.append("## SAMPLE CHANGES BY ALBUM")
    lines.append("")

    albums_with_changes = {}
    for c in changes:
        if c["has_changes"] and c["confidence"] != "low":
            ak = c["album_key"]
            if ak not in albums_with_changes:
                albums_with_changes[ak] = []
            albums_with_changes[ak].append(c)

    for ak in sorted(albums_with_changes.keys())[:50]:  # Cap at 50 albums
        items = albums_with_changes[ak]
        lines.append(f"  [{ak}] ({len(items)} changes)")
        for c in items[:3]:
            parts = []
            if c["rename"]:
                parts.append(f"RENAME: {c['rename']['from']} -> {c['rename']['to']}")
            for tag, diff in c.get("tag_changes", {}).items():
                if tag in ("title", "album") and diff["from"] != diff["to"]:
                    parts.append(f"{tag}: \"{diff['from'][:40]}\" -> \"{diff['to'][:40]}\"")
            if parts:
                lines.append(f"    {' | '.join(parts)}")
        if len(items) > 3:
            lines.append(f"    ... and {len(items) - 3} more")
        lines.append("")

    # Section 4: DRM files
    drm_files = [c for c in changes if c.get("extension") == ".m4p"]
    if drm_files:
        lines.append(f"## DRM FILES ({len(drm_files)} files - cannot modify)")
        lines.append("")
        for c in drm_files[:10]:
            lines.append(f"  {c['filename']} ({c['album_key']})")
        if len(drm_files) > 10:
            lines.append(f"  ... and {len(drm_files) - 10} more")
        lines.append("")

    # Section 5: Rename collision check
    lines.append("## RENAME COLLISION CHECK")
    rename_targets = {}
    collisions = 0
    for c in changes:
        if c["rename"]:
            dir_path = os.path.dirname(c["file_path"])
            target = os.path.join(dir_path, c["rename"]["to"])
            if target in rename_targets:
                collisions += 1
                lines.append(f"  COLLISION: {c['rename']['to']} in {dir_path}")
                lines.append(f"    Source 1: {rename_targets[target]}")
                lines.append(f"    Source 2: {c['rename']['from']}")
            else:
                rename_targets[target] = c["rename"]["from"]
    if collisions == 0:
        lines.append("  No collisions detected.")
    lines.append("")

    lines.append("=" * 70)
    lines.append("END OF VALIDATION REPORT")
    lines.append("=" * 70)

    return "\n".join(lines)


def create_approved_plan(plan: dict) -> dict:
    """
    Create approved plan. Auto-approve high/medium confidence, flag low for review.
    """
    approved = []
    for c in plan["changes"]:
        entry = dict(c)
        if c["confidence"] in ("high", "medium") and c["has_changes"]:
            entry["approved"] = True
        elif not c["has_changes"]:
            entry["approved"] = False  # nothing to do
        else:
            entry["approved"] = False  # low confidence - needs manual approval
        approved.append(entry)

    return {"changes": approved, "stats": plan["stats"]}


def main():
    # Load change plan
    plan_path = os.path.join(DATA_DIR, "change_plan.json")
    if not os.path.exists(plan_path):
        print("ERROR: change_plan.json not found. Run stage3_plan.py first.")
        sys.exit(1)

    with open(plan_path, "r", encoding="utf-8") as f:
        plan = json.load(f)

    # Generate report
    report = generate_report(plan)

    report_path = os.path.join(DATA_DIR, "validation_report.txt")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report)

    print(report)
    print()
    print(f"Report saved to: {report_path}")

    # Create approved plan (auto-approve high/medium confidence)
    approved = create_approved_plan(plan)
    approved_path = os.path.join(DATA_DIR, "approved_plan.json")
    with open(approved_path, "w", encoding="utf-8") as f:
        json.dump(approved, f, indent=2, ensure_ascii=False)

    auto_approved = sum(1 for c in approved["changes"] if c["approved"])
    needs_review = sum(1 for c in approved["changes"]
                       if not c["approved"] and c["has_changes"])
    print(f"Auto-approved: {auto_approved} changes")
    print(f"Needs review:  {needs_review} changes (low confidence)")
    print(f"Approved plan: {approved_path}")


if __name__ == "__main__":
    main()
