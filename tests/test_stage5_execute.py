import builtins
import hashlib
import json
import os

import pytest

from pipeline import stage5_execute as stage5
from pipeline.utils.safe_fs import file_identity
from pipeline.utils.tag_io import read_tags
from tests.fixtures_audio import make_m4a, make_mp3


RUN_ID = "20260904T120000-deadbeef"


def configure_roots(tmp_path, monkeypatch):
    music = tmp_path / "music"
    data = tmp_path / "data"
    repo = tmp_path / "repo"
    music.mkdir()
    data.mkdir()
    repo.mkdir()
    monkeypatch.setattr(stage5, "MUSIC_DIR", str(music))
    monkeypatch.setattr(stage5, "DATA_DIR", str(data))
    monkeypatch.setattr(stage5, "REPO_ROOT", str(repo))
    return music, data


def change_for(path, *, title="New", rename=None, approved=True):
    return {
        "file_path": str(path),
        "filename": path.name,
        "has_changes": bool(title or rename),
        "approved": approved,
        "can_write_tags": path.suffix.lower() in {".mp3", ".m4a"},
        "tag_changes": {"title": {"from": "Old", "to": title}} if title else {},
        "rename": {"from": path.name, "to": rename} if rename else None,
    }


def write_plan(data, changes):
    path = data / "approved_plan.json"
    path.write_text(json.dumps({"changes": changes}), encoding="utf-8")
    return path


def invoke(*args):
    with pytest.raises(SystemExit) as caught:
        stage5.main(list(args))
    return caught.value.code


def journal_events(data, run_id):
    return stage5.read_journal(str(data / f"journal.{run_id}.jsonl"))


def test_dry_run_writes_bound_json_marker(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    plan = write_plan(data, [change_for(source)])

    assert invoke("--dry-run") == 0

    marker = json.loads((data / ".dry-run-complete").read_text(encoding="utf-8"))
    assert marker["schema_version"] == 2
    assert marker["plan_sha256"] == hashlib.sha256(plan.read_bytes()).hexdigest()
    assert marker["plan_size"] == plan.stat().st_size
    assert (data / "dry_run_log.json").exists()


@pytest.mark.parametrize("marker", ["legacy timestamp", None])
def test_apply_refuses_legacy_or_missing_marker(tmp_path, monkeypatch, marker):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    if marker is not None:
        (data / ".dry-run-complete").write_text(marker, encoding="utf-8")
    assert invoke("--apply") == 1
    assert read_tags(str(source))["title"] == "Old"
    assert not list(data.glob("journal.*.jsonl"))


def test_apply_refuses_plan_changed_after_dry_run(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    plan = write_plan(data, [change_for(source)])
    assert invoke("--dry-run") == 0
    plan.write_text(plan.read_text(encoding="utf-8") + " ", encoding="utf-8")
    assert invoke("--apply") == 1
    assert not list(data.glob("journal.*.jsonl"))


def test_apply_and_rollback_round_trip_tags_name_and_identity(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "Old Name.mp3", title="Old", year="2020")
    identity = file_identity(str(source))
    write_plan(data, [change_for(source, rename="New Name.mp3")])

    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    manifests = list(data.glob("backup_manifest.*.json"))
    assert len(manifests) == 1
    manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
    run_id = manifest["run_id"]
    renamed = music / "New Name.mp3"
    assert renamed.exists() and not source.exists()
    assert read_tags(str(renamed))["title"] == "New"
    assert not (data / ".dry-run-complete").exists()
    assert manifest["entries"][0]["file_id"] == list(identity)
    assert manifest["entries"][0]["written_keys"] == ["title"]
    assert manifest["entries"][0]["written_values"] == {"title": "New"}
    assert not (data / "backup_manifest.json").exists()
    assert not (data / "execution_log.json").exists()

    assert invoke("--rollback", "--run-id", run_id, "--dry-run") == 0
    assert renamed.exists()
    assert invoke("--rollback", "--run-id", run_id) == 0
    assert source.exists() and not renamed.exists()
    tags = read_tags(str(source))
    assert tags["title"] == "Old"
    assert tags["year"] == "2020"
    assert file_identity(str(source)) == identity
    assert journal_events(data, run_id)[-1] == {"event": "rollback_end", "unresolved": 0}


def test_rename_only_never_calls_apply_tags_during_apply_or_rollback(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "old.mp3", title="Keep")
    write_plan(data, [change_for(source, title=None, rename="new.mp3")])
    calls = 0
    real_apply = stage5.apply_tags

    def spy(*args, **kwargs):
        nonlocal calls
        calls += 1
        return real_apply(*args, **kwargs)

    monkeypatch.setattr(stage5, "apply_tags", spy)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    manifest_path = next(data.glob("backup_manifest.*.json"))
    run_id = json.loads(manifest_path.read_text(encoding="utf-8"))["run_id"]
    assert invoke("--rollback", "--run-id", run_id) == 0
    assert calls == 0
    assert source.exists()


def test_preflight_rejects_missing_hardlinked_wav_and_collision(tmp_path, monkeypatch):
    music, _ = configure_roots(tmp_path, monkeypatch)
    missing = music / "missing.mp3"
    first = make_mp3(music / "first.mp3", title="Old")
    os.link(first, music / "linked.mp3")
    wav = music / "audio.wav"
    wav.write_bytes(b"RIFF")
    collision = make_mp3(music / "occupied.mp3", title="Other")
    changes = [
        change_for(missing),
        change_for(first),
        {**change_for(wav), "can_write_tags": True},
        change_for(collision, title=None, rename="first.mp3"),
    ]
    reasons = [issue.reason for issue in stage5.preflight_apply({"changes": changes}, RUN_ID)]
    assert any("unavailable" in reason for reason in reasons)
    assert any("hard links" in reason for reason in reasons)
    assert any("unsupported .wav" in reason for reason in reasons)
    assert any("already exists" in reason for reason in reasons)


def test_preflight_failure_writes_no_artifacts_or_tags(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source, rename="CON.mp3")])
    before = source.stat().st_mtime_ns
    assert invoke("--dry-run") == 1
    assert source.stat().st_mtime_ns == before
    assert read_tags(str(source))["title"] == "Old"
    assert not (data / ".dry-run-complete").exists()


def test_changed_since_preflight_is_journaled_and_rename_skipped(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source, rename="renamed.mp3")])
    assert invoke("--dry-run") == 0
    real_create = stage5.create_backup_manifest

    def create_then_change(*args, **kwargs):
        manifest = real_create(*args, **kwargs)
        with open(source, "ab") as output:
            output.write(b"changed")
        return manifest

    monkeypatch.setattr(stage5, "create_backup_manifest", create_then_change)
    assert invoke("--apply") == 2
    run_id = json.loads(next(data.glob("backup_manifest.*.json")).read_text(encoding="utf-8"))["run_id"]
    results = [e for e in journal_events(data, run_id) if e["event"] == "result"]
    assert results[-1]["outcome"] == "changed_since_preflight"
    assert source.exists() and not (music / "renamed.mp3").exists()


def test_empty_and_journal_only_runs_close_without_manifest(tmp_path, monkeypatch):
    _, data = configure_roots(tmp_path, monkeypatch)
    empty = data / f"journal.{RUN_ID}.jsonl"
    empty.write_bytes(b"")
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert journal_events(data, RUN_ID)[-1]["event"] == "rollback_end"


def test_truncated_tail_tolerated_but_malformed_interior_is_corrupt(tmp_path):
    tail = tmp_path / "tail.jsonl"
    tail.write_bytes(b'{"event":"run_start"}\n{"event":')
    assert stage5.read_journal(str(tail)) == [{"event": "run_start"}]
    interior = tmp_path / "bad.jsonl"
    interior.write_bytes(b'{"event":"run_start"}\nnot-json\n{"event":"run_end","unresolved":0}\n')
    with pytest.raises(stage5.JournalCorrupt):
        stage5.read_journal(str(interior))
    malformed_tail = tmp_path / "bad-tail.jsonl"
    malformed_tail.write_bytes(b"not-json")
    with pytest.raises(stage5.JournalCorrupt):
        stage5.read_journal(str(malformed_tail))


def test_open_run_gate_and_acknowledgement(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    (data / f"journal.{RUN_ID}.jsonl").write_text('{"event":"run_start"}\n', encoding="utf-8")
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 1
    before = (data / f"journal.{RUN_ID}.jsonl").read_bytes()
    assert invoke("--acknowledge-run", RUN_ID, "--note", "manual inspection") == 0
    assert invoke("--rollback", "--run-id", RUN_ID) == 1
    assert (data / f"journal.{RUN_ID}.jsonl").read_bytes() == before


def test_rollback_rejects_legacy_manifest_and_bad_run_id(tmp_path, monkeypatch):
    _, data = configure_roots(tmp_path, monkeypatch)
    (data / f"journal.{RUN_ID}.jsonl").write_text('{"event":"run_start"}\n', encoding="utf-8")
    (data / f"backup_manifest.{RUN_ID}.json").write_text("[]", encoding="utf-8")
    assert invoke("--rollback", "--run-id", RUN_ID) == 1
    assert invoke("--rollback", "--run-id", "../escape") == 1


def test_no_mode_writes_legacy_artifact_names(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    real_open = builtins.open

    def guarded_open(path, mode="r", *args, **kwargs):
        if any(flag in mode for flag in "wax+") and os.path.basename(os.fspath(path)) in {
            "backup_manifest.json", "execution_log.json"
        }:
            pytest.fail("legacy artifact opened for writing")
        return real_open(path, mode, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", guarded_open)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0


def test_four_fixture_end_to_end_and_plan_edit_requires_new_dry_run(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    normal = make_mp3(music / "normal old.mp3", title="Old")
    case_only = make_mp3(music / "Case Name.mp3", title="Old")
    tag_only = make_mp3(music / "tags.mp3", title="Old")
    unapproved = make_m4a(music / "unapproved.m4a", title="Old", track="3/12")
    original = {
        path.name: read_tags(str(path))
        for path in (normal, case_only, tag_only, unapproved)
    }
    changes = [
        change_for(normal, rename="normal new.mp3"),
        change_for(case_only, rename="case name.mp3"),
        change_for(tag_only),
        change_for(unapproved, approved=False),
    ]
    plan = write_plan(data, changes)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    manifest = json.loads(next(data.glob("backup_manifest.*.json")).read_text(encoding="utf-8"))
    run_id = manifest["run_id"]
    assert invoke("--rollback", "--run-id", run_id, "--dry-run") == 0
    assert invoke("--rollback", "--run-id", run_id) == 0
    for name, expected in original.items():
        path = music / name
        assert path.exists()
        actual = read_tags(str(path))
        for key in (
            "title", "artist", "album_artist", "album", "track", "year", "disc"
        ):
            assert actual[key] == expected[key]

    payload = json.loads(plan.read_text(encoding="utf-8"))
    payload["changes"][-1]["approved"] = True
    plan.write_text(json.dumps(payload), encoding="utf-8")
    assert invoke("--apply") == 1


def test_mid_save_unknown_state_becomes_manual_review(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    assert invoke("--dry-run") == 0
    real_apply = stage5.apply_tags

    def write_different_then_fail(path, values, deletes):
        real_apply(path, {"title": "Neither"}, [])
        raise OSError("injected after save")

    monkeypatch.setattr(stage5, "apply_tags", write_different_then_fail)
    assert invoke("--apply") == 2
    manifest = json.loads(next(data.glob("backup_manifest.*.json")).read_text(encoding="utf-8"))
    monkeypatch.setattr(stage5, "apply_tags", real_apply)
    before = source.read_bytes()
    assert invoke("--rollback", "--run-id", manifest["run_id"]) == 2
    assert source.read_bytes() == before
    results = [e for e in journal_events(data, manifest["run_id"]) if e.get("mode") == "rollback" and e["event"] == "result"]
    assert results[-1]["outcome"] == "manual_review"


def test_rollback_hardlink_is_unresolved_then_retry_restores(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "old.mp3", title="Old")
    write_plan(data, [change_for(source, rename="new.mp3")])
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    manifest = json.loads(next(data.glob("backup_manifest.*.json")).read_text(encoding="utf-8"))
    renamed = music / "new.mp3"
    linked = music / "linked.mp3"
    os.link(renamed, linked)
    assert invoke("--rollback", "--run-id", manifest["run_id"]) == 2
    assert read_tags(str(renamed))["title"] == "New"
    linked.unlink()
    assert invoke("--rollback", "--run-id", manifest["run_id"]) == 0
    assert source.exists()
    assert read_tags(str(source))["title"] == "Old"


def test_rollback_deletes_originally_empty_key_and_preserves_other_tags(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old", artist="Keep")
    change = change_for(source)
    change["tag_changes"]["year"] = {"from": "", "to": "2026"}
    write_plan(data, [change])
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    manifest = json.loads(next(data.glob("backup_manifest.*.json")).read_text(encoding="utf-8"))
    assert read_tags(str(source))["year"] == "2026"
    assert invoke("--rollback", "--run-id", manifest["run_id"]) == 0
    tags = read_tags(str(source))
    assert tags["year"] == ""
    assert tags["artist"] == "Keep"


def test_second_rollback_reports_already_restored_cleanly(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    manifest = json.loads(next(data.glob("backup_manifest.*.json")).read_text(encoding="utf-8"))
    run_id = manifest["run_id"]
    assert invoke("--rollback", "--run-id", run_id) == 0
    assert invoke("--rollback", "--run-id", run_id) == 0
    assert journal_events(data, run_id)[-2]["outcome"] == "already_restored"


def test_preflight_path_schema_and_collision_failures(tmp_path, monkeypatch):
    music, _ = configure_roots(tmp_path, monkeypatch)
    one = make_mp3(music / "one.mp3", title="Old")
    two = make_mp3(music / "two.mp3", title="Old")
    malformed = music / "bad.m4a"
    malformed.write_bytes(b"not-an-mp4")
    outside = make_mp3(tmp_path / "outside.mp3", title="Old")
    changes = [
        {**change_for(one), "filename": "wrong.mp3"},
        change_for(two, title=None, rename="../escape.mp3"),
        change_for(malformed),
        change_for(outside),
        change_for(one),
        change_for(one),
    ]
    reasons = [issue.reason for issue in stage5.preflight_apply({"changes": changes}, RUN_ID)]
    assert any("filename does not match" in reason for reason in reasons)
    assert any("bare basename" in reason for reason in reasons)
    assert any("tags cannot be read" in reason for reason in reasons)
    assert any("outside MUSIC_DIR" in reason for reason in reasons)
    assert any("duplicate file_path" in reason for reason in reasons)
    assert any("duplicate file identity" in reason for reason in reasons)


def test_preflight_rejects_bad_track_duplicate_destination_and_chain(tmp_path, monkeypatch):
    music, _ = configure_roots(tmp_path, monkeypatch)
    one = make_m4a(music / "one.m4a", title="Old")
    two = make_m4a(music / "two.m4a", title="Old")
    three = make_m4a(music / "three.m4a", title="Old")
    bad = change_for(one, rename="target.m4a")
    bad["tag_changes"]["track"] = {"from": "1", "to": "abc"}
    changes = [
        bad,
        change_for(two, title=None, rename="target.m4a"),
        change_for(three, title=None, rename="two.m4a"),
    ]
    reasons = [issue.reason for issue in stage5.preflight_apply({"changes": changes}, RUN_ID)]
    assert any("invalid track" in reason for reason in reasons)
    assert any("duplicate rename destination" in reason for reason in reasons)
    assert any("rename chain" in reason for reason in reasons)


def test_journal_writer_flushes_and_fsyncs_each_event(tmp_path, monkeypatch):
    path = tmp_path / "journal.jsonl"
    calls = []
    real_fsync = stage5.os.fsync

    def fsync(fd):
        calls.append(fd)
        return real_fsync(fd)

    monkeypatch.setattr(stage5.os, "fsync", fsync)
    with stage5.JournalWriter(str(path), exclusive=True) as journal:
        journal.append({"event": "one"})
        journal.append({"event": "two"})
    assert len(calls) == 2
    assert stage5.read_journal(str(path)) == [{"event": "one"}, {"event": "two"}]


def test_closed_run_id_collision_preserves_existing_artifacts(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    journal = data / f"journal.{RUN_ID}.jsonl"
    manifest = data / f"backup_manifest.{RUN_ID}.json"
    journal.write_text('{"event":"run_end","unresolved":0}\n', encoding="utf-8")
    manifest.write_bytes(b"existing")
    before = (journal.read_bytes(), manifest.read_bytes())
    assert invoke("--apply") == 1
    assert (journal.read_bytes(), manifest.read_bytes()) == before


def test_rollback_containment_refuses_before_identity_lookup(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    outside = str(tmp_path / "outside.mp3")
    journal = data / f"journal.{RUN_ID}.jsonl"
    journal.write_text(
        json.dumps({
            "event": "result", "mode": "apply", "entry_id": 0,
            "outcome": "applied", "final_path": outside,
            "size_after": 1, "container_ok": True,
        }) + "\n",
        encoding="utf-8",
    )
    manifest = {
        "schema_version": 2,
        "run_id": RUN_ID,
        "music_dir": str(music.resolve()),
        "entries": [{
            "file_path": str(music / "song.mp3"),
            "original_filename": "song.mp3",
            "planned_path": None,
            "tmp_path": None,
            "file_id": ["1", "2"],
            "size": 1,
            "written_keys": [],
            "written_values": {},
            "original_tags": {},
        }],
    }
    (data / f"backup_manifest.{RUN_ID}.json").write_text(json.dumps(manifest), encoding="utf-8")
    monkeypatch.setattr(stage5, "file_identity", lambda path: pytest.fail("identity lookup before containment"))
    assert invoke("--rollback", "--run-id", RUN_ID) == 1


def test_rollback_preflight_occupied_destination_writes_no_start(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "old.mp3", title="Old")
    write_plan(data, [change_for(source, rename="new.mp3")])
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    manifest = json.loads(next(data.glob("backup_manifest.*.json")).read_text(encoding="utf-8"))
    make_mp3(music / "old.mp3", title="Foreign")
    journal_path = data / f"journal.{manifest['run_id']}.jsonl"
    before = journal_path.read_bytes()
    assert invoke("--rollback", "--run-id", manifest["run_id"]) == 1
    assert journal_path.read_bytes() == before


def test_manifest_run_id_mismatch_and_truncation_refuse(tmp_path, monkeypatch):
    _, data = configure_roots(tmp_path, monkeypatch)
    journal = data / f"journal.{RUN_ID}.jsonl"
    manifest = data / f"backup_manifest.{RUN_ID}.json"
    journal.write_text('{"event":"run_start"}\n', encoding="utf-8")
    manifest.write_text(json.dumps({"schema_version": 2, "run_id": "20260904T120001-deadbeef"}), encoding="utf-8")
    assert invoke("--rollback", "--run-id", RUN_ID) == 1
    manifest.write_text('{"schema_version":2', encoding="utf-8")
    assert invoke("--rollback", "--run-id", RUN_ID) == 1


@pytest.mark.parametrize("kill_at", ["empty", "run_start", "saved", "run_end"])
def test_apply_fault_points_leave_open_recoverable_run(tmp_path, monkeypatch, kill_at):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    real_append = stage5.JournalWriter.append

    def interrupted_append(self, event):
        if kill_at == "empty" and event["event"] == "run_start":
            raise KeyboardInterrupt()
        if kill_at == "run_end" and event["event"] == "run_end":
            raise KeyboardInterrupt()
        real_append(self, event)
        if kill_at == "run_start" and event["event"] == "run_start":
            raise KeyboardInterrupt()
        if kill_at == "saved" and event["event"] == "saved" and event.get("mode") == "apply":
            raise KeyboardInterrupt()

    monkeypatch.setattr(stage5.JournalWriter, "append", interrupted_append)
    with pytest.raises(KeyboardInterrupt):
        stage5.main(["--apply"])
    monkeypatch.setattr(stage5.JournalWriter, "append", real_append)
    assert stage5.run_state(RUN_ID) == "open"
    assert invoke("--apply") == 1
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert read_tags(str(source))["title"] == "Old"
    assert stage5.run_state(RUN_ID) == "closed"


def test_apply_fault_after_manifest_before_marker_delete_is_recoverable(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    real_remove = stage5.os.remove

    def interrupt_marker_remove(path):
        if os.path.normcase(path) == os.path.normcase(str(data / ".dry-run-complete")):
            raise KeyboardInterrupt()
        return real_remove(path)

    monkeypatch.setattr(stage5.os, "remove", interrupt_marker_remove)
    with pytest.raises(KeyboardInterrupt):
        stage5.main(["--apply"])
    monkeypatch.setattr(stage5.os, "remove", real_remove)
    assert (data / ".dry-run-complete").exists()
    assert invoke("--apply") == 1
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert (data / ".dry-run-complete").exists()


@pytest.mark.parametrize("after_save", [False, True])
def test_interrupted_apply_tag_save_reconciles_to_clean_rollback(tmp_path, monkeypatch, after_save):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    real_apply = stage5.apply_tags

    def interrupted(path, values, deletes):
        if after_save:
            real_apply(path, values, deletes)
        raise KeyboardInterrupt()

    monkeypatch.setattr(stage5, "apply_tags", interrupted)
    with pytest.raises(KeyboardInterrupt):
        stage5.main(["--apply"])
    monkeypatch.setattr(stage5, "apply_tags", real_apply)
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert read_tags(str(source))["title"] == "Old"


@pytest.mark.parametrize("phase", ["intent_tags", "saved", "intent_rename", "result"])
def test_interrupted_rollback_resumes_without_duplicate_tag_save(tmp_path, monkeypatch, phase):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "old.mp3", title="Old")
    write_plan(data, [change_for(source, rename="new.mp3")])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    real_apply = stage5.apply_tags
    real_append = stage5.JournalWriter.append
    saves = 0

    def count_apply(path, values, deletes):
        nonlocal saves
        saves += 1
        return real_apply(path, values, deletes)

    def interrupted_append(self, event):
        if phase == "intent_tags" and event.get("mode") == "rollback" and event.get("phase") == "tags":
            real_append(self, event)
            raise KeyboardInterrupt()
        if phase == "intent_rename" and event.get("mode") == "rollback" and event.get("phase") == "rename":
            real_append(self, event)
            raise KeyboardInterrupt()
        real_append(self, event)
        if phase == "saved" and event.get("mode") == "rollback" and event["event"] == "saved":
            raise KeyboardInterrupt()
        if phase == "result" and event.get("mode") == "rollback" and event["event"] == "result":
            raise KeyboardInterrupt()

    monkeypatch.setattr(stage5, "apply_tags", count_apply)
    monkeypatch.setattr(stage5.JournalWriter, "append", interrupted_append)
    with pytest.raises(KeyboardInterrupt):
        stage5.main(["--rollback", "--run-id", RUN_ID])
    monkeypatch.setattr(stage5.JournalWriter, "append", real_append)
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert saves <= 1
    assert source.exists()
    assert read_tags(str(source))["title"] == "Old"


@pytest.mark.parametrize("race", ["replaced", "hardlinked"])
def test_rollback_rechecks_identity_and_links_after_preflight(tmp_path, monkeypatch, race):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    replacement = make_mp3(music / "replacement.mp3", title="Replacement")
    link = music / "link.mp3"
    real_append = stage5.JournalWriter.append

    def create_race(self, event):
        real_append(self, event)
        if event["event"] == "rollback_start":
            if race == "replaced":
                os.replace(replacement, source)
            else:
                os.link(source, link)

    monkeypatch.setattr(stage5.JournalWriter, "append", create_race)
    assert invoke("--rollback", "--run-id", RUN_ID) == 2
    assert read_tags(str(source))["title"] == ("Replacement" if race == "replaced" else "New")
    results = [e for e in journal_events(data, RUN_ID) if e.get("mode") == "rollback" and e["event"] == "result"]
    assert results[-1]["outcome"] == ("not_found" if race == "replaced" else "hardlinked")


def test_rollback_rechecks_hardlinks_between_saved_and_rename(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "old.mp3", title="Old")
    renamed = music / "new.mp3"
    write_plan(data, [change_for(source, rename=renamed.name)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    link = music / "link.mp3"
    real_append = stage5.JournalWriter.append

    def hardlink_after_saved(self, event):
        real_append(self, event)
        if event["event"] == "saved" and event.get("mode") == "rollback":
            os.link(renamed, link)

    monkeypatch.setattr(stage5.JournalWriter, "append", hardlink_after_saved)
    assert invoke("--rollback", "--run-id", RUN_ID) == 2
    assert renamed.exists() and not source.exists()
    assert read_tags(str(renamed))["title"] == "Old"
    results = [e for e in journal_events(data, RUN_ID) if e.get("mode") == "rollback" and e["event"] == "result"]
    assert results[-1]["outcome"] == "hardlinked"


def test_rename_failure_keeps_verified_tags_for_rollback(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "old.mp3", title="Old")
    write_plan(data, [change_for(source, rename="new.mp3")])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    real_rename = stage5.rename_exact

    def fail_rename(*args, **kwargs):
        raise OSError("injected rename failure")

    monkeypatch.setattr(stage5, "rename_exact", fail_rename)
    assert invoke("--apply") == 2
    assert source.exists()
    assert read_tags(str(source))["title"] == "New"
    monkeypatch.setattr(stage5, "rename_exact", real_rename)
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert read_tags(str(source))["title"] == "Old"


def test_multitrack_directory_identity_resolution_ignores_cover_file(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    album = music / "album"
    album.mkdir()
    one = make_mp3(album / "one.mp3", title="Old One")
    two = make_mp3(album / "two.mp3", title="Old Two")
    (album / "cover.jpg").write_bytes(b"image")
    first = change_for(one, title="New One", rename="renamed one.mp3")
    second = change_for(two, title="New Two", rename="renamed two.mp3")
    write_plan(data, [first, second])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert read_tags(str(one))["title"] == "Old One"
    assert read_tags(str(two))["title"] == "Old Two"
    assert (album / "cover.jpg").read_bytes() == b"image"


def test_m4a_totals_survive_apply_and_rollback(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_m4a(music / "song.m4a", title="Old", track="3/12", disc="1/2")
    identity = file_identity(str(source))
    change = change_for(source)
    change["tag_changes"]["track"] = {"from": "3/12", "to": "4/12"}
    write_plan(data, [change])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    assert read_tags(str(source))["track"] == "4/12"
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    tags = read_tags(str(source))
    assert tags["track"] == "3/12"
    assert tags["disc"] == "1/2"
    assert file_identity(str(source)) == identity


def test_seeded_temporary_rename_state_resolves_by_identity(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "Original.mp3", title="Old")
    planned = music / "original.mp3"
    temporary = music / f"original.mp3.{RUN_ID}.tmp"
    identity = file_identity(str(source))
    size = source.stat().st_size
    os.rename(source, temporary)
    manifest = {
        "schema_version": 2,
        "run_id": RUN_ID,
        "plan_sha256": "deadbeef",
        "created_at": "2026-09-04T12:00:00",
        "music_dir": str(music.resolve()),
        "entries": [{
            "file_path": str(source),
            "original_filename": source.name,
            "planned_path": str(planned),
            "tmp_path": str(temporary),
            "file_id": list(identity),
            "size": size,
            "written_keys": [],
            "written_values": {},
            "original_tags": read_tags(str(temporary)),
        }],
    }
    (data / f"backup_manifest.{RUN_ID}.json").write_text(json.dumps(manifest), encoding="utf-8")
    (data / f"journal.{RUN_ID}.jsonl").write_text(
        json.dumps({
            "event": "intent", "mode": "apply", "entry_id": 0,
            "phase": "rename", "size_before": size, "tmp_path": str(temporary),
        }) + "\n",
        encoding="utf-8",
    )
    calls = 0

    def unexpected_tags(*args, **kwargs):
        nonlocal calls
        calls += 1

    monkeypatch.setattr(stage5, "apply_tags", unexpected_tags)
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert source.exists() and not temporary.exists()
    assert calls == 0


def test_externally_modified_entry_isolated_and_retryable(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    one = make_mp3(music / "one.mp3", title="Old One")
    two = make_mp3(music / "two.mp3", title="Old Two")
    write_plan(data, [change_for(one, title="New One"), change_for(two, title="New Two")])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    from pipeline.utils.tag_io import apply_tags as real_apply_tags
    real_apply_tags(str(one), {"title": "Human Edit"}, [])

    assert invoke("--rollback", "--run-id", RUN_ID) == 2
    assert read_tags(str(one))["title"] == "Human Edit"
    assert read_tags(str(two))["title"] == "Old Two"
    real_apply_tags(str(one), {"title": "New One"}, [])
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert read_tags(str(one))["title"] == "Old One"


def test_manual_review_retry_after_human_restores_expected_apply_state(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    real_apply = stage5.apply_tags

    def fail_uncertain(path, values, deletes):
        real_apply(path, {"title": "Neither"}, [])
        raise OSError("uncertain")

    monkeypatch.setattr(stage5, "apply_tags", fail_uncertain)
    assert invoke("--apply") == 2
    monkeypatch.setattr(stage5, "apply_tags", real_apply)
    assert invoke("--rollback", "--run-id", RUN_ID) == 2
    real_apply(str(source), {"title": "New"}, [])
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert read_tags(str(source))["title"] == "Old"


def test_corrupt_journal_stays_open_until_separate_acknowledgement(tmp_path, monkeypatch):
    _, data = configure_roots(tmp_path, monkeypatch)
    journal = data / f"journal.{RUN_ID}.jsonl"
    journal.write_bytes(b"not-json\n")
    assert stage5.run_state(RUN_ID) == "open"
    before = journal.read_bytes()
    assert invoke("--rollback", "--run-id", RUN_ID) == 1
    assert journal.read_bytes() == before
    assert invoke("--acknowledge-run", RUN_ID, "--note", "corrupt journal reviewed") == 0
    assert stage5.run_state(RUN_ID) == "acknowledged"
    assert journal.read_bytes() == before


def test_orphan_manifest_is_open_and_requires_acknowledgement(tmp_path, monkeypatch):
    _, data = configure_roots(tmp_path, monkeypatch)
    manifest = data / f"backup_manifest.{RUN_ID}.json"
    manifest.write_text("{}", encoding="utf-8")
    assert stage5.run_state(RUN_ID) == "open"
    assert invoke("--rollback", "--run-id", RUN_ID) == 1
    assert invoke("--acknowledge-run", RUN_ID, "--note", "orphan inspected") == 0
    assert stage5.run_state(RUN_ID) == "acknowledged"


def test_tag_failure_skips_rename_and_records_size_delta(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "old.mp3", title="Old")
    write_plan(data, [change_for(source, rename="new.mp3")])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0

    def fail_tags(path, values, deletes):
        raise OSError("injected tag failure")

    monkeypatch.setattr(stage5, "apply_tags", fail_tags)
    assert invoke("--apply") == 2
    assert source.exists() and not (music / "new.mp3").exists()
    result = [e for e in journal_events(data, RUN_ID) if e["event"] == "result"][-1]
    assert result["outcome"] == "tag_failed"
    assert result["size_before"] == result["size_after"]


@pytest.mark.parametrize("failure", ["reread", "container"])
def test_post_write_verification_failure_is_tag_failed(tmp_path, monkeypatch, failure):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "old.mp3", title="Old")
    write_plan(data, [change_for(source, rename="new.mp3")])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    if failure == "reread":
        real_read = stage5.read_tags
        calls = 0

        def mismatched_after_write(path):
            nonlocal calls
            calls += 1
            result = real_read(path)
            if calls >= 4:
                result["title"] = "Mismatch"
            return result

        monkeypatch.setattr(stage5, "read_tags", mismatched_after_write)
    else:
        monkeypatch.setattr(stage5, "verify_container", lambda path: False)
    assert invoke("--apply") == 2
    assert source.exists() and not (music / "new.mp3").exists()
    result = [e for e in journal_events(data, RUN_ID) if e["event"] == "result"][-1]
    assert result["outcome"] == "tag_failed"


@pytest.mark.parametrize("mutation", ["identity", "tags", "rename_only_size"])
def test_post_preflight_mutation_is_detected_before_write(tmp_path, monkeypatch, mutation):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    change = change_for(
        source,
        title=None if mutation == "rename_only_size" else "New",
        rename="renamed.mp3" if mutation == "rename_only_size" else None,
    )
    write_plan(data, [change])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    real_create = stage5.create_backup_manifest

    def mutate_after_manifest(*args, **kwargs):
        manifest = real_create(*args, **kwargs)
        if mutation == "identity":
            replacement = make_mp3(music / "replacement.mp3", title="Old")
            os.replace(replacement, source)
        elif mutation == "tags":
            from pipeline.utils.tag_io import apply_tags as real_apply_tags
            real_apply_tags(str(source), {"title": "Human"}, [])
        else:
            with open(source, "ab") as output:
                output.write(b"size change")
        return manifest

    monkeypatch.setattr(stage5, "create_backup_manifest", mutate_after_manifest)
    assert invoke("--apply") == 2
    result = [e for e in journal_events(data, RUN_ID) if e["event"] == "result"][-1]
    assert result["outcome"] == "changed_since_preflight"
    assert not (music / "renamed.mp3").exists()


def test_manifest_error_blocks_deletion_during_rollback(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    change = change_for(source)
    change["tag_changes"] = {"year": {"from": "", "to": "2026"}}
    write_plan(data, [change])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    manifest_path = data / f"backup_manifest.{RUN_ID}.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["entries"][0]["original_tags"]["error"] = "hand edited"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    assert invoke("--rollback", "--run-id", RUN_ID) == 2
    assert read_tags(str(source))["year"] == "2026"


@pytest.mark.parametrize("invalid", ["music_dir", "planned_path", "tmp_path", "original_filename"])
def test_rollback_manifest_containment_variants_refuse_before_stat(tmp_path, monkeypatch, invalid):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = music / "song.mp3"
    entry = {
        "file_path": str(source),
        "original_filename": source.name,
        "planned_path": None,
        "tmp_path": None,
        "file_id": ["1", "2"],
        "size": 1,
        "written_keys": [],
        "written_values": {},
        "original_tags": {},
    }
    manifest = {
        "schema_version": 2,
        "run_id": RUN_ID,
        "music_dir": str(music.resolve()),
        "entries": [entry],
    }
    if invalid == "music_dir":
        manifest["music_dir"] = str(tmp_path / "other-music")
    elif invalid == "original_filename":
        entry["original_filename"] = "..\\escape.mp3"
    else:
        entry[invalid] = str(tmp_path / "outside.mp3")
    (data / f"journal.{RUN_ID}.jsonl").write_text('{"event":"run_start"}\n', encoding="utf-8")
    (data / f"backup_manifest.{RUN_ID}.json").write_text(json.dumps(manifest), encoding="utf-8")
    monkeypatch.setattr(stage5, "file_identity", lambda path: pytest.fail("stat before containment"))
    assert invoke("--rollback", "--run-id", RUN_ID) == 1


def test_preflight_rejects_symlink_source_when_supported(tmp_path, monkeypatch):
    music, _ = configure_roots(tmp_path, monkeypatch)
    target = make_mp3(music / "target.mp3", title="Old")
    link = music / "link.mp3"
    try:
        os.symlink(target, link)
    except OSError as error:
        pytest.skip(f"symlink creation unavailable: {error}")
    reasons = [
        issue.reason
        for issue in stage5.preflight_apply({"changes": [change_for(link)]}, RUN_ID)
    ]
    assert any("symlink or reparse" in reason for reason in reasons)


def test_preflight_validates_the_case_rename_temporary_path(tmp_path, monkeypatch):
    music, _ = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "Song.MP3", title="Old")
    change = change_for(source, title=None, rename="Song.mp3")
    real_validate = stage5.validate_windows_path
    checked = []

    def validate(path):
        checked.append(path)
        if path.endswith(f".{RUN_ID}.tmp"):
            return ["full path is 260 UTF-16 code units or longer"]
        return real_validate(path)

    monkeypatch.setattr(stage5, "validate_windows_path", validate)
    reasons = [
        issue.reason
        for issue in stage5.preflight_apply({"changes": [change]}, RUN_ID)
    ]
    assert any(path.endswith(f".{RUN_ID}.tmp") for path in checked)
    assert any("invalid temporary path" in reason for reason in reasons)


def test_corrupt_mid_save_is_manual_review_and_rollback_leaves_bytes(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    write_plan(data, [change_for(source)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0

    def corrupt_then_fail(path, values, deletes):
        with open(path, "wb") as output:
            output.write(b"corrupt")
        raise OSError("interrupted corrupt save")

    monkeypatch.setattr(stage5, "apply_tags", corrupt_then_fail)
    assert invoke("--apply") == 2
    corrupt_bytes = source.read_bytes()
    assert invoke("--rollback", "--run-id", RUN_ID) == 2
    assert source.read_bytes() == corrupt_bytes
    results = [e for e in journal_events(data, RUN_ID) if e.get("mode") == "rollback" and e["event"] == "result"]
    assert results[-1]["outcome"] == "manual_review"


def test_stranded_apply_result_is_found_at_tmp_and_restored(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "Old.mp3", title="Old")
    destination = music / "old.mp3"
    write_plan(data, [change_for(source, rename=destination.name)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    real_rename = stage5.rename_exact

    def strand(src, dst, run_id):
        temporary = f"{dst}.{run_id}.tmp"
        os.rename(src, temporary)
        from pipeline.utils.safe_fs import StrandedFileError
        raise StrandedFileError(temporary)

    monkeypatch.setattr(stage5, "rename_exact", strand)
    assert invoke("--apply") == 2
    temporary = music / f"old.mp3.{RUN_ID}.tmp"
    assert temporary.exists() and not source.exists()
    monkeypatch.setattr(stage5, "rename_exact", real_rename)
    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert source.exists() and not temporary.exists()
    assert read_tags(str(source))["title"] == "Old"


@pytest.mark.parametrize(
    "args",
    [
        (),
        ("--apply", "--dry-run"),
        ("--apply", "--rollback"),
        ("--rollback", "--note", "invalid"),
        ("--acknowledge-run", RUN_ID, "--dry-run", "--note", "invalid"),
    ],
)
def test_argument_refusals_exit_one(args):
    assert invoke(*args) == 1


@pytest.mark.parametrize(
    "field,value",
    [
        ("file_id", ["only-one"]),
        ("size", -1),
        ("written_keys", ["title", "title"]),
        ("original_tags", None),
    ],
)
def test_malformed_manifest_entry_refuses_before_rollback_start(
    tmp_path, monkeypatch, field, value
):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    entry = {
        "file_path": str(source),
        "original_filename": source.name,
        "planned_path": None,
        "tmp_path": None,
        "file_id": list(file_identity(str(source))),
        "size": source.stat().st_size,
        "written_keys": ["title"],
        "written_values": {"title": "New"},
        "original_tags": read_tags(str(source)),
    }
    entry[field] = value
    manifest = {
        "schema_version": 2,
        "run_id": RUN_ID,
        "music_dir": str(music.resolve()),
        "entries": [entry],
    }
    journal = data / f"journal.{RUN_ID}.jsonl"
    journal.write_text('{"event":"run_start"}\n', encoding="utf-8")
    (data / f"backup_manifest.{RUN_ID}.json").write_text(json.dumps(manifest), encoding="utf-8")
    before = journal.read_bytes()
    assert invoke("--rollback", "--run-id", RUN_ID) == 1
    assert journal.read_bytes() == before


def test_seeded_case_only_rollback_temp_resumes_to_original_name(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "Original.mp3", title="Old")
    planned = music / "original.mp3"
    write_plan(data, [change_for(source, title=None, rename=planned.name)])
    monkeypatch.setattr(stage5, "make_run_id", lambda digest: RUN_ID)
    assert invoke("--dry-run") == 0
    assert invoke("--apply") == 0
    rollback_tmp = music / f"Original.mp3.{RUN_ID}.tmp"
    with stage5.JournalWriter(str(data / f"journal.{RUN_ID}.jsonl")) as journal:
        journal.append({"event": "rollback_start"})
        journal.append({
            "event": "intent", "mode": "rollback", "entry_id": 0,
            "phase": "rename", "size_before": planned.stat().st_size,
            "tmp_path": str(rollback_tmp),
        })
    os.rename(planned, rollback_tmp)

    assert invoke("--rollback", "--run-id", RUN_ID) == 0
    assert source.exists()
    assert not rollback_tmp.exists()
    names = os.listdir(music)
    assert source.name in names
    assert planned.name not in names


def test_journal_temporary_path_outside_music_refuses_before_stat(tmp_path, monkeypatch):
    music, data = configure_roots(tmp_path, monkeypatch)
    source = make_mp3(music / "song.mp3", title="Old")
    entry = {
        "file_path": str(source),
        "original_filename": source.name,
        "planned_path": None,
        "tmp_path": None,
        "file_id": list(file_identity(str(source))),
        "size": source.stat().st_size,
        "written_keys": [],
        "written_values": {},
        "original_tags": read_tags(str(source)),
    }
    manifest = {
        "schema_version": 2, "run_id": RUN_ID,
        "music_dir": str(music.resolve()), "entries": [entry],
    }
    (data / f"backup_manifest.{RUN_ID}.json").write_text(json.dumps(manifest), encoding="utf-8")
    (data / f"journal.{RUN_ID}.jsonl").write_text(json.dumps({
        "event": "intent", "mode": "rollback", "entry_id": 0,
        "phase": "rename", "size_before": source.stat().st_size,
        "tmp_path": str(tmp_path / "outside.tmp"),
    }) + "\n", encoding="utf-8")
    monkeypatch.setattr(stage5, "file_identity", lambda path: pytest.fail("stat before containment"))
    assert invoke("--rollback", "--run-id", RUN_ID) == 1
