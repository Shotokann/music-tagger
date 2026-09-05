#!/usr/bin/env python3
"""Stage 5: durably apply and roll back an approved change plan."""

import argparse
import io
import json
import os
import re
import stat
import sys
import time
from dataclasses import dataclass
from typing import Any

if sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline.config import DATA_DIR, MUSIC_DIR, REPO_ROOT, WRITABLE_EXTENSIONS
from pipeline.utils.safe_fs import (
    IdentityUnavailable,
    StrandedFileError,
    contained,
    file_identity,
    link_count,
    rename_exact,
    sha256_file,
    temp_name_for,
    validate_windows_path,
    write_json_atomic,
)
from pipeline.utils.tag_io import apply_tags, parse_track_value, read_tags, verify_container

MARKER_SCHEMA_VERSION = 2
MANIFEST_SCHEMA_VERSION = 2
RUN_ID_RE = re.compile(r"^\d{8}T\d{6}-[0-9a-f]{8}$")
FILE_ATTRIBUTE_REPARSE_POINT = 0x400
ROLLBACK_CLEAN_OUTCOMES = {"restored", "not_started", "already_restored"}


class Stage5Error(Exception):
    """A refusal caused by a failed Stage 5 safety contract."""


class JournalCorrupt(Stage5Error):
    """The journal has a malformed durable event."""


class Stage5ArgumentParser(argparse.ArgumentParser):
    """Reserve exit code 2 for completed runs with unresolved entries."""

    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        self.exit(1, f"{self.prog}: error: {message}\n")


@dataclass(frozen=True)
class Issue:
    basename: str
    reason: str


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def make_run_id(plan_sha256: str) -> str:
    return time.strftime("%Y%m%dT%H%M%S") + "-" + plan_sha256[:8]


def validate_run_id(run_id: str) -> str:
    if not RUN_ID_RE.fullmatch(run_id):
        raise Stage5Error(f"Invalid run id: {run_id!r}")
    return run_id


def _artifact_path(kind: str, run_id: str) -> str:
    validate_run_id(run_id)
    names = {
        "journal": f"journal.{run_id}.jsonl",
        "manifest": f"backup_manifest.{run_id}.json",
        "acknowledged": f"acknowledged.{run_id}.json",
    }
    return os.path.join(DATA_DIR, names[kind])


def _marker_path() -> str:
    return os.path.join(DATA_DIR, ".dry-run-complete")


def _approved_path() -> str:
    return os.path.join(DATA_DIR, "approved_plan.json")


def _load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as source:
        return json.load(source)


def _validate_marker(plan_path: str) -> dict:
    message = "Plan changed since last --dry-run. Re-run --dry-run."
    try:
        marker = _load_json(_marker_path())
    except (OSError, json.JSONDecodeError, TypeError) as error:
        raise Stage5Error(message) from error
    if (
        not isinstance(marker, dict)
        or marker.get("schema_version") != MARKER_SCHEMA_VERSION
        or marker.get("plan_sha256") != sha256_file(plan_path)
        or marker.get("plan_size") != os.path.getsize(plan_path)
    ):
        raise Stage5Error(message)
    return marker


def _active_changes(approved: dict) -> list[dict]:
    return [c for c in approved.get("changes", []) if c.get("approved") and c.get("has_changes")]


def _norm(path: str) -> str:
    return os.path.normcase(os.path.abspath(path))


def _written_values(change: dict) -> dict[str, str]:
    if os.path.splitext(change["file_path"])[1].lower() not in WRITABLE_EXTENSIONS:
        return {}
    return {key: str(diff.get("to", "")) for key, diff in change.get("tag_changes", {}).items()}


def _destination(change: dict) -> str | None:
    if not change.get("rename"):
        return None
    return os.path.join(os.path.realpath(os.path.dirname(change["file_path"])), change["rename"]["to"])


def preflight_apply(approved: dict, run_id: str | None = None) -> list[Issue]:
    """Validate every approved mutation without writing artifacts or audio files."""
    issues: list[Issue] = []
    changes = _active_changes(approved)
    identities: dict[tuple[str, str], str] = {}
    paths: dict[str, str] = {}
    destinations: dict[str, str] = {}
    source_norms = {_norm(c.get("file_path", "")) for c in changes}
    run_id = run_id or make_run_id("0" * 64)
    for change in changes:
        filepath = change.get("file_path", "")
        basename = os.path.basename(filepath) or "<unknown>"
        if not os.path.isabs(filepath):
            issues.append(Issue(basename, "file_path is not absolute"))
        if not contained(filepath, MUSIC_DIR):
            issues.append(Issue(basename, "file_path is outside MUSIC_DIR"))
        if contained(filepath, DATA_DIR) or contained(filepath, REPO_ROOT):
            issues.append(Issue(basename, "file_path is inside an artifact/source root"))
        if change.get("filename") != os.path.basename(filepath):
            issues.append(Issue(basename, "filename does not match file_path basename"))
        path_key = _norm(filepath)
        if path_key in paths:
            issues.append(Issue(basename, "duplicate file_path"))
        paths[path_key] = filepath
        try:
            source_stat = os.stat(filepath, follow_symlinks=False)
            if not stat.S_ISREG(source_stat.st_mode):
                issues.append(Issue(basename, "source is not a regular file"))
            if os.path.islink(filepath) or bool(
                getattr(source_stat, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT
            ):
                issues.append(Issue(basename, "source is a symlink or reparse point"))
        except OSError as error:
            issues.append(Issue(basename, f"source is unavailable: {error}"))
            source_stat = None
        tags = read_tags(filepath) if source_stat is not None else {"error": "unavailable"}
        if "error" in tags:
            issues.append(Issue(basename, f"tags cannot be read: {tags['error']}"))
        if source_stat is not None:
            try:
                identity = file_identity(filepath)
                if identity in identities:
                    issues.append(Issue(basename, "duplicate file identity"))
                identities[identity] = filepath
                if link_count(filepath) != 1:
                    issues.append(Issue(basename, "source has multiple hard links"))
            except (OSError, IdentityUnavailable) as error:
                issues.append(Issue(basename, f"file identity unavailable: {error}"))
        ext = os.path.splitext(filepath)[1].lower()
        tag_changes = change.get("tag_changes") or {}
        if change.get("can_write_tags") and ext not in WRITABLE_EXTENSIONS:
            issues.append(Issue(basename, f"plan marks unsupported {ext} tags writable"))
        if tag_changes and ext in WRITABLE_EXTENSIONS:
            for key in ("track", "disc"):
                if key in tag_changes and tag_changes[key].get("to"):
                    try:
                        parse_track_value(str(tag_changes[key]["to"]))
                    except Exception as error:
                        issues.append(Issue(basename, f"invalid {key} value: {error}"))
        rename = change.get("rename")
        if not rename:
            continue
        target_name = rename.get("to", "")
        if (
            not target_name or target_name in (".", "..")
            or target_name != os.path.basename(target_name)
            or "/" in target_name or "\\" in target_name
        ):
            issues.append(Issue(basename, "rename.to is not a bare basename"))
            continue
        dst = _destination(change)
        if not contained(dst, MUSIC_DIR) or contained(dst, DATA_DIR) or contained(dst, REPO_ROOT):
            issues.append(Issue(basename, "rename destination violates containment"))
        for violation in validate_windows_path(dst):
            issues.append(Issue(basename, f"invalid destination: {violation}"))
        tmp_path = temp_name_for(dst, run_id)
        for violation in validate_windows_path(tmp_path):
            issues.append(Issue(basename, f"invalid temporary path: {violation}"))
        dst_key = _norm(dst)
        if dst_key in destinations:
            issues.append(Issue(basename, "duplicate rename destination"))
        destinations[dst_key] = filepath
        if dst_key in source_norms and dst_key != path_key:
            issues.append(Issue(basename, "rename chain or source collision"))
        if os.path.exists(dst):
            try:
                same = os.path.samefile(filepath, dst)
            except OSError:
                same = False
            if not same:
                issues.append(Issue(basename, "rename destination already exists"))
        if os.path.exists(tmp_path):
            issues.append(Issue(basename, "temporary rename path already exists"))
    return issues


def _print_issues(issues: list[Issue]) -> None:
    print("ERROR: Stage 5 preflight failed:")
    for issue in issues:
        print(f"  {issue.basename}: {issue.reason}")


class JournalWriter:
    """Append newline-delimited events with a durability boundary per event."""

    def __init__(self, path: str, exclusive: bool = False):
        self._file = open(path, "x" if exclusive else "a", encoding="utf-8", newline="\n")

    def append(self, event: dict) -> None:
        json.dump(event, self._file, ensure_ascii=False, separators=(",", ":"))
        self._file.write("\n")
        self._file.flush()
        os.fsync(self._file.fileno())

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self._file.close()


def read_journal(path: str) -> list[dict]:
    """Read events, tolerating only a malformed truncated trailing line."""
    with open(path, "rb") as source:
        raw = source.read()
    events = []
    lines = raw.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            event = json.loads(line.strip().decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            stripped = line.lstrip()
            if (
                index == len(lines) - 1
                and not line.endswith((b"\n", b"\r"))
                and stripped.startswith((b"{", b"["))
            ):
                break
            raise JournalCorrupt(f"Malformed journal event in {path}") from error
        if not isinstance(event, dict) or "event" not in event:
            raise JournalCorrupt(f"Invalid journal event in {path}")
        events.append(event)
    return events


def _run_ids() -> list[str]:
    if not os.path.isdir(DATA_DIR):
        return []
    found = set()
    patterns = [
        re.compile(r"^journal\.(.+)\.jsonl$"),
        re.compile(r"^backup_manifest\.(.+)\.json$"),
        re.compile(r"^acknowledged\.(.+)\.json$"),
    ]
    for name in os.listdir(DATA_DIR):
        for pattern in patterns:
            match = pattern.fullmatch(name)
            if match and RUN_ID_RE.fullmatch(match.group(1)):
                found.add(match.group(1))
    return sorted(found)


def run_state(run_id: str) -> str:
    if os.path.exists(_artifact_path("acknowledged", run_id)):
        return "acknowledged"
    journal_path = _artifact_path("journal", run_id)
    manifest_path = _artifact_path("manifest", run_id)
    if not os.path.exists(journal_path):
        return "open" if os.path.exists(manifest_path) else "missing"
    try:
        events = read_journal(journal_path)
    except JournalCorrupt:
        return "open"
    if events and events[-1].get("event") in ("run_end", "rollback_end") and events[-1].get("unresolved") == 0:
        return "closed"
    return "open"


def _ensure_no_open_runs() -> None:
    open_runs = [run_id for run_id in _run_ids() if run_state(run_id) == "open"]
    if open_runs:
        run_id = open_runs[0]
        raise Stage5Error(
            f"Run {run_id} is open. Use --rollback --run-id {run_id}, or "
            f"--acknowledge-run {run_id} --note \"<why>\"."
        )


def execute_dry_run(approved: dict) -> dict:
    log = {"mode": "dry_run", "entries": [], "stats": {"would_tag": 0, "would_rename": 0, "would_skip": 0}}
    for change in approved.get("changes", []):
        if not change.get("approved") or not change.get("has_changes"):
            log["stats"]["would_skip"] += 1
            continue
        actions = []
        if _written_values(change):
            log["stats"]["would_tag"] += 1
            actions.append({"type": "tag_write", "changes": change["tag_changes"]})
        if change.get("rename"):
            log["stats"]["would_rename"] += 1
            actions.append({"type": "rename", **change["rename"]})
        log["entries"].append({"file_path": change["file_path"], "actions": actions})
    return log


def create_backup_manifest(approved: dict, run_id: str, plan_sha256: str) -> dict:
    entries = []
    for change in _active_changes(approved):
        filepath = change["file_path"]
        values = _written_values(change)
        dst = _destination(change)
        entries.append({
            "file_path": filepath,
            "original_filename": change["filename"],
            "planned_path": dst,
            "tmp_path": temp_name_for(dst, run_id) if dst else None,
            "file_id": list(file_identity(filepath)),
            "size": os.stat(filepath, follow_symlinks=False).st_size,
            "written_keys": list(values),
            "written_values": values,
            "original_tags": read_tags(filepath),
        })
    return {
        "schema_version": 2, "run_id": run_id, "plan_sha256": plan_sha256,
        "created_at": _now(), "music_dir": os.path.realpath(MUSIC_DIR), "entries": entries,
    }


def _tags_equal(tags: dict, expected: dict, keys: list[str]) -> bool:
    return all(str(tags.get(k, "")) == str(expected.get(k, "")) for k in keys)


def _result_event(
    entry_id: int,
    outcome: str,
    path: str | None,
    mode: str = "apply",
    size_before: int | None = None,
) -> dict:
    size_after, container_ok = None, False
    if path and os.path.isfile(path):
        try:
            size_after, container_ok = os.path.getsize(path), verify_container(path)
        except OSError:
            pass
    event = {
        "event": "result", "mode": mode, "entry_id": entry_id, "outcome": outcome,
        "final_path": path, "size_after": size_after, "container_ok": container_ok,
    }
    if size_before is not None:
        event["size_before"] = size_before
    return event


def execute_apply(manifest: dict, journal: JournalWriter) -> int:
    unresolved = 0
    for entry_id, entry in enumerate(manifest["entries"]):
        path, keys, values = entry["file_path"], entry["written_keys"], entry["written_values"]
        expected_id = tuple(entry["file_id"])
        try:
            current = os.stat(path, follow_symlinks=False)
            unchanged = file_identity(path) == expected_id and current.st_size == entry["size"]
            if keys:
                unchanged = unchanged and _tags_equal(read_tags(path), entry["original_tags"], keys)
        except (OSError, IdentityUnavailable):
            unchanged = False
        if not unchanged:
            journal.append(_result_event(entry_id, "changed_since_preflight", path))
            unresolved += 1
            continue
        if keys:
            size_before = os.path.getsize(path)
            journal.append({"event": "intent", "mode": "apply", "entry_id": entry_id, "phase": "tags", "size_before": size_before})
            try:
                apply_tags(path, values, [])
            except Exception:
                journal.append(_result_event(entry_id, "tag_failed", path, size_before=size_before))
                unresolved += 1
                continue
            reread = read_tags(path)
            if "error" in reread or not _tags_equal(reread, values, keys) or not verify_container(path):
                journal.append(_result_event(entry_id, "tag_failed", path, size_before=size_before))
                unresolved += 1
                continue
            journal.append({"event": "saved", "mode": "apply", "entry_id": entry_id})
        dst = entry["planned_path"]
        if dst:
            try:
                unchanged = file_identity(path) == expected_id
                if not keys:
                    unchanged = unchanged and os.path.getsize(path) == entry["size"]
            except (OSError, IdentityUnavailable):
                unchanged = False
            if not unchanged:
                outcome = "rename_failed" if keys else "changed_since_preflight"
                journal.append(_result_event(entry_id, outcome, path))
                unresolved += 1
                continue
            journal.append({"event": "intent", "mode": "apply", "entry_id": entry_id, "phase": "rename", "size_before": os.path.getsize(path), "tmp_path": entry["tmp_path"]})
            try:
                path = rename_exact(path, dst, manifest["run_id"])
            except StrandedFileError as error:
                journal.append(_result_event(entry_id, "stranded", error.tmp_path))
                unresolved += 1
                continue
            except BaseException:
                journal.append(_result_event(entry_id, "rename_failed", path))
                unresolved += 1
                continue
        journal.append(_result_event(entry_id, "applied", path))
        time.sleep(0.02)
    journal.append({"event": "run_end", "unresolved": unresolved})
    return unresolved


def _latest(events: list[dict], mode: str) -> dict[int, dict]:
    result = {}
    for event in events:
        if event.get("mode", "apply") == mode and isinstance(event.get("entry_id"), int):
            result[event["entry_id"]] = event
    return result


def _validate_manifest(manifest: dict, events: list[dict]) -> None:
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 2:
        raise Stage5Error("Legacy or unsupported backup manifest; schema_version 2 is required.")
    if not isinstance(manifest.get("music_dir"), str) or manifest.get("music_dir") != os.path.realpath(MUSIC_DIR):
        raise Stage5Error("Manifest music_dir does not match the current MUSIC_DIR.")
    if not isinstance(manifest.get("entries"), list):
        raise Stage5Error("Manifest entries must be a list.")
    root = manifest["music_dir"]
    for entry in manifest["entries"]:
        if not isinstance(entry, dict):
            raise Stage5Error("Manifest contains a non-object entry.")
        filepath, original = entry.get("file_path"), entry.get("original_filename", "")
        if (
            not isinstance(filepath, str)
            or not os.path.isabs(filepath)
            or not isinstance(original, str)
            or original != os.path.basename(filepath)
            or original in (".", "..")
            or original != os.path.basename(original)
            or "/" in original
            or "\\" in original
        ):
            raise Stage5Error("Manifest contains an invalid original filename.")
        for key in ("file_path", "planned_path", "tmp_path"):
            path = entry.get(key)
            if path is not None and not isinstance(path, str):
                raise Stage5Error(f"Manifest {key} is not a path string.")
            if path and (not os.path.isabs(path) or not contained(path, root)):
                raise Stage5Error(f"Manifest {key} is outside MUSIC_DIR.")
        file_id = entry.get("file_id")
        if (
            not isinstance(file_id, list)
            or len(file_id) != 2
            or not all(isinstance(part, str) and part for part in file_id)
        ):
            raise Stage5Error("Manifest contains an invalid file_id.")
        if not isinstance(entry.get("size"), int) or entry["size"] < 0:
            raise Stage5Error("Manifest contains an invalid file size.")
        written_keys = entry.get("written_keys")
        written_values = entry.get("written_values")
        if (
            not isinstance(written_keys, list)
            or not all(isinstance(key, str) for key in written_keys)
            or len(set(written_keys)) != len(written_keys)
            or not isinstance(written_values, dict)
            or set(written_values) != set(written_keys)
            or not all(isinstance(value, str) for value in written_values.values())
        ):
            raise Stage5Error("Manifest contains invalid written tag data.")
        if not isinstance(entry.get("original_tags"), dict):
            raise Stage5Error("Manifest contains invalid original_tags.")
    for event in events:
        for key in ("final_path", "tmp_path"):
            if event.get(key) is None:
                continue
            event_path = event[key]
            if (
                not isinstance(event_path, str)
                or not os.path.isabs(event_path)
                or not contained(event_path, root)
            ):
                raise Stage5Error(f"Journal {key} is outside MUSIC_DIR.")


def _resolve(entry: dict, event: dict | None) -> tuple[str | None, str]:
    event_candidates = []
    if event:
        event_candidates = [event.get("final_path"), event.get("tmp_path")]
    candidates = event_candidates + [
        entry.get("tmp_path"), entry.get("planned_path"), entry["file_path"]
    ]
    matches = []
    for path in candidates:
        if path and os.path.isfile(path):
            try:
                if file_identity(path) == tuple(entry["file_id"]):
                    matches.append(path)
            except (OSError, IdentityUnavailable):
                pass
    if not matches:
        return None, "not_found"
    try:
        if any(not os.path.samefile(matches[0], path) for path in matches[1:]):
            return None, "not_found"
        if link_count(matches[0]) != 1:
            return matches[0], "hardlinked"
    except OSError:
        return None, "not_found"
    return matches[0], "resolved"


def _uncertain(path: str, keys: list[str], before: dict, after: dict, size_before: int | None) -> str:
    tags = read_tags(path)
    ok = "error" not in tags and verify_container(path)
    try:
        size = os.path.getsize(path)
    except OSError:
        return "manual_review"
    if ok and _tags_equal(tags, before, keys) and size == size_before:
        return "before"
    if ok and _tags_equal(tags, after, keys):
        return "after"
    return "manual_review"


def _decision(entry: dict, apply_event: dict | None, rollback_event: dict | None, path: str) -> tuple[str, bool, bool]:
    keys = entry["written_keys"]
    if _apply_not_started(apply_event):
        return "not_started", False, False
    if keys and ((apply_event.get("event") == "intent" and apply_event.get("phase") == "tags") or (apply_event.get("event") == "result" and apply_event.get("outcome") == "tag_failed")):
        state = _uncertain(path, keys, entry["original_tags"], entry["written_values"], apply_event.get("size_before"))
        if state == "before":
            return "not_started", False, False
        if state == "manual_review":
            return "manual_review", False, False
    needs_tags = bool(keys)
    if rollback_event:
        if rollback_event.get("event") == "result" and rollback_event.get("outcome") in (
            "restored", "already_restored"
        ):
            return "already_restored", False, False
        uncertain = keys and ((rollback_event.get("event") == "intent" and rollback_event.get("phase") == "tags") or (rollback_event.get("event") == "result" and rollback_event.get("outcome") == "tag_restore_failed"))
        if uncertain:
            state = _uncertain(path, keys, entry["written_values"], entry["original_tags"], rollback_event.get("size_before"))
            if state == "manual_review":
                return "manual_review", False, False
            needs_tags = state == "before"
        elif rollback_event.get("event") in ("saved", "intent") or (rollback_event.get("event") == "result" and rollback_event.get("outcome") == "rename_back_failed"):
            if keys and not _tags_equal(read_tags(path), entry["original_tags"], keys):
                return "externally_modified", False, False
            needs_tags = False
    if needs_tags and not _tags_equal(read_tags(path), entry["written_values"], keys):
        return "externally_modified", False, False
    return "restore", needs_tags, os.path.basename(path) != entry["original_filename"]


def _apply_not_started(apply_event: dict | None) -> bool:
    """Return whether the journal proves apply performed no mutation."""
    return apply_event is None or (
        apply_event.get("event") == "result"
        and apply_event.get("outcome") in ("skipped", "changed_since_preflight")
    )


def _rollback_preflight(manifest: dict, events: list[dict]) -> list[Issue]:
    issues, targets = [], {}
    apply_latest, rollback_latest = _latest(events, "apply"), _latest(events, "rollback")
    for entry_id, entry in enumerate(manifest["entries"]):
        apply_event = apply_latest.get(entry_id)
        if _apply_not_started(apply_event):
            continue
        path, resolution = _resolve(
            entry, rollback_latest.get(entry_id) or apply_event
        )
        if resolution != "resolved" or not path:
            continue
        outcome, _, rename = _decision(
            entry, apply_event, rollback_latest.get(entry_id), path
        )
        if outcome != "restore" or not rename:
            continue
        target = os.path.join(os.path.dirname(path), entry["original_filename"])
        key = _norm(target)
        if key in targets and targets[key] != entry_id:
            issues.append(Issue(entry["original_filename"], "intra-manifest rename-back collision"))
        targets[key] = entry_id
        if os.path.exists(target):
            try:
                same = os.path.samefile(path, target)
            except OSError:
                same = False
            if not same:
                issues.append(Issue(entry["original_filename"], "rename-back destination is occupied"))
    return issues


def _guard(path: str, entry: dict) -> str:
    try:
        if file_identity(path) != tuple(entry["file_id"]):
            return "not_found"
        if link_count(path) != 1:
            return "hardlinked"
    except (OSError, IdentityUnavailable):
        return "not_found"
    return "ok"


def execute_rollback(manifest: dict, events: list[dict], journal: JournalWriter | None, preview: bool = False) -> tuple[int, list[dict]]:
    unresolved, previews = 0, []
    apply_latest, rollback_latest = _latest(events, "apply"), _latest(events, "rollback")
    if journal:
        journal.append({"event": "rollback_start"})
    for entry_id, entry in enumerate(manifest["entries"]):
        apply_event = apply_latest.get(entry_id)
        if _apply_not_started(apply_event):
            path = None
            outcome, needs_tags, needs_rename = "not_started", False, False
        else:
            path, resolution = _resolve(
                entry, rollback_latest.get(entry_id) or apply_event
            )
            if resolution != "resolved" or not path:
                outcome, needs_tags, needs_rename = resolution, False, False
            else:
                outcome, needs_tags, needs_rename = _decision(
                    entry, apply_event, rollback_latest.get(entry_id), path
                )
        item = {"entry_id": entry_id, "path": path, "verdict": outcome, "set": {}, "delete": [], "rename_to": None}
        if outcome == "restore" and path:
            original = entry["original_tags"]
            if needs_tags:
                item["set"] = {k: str(original.get(k, "")) for k in entry["written_keys"] if original.get(k, "")}
                item["delete"] = [] if "error" in original else [k for k in entry["written_keys"] if not original.get(k, "")]
            if needs_rename:
                item["rename_to"] = os.path.join(os.path.dirname(path), entry["original_filename"])
        previews.append(item)
        if preview:
            if outcome not in ROLLBACK_CLEAN_OUTCOMES and outcome != "restore":
                unresolved += 1
            continue
        if outcome != "restore":
            journal.append(_result_event(entry_id, outcome, path, "rollback"))
            if outcome not in ROLLBACK_CLEAN_OUTCOMES:
                unresolved += 1
            continue
        if needs_tags:
            guard = _guard(path, entry)
            if guard != "ok":
                journal.append(_result_event(entry_id, guard, path, "rollback"))
                unresolved += 1
                continue
            size_before = os.path.getsize(path)
            journal.append({"event": "intent", "mode": "rollback", "entry_id": entry_id, "phase": "tags", "size_before": size_before})
            try:
                apply_tags(path, item["set"], item["delete"])
            except Exception:
                journal.append(_result_event(
                    entry_id, "tag_restore_failed", path, "rollback", size_before
                ))
                unresolved += 1
                continue
            reread = read_tags(path)
            if "error" in reread or not _tags_equal(reread, entry["original_tags"], entry["written_keys"]) or not verify_container(path):
                journal.append(_result_event(
                    entry_id, "tag_restore_failed", path, "rollback", size_before
                ))
                unresolved += 1
                continue
            journal.append({"event": "saved", "mode": "rollback", "entry_id": entry_id})
        if needs_rename:
            guard = _guard(path, entry)
            if guard != "ok":
                journal.append(_result_event(entry_id, guard, path, "rollback"))
                unresolved += 1
                continue
            target = item["rename_to"]
            journal.append({"event": "intent", "mode": "rollback", "entry_id": entry_id, "phase": "rename", "size_before": os.path.getsize(path), "tmp_path": temp_name_for(target, manifest["run_id"])})
            try:
                path = rename_exact(path, target, manifest["run_id"])
            except BaseException:
                journal.append(_result_event(entry_id, "rename_back_failed", path, "rollback"))
                unresolved += 1
                continue
        journal.append(_result_event(entry_id, "restored", path, "rollback"))
    if journal:
        journal.append({"event": "rollback_end", "unresolved": unresolved})
    return unresolved, previews


def _load_approved() -> tuple[str, dict]:
    path = _approved_path()
    if not os.path.isfile(path):
        raise Stage5Error("approved_plan.json not found. Run stage4_validate.py first.")
    return path, _load_json(path)


def _run_dry_run() -> int:
    plan_path, approved = _load_approved()
    digest, run_id = sha256_file(plan_path), make_run_id(sha256_file(plan_path))
    issues = preflight_apply(approved, run_id)
    if issues:
        _print_issues(issues)
        return 1
    log = execute_dry_run(approved)
    os.makedirs(DATA_DIR, exist_ok=True)
    write_json_atomic(os.path.join(DATA_DIR, "dry_run_log.json"), log)
    write_json_atomic(_marker_path(), {"schema_version": 2, "plan_sha256": digest, "plan_size": os.path.getsize(plan_path), "created_at": _now()})
    print(f"Stage 5 dry run passed for {len(log['entries'])} active entries.")
    print("Run with --apply to execute this exact plan.")
    return 0


def _run_apply() -> int:
    plan_path, approved = _load_approved()
    _ensure_no_open_runs()
    marker = _validate_marker(plan_path)
    run_id = make_run_id(marker["plan_sha256"])
    journal_path, manifest_path = _artifact_path("journal", run_id), _artifact_path("manifest", run_id)
    if (
        os.path.exists(journal_path)
        or os.path.exists(manifest_path)
        or os.path.exists(_artifact_path("acknowledged", run_id))
    ):
        raise Stage5Error(f"Run id {run_id} already has artifacts; retry in a later second.")
    issues = preflight_apply(approved, run_id)
    if issues:
        _print_issues(issues)
        return 1
    manifest = create_backup_manifest(approved, run_id, marker["plan_sha256"])
    print(f"Run id: {run_id}")
    with JournalWriter(journal_path, exclusive=True) as journal:
        journal.append({"event": "run_start", "run_id": run_id, "plan_sha256": marker["plan_sha256"], "created_at": _now()})
        write_json_atomic(manifest_path, manifest)
        os.remove(_marker_path())
        unresolved = execute_apply(manifest, journal)
    print(f"Rollback: python -m pipeline.stage5_execute --rollback --run-id {run_id}")
    print(f"Run id: {run_id}; unresolved: {unresolved}")
    return 0 if unresolved == 0 else 2


def _run_rollback(run_id: str | None, preview: bool) -> int:
    if run_id is None:
        print("ERROR: --rollback requires --run-id. Available runs:")
        for found in _run_ids():
            print(f"  {found}: {run_state(found)}")
        return 1
    validate_run_id(run_id)
    if os.path.exists(_artifact_path("acknowledged", run_id)):
        raise Stage5Error("Acknowledged runs are frozen and cannot be rolled back.")
    journal_path, manifest_path = _artifact_path("journal", run_id), _artifact_path("manifest", run_id)
    if not os.path.exists(journal_path):
        raise Stage5Error("Run journal not found.")
    events = read_journal(journal_path)
    if not os.path.exists(manifest_path):
        if any(event.get("event") == "intent" for event in events):
            raise Stage5Error("Manifest missing for a run that reached mutation intent.")
        if preview:
            print("Zero-intent run; rollback would close it without file changes.")
            return 0
        with JournalWriter(journal_path) as journal:
            journal.append({"event": "rollback_start"})
            journal.append({"event": "rollback_end", "unresolved": 0})
        return 0
    manifest = _load_json(manifest_path)
    if not isinstance(manifest, dict) or manifest.get("run_id") != run_id:
        raise Stage5Error("Manifest run_id does not match the requested run.")
    _validate_manifest(manifest, events)
    issues = _rollback_preflight(manifest, events)
    if issues:
        _print_issues(issues)
        return 1
    if preview:
        unresolved, entries = execute_rollback(manifest, events, None, True)
        for entry in entries:
            print(f"[{entry['entry_id']}] {entry['verdict']}: {entry['path']} set={entry['set']} delete={entry['delete']} rename={entry['rename_to']}")
        return 0 if unresolved == 0 else 2
    with JournalWriter(journal_path) as journal:
        unresolved, _ = execute_rollback(manifest, events, journal)
    print(f"Rollback {run_id} finished; unresolved: {unresolved}")
    return 0 if unresolved == 0 else 2


def _acknowledge(run_id: str, note: str | None) -> int:
    validate_run_id(run_id)
    if not note or not note.strip():
        raise Stage5Error("--acknowledge-run requires a non-empty --note.")
    if run_state(run_id) == "missing":
        raise Stage5Error(f"Run {run_id} does not exist.")
    write_json_atomic(_artifact_path("acknowledged", run_id), {"note": note.strip(), "created_at": _now()})
    print(f"Acknowledged run {run_id}.")
    return 0


def main(argv: list[str] | None = None) -> None:
    parser = Stage5ArgumentParser(description="Stage 5: Execute approved changes safely")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--apply", action="store_true")
    group.add_argument("--rollback", action="store_true")
    group.add_argument("--acknowledge-run", metavar="RUN_ID")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--run-id")
    parser.add_argument("--note")
    args = parser.parse_args(argv)
    try:
        if args.apply and args.dry_run:
            raise Stage5Error("--dry-run cannot be combined with --apply.")
        if args.acknowledge_run:
            if args.dry_run or args.run_id:
                raise Stage5Error("Invalid option combination for --acknowledge-run.")
            code = _acknowledge(args.acknowledge_run, args.note)
        elif args.rollback:
            if args.note:
                raise Stage5Error("--note is only valid with --acknowledge-run.")
            code = _run_rollback(args.run_id, args.dry_run)
        elif args.apply:
            if args.run_id or args.note:
                raise Stage5Error("--run-id/--note are not valid with --apply.")
            code = _run_apply()
        elif args.dry_run:
            if args.run_id or args.note:
                raise Stage5Error("--run-id/--note are not valid for plan dry-run.")
            code = _run_dry_run()
        else:
            raise Stage5Error("Choose --dry-run, --apply, --rollback, or --acknowledge-run.")
    except (Stage5Error, json.JSONDecodeError, OSError) as error:
        print(f"ERROR: {error}")
        code = 1
    raise SystemExit(code)


if __name__ == "__main__":
    main()
