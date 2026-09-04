import hashlib
import json
import os
from types import SimpleNamespace

import pytest

from pipeline.utils import safe_fs


RUN_ID = "20260904T120000-deadbeef"


def _case_sensitive(tmp_path):
    probe = tmp_path / "caseprobe"
    probe.write_text("x")
    return not (tmp_path / "CASEPROBE").exists()


def test_case_only_rename_or_case_sensitive_collision(tmp_path):
    src = tmp_path / "Waking The Fallen.mp3"
    dst = tmp_path / "Waking the Fallen.mp3"
    src.write_bytes(b"audio")
    identity = safe_fs.file_identity(str(src))

    if _case_sensitive(tmp_path):
        dst.write_bytes(b"other")
        with pytest.raises(safe_fs.CollisionError):
            safe_fs.rename_exact(str(src), str(dst), RUN_ID)
        assert src.read_bytes() == b"audio"
        assert dst.read_bytes() == b"other"
    else:
        safe_fs.rename_exact(str(src), str(dst), RUN_ID)
        assert dst.exists()
        assert safe_fs.file_identity(str(dst)) == identity


def test_genuine_collision_leaves_both_files_untouched(tmp_path):
    src = tmp_path / "source.mp3"
    dst = tmp_path / "target.mp3"
    src.write_bytes(b"source")
    dst.write_bytes(b"target")
    before = (src.stat().st_mtime_ns, dst.stat().st_mtime_ns)

    with pytest.raises(safe_fs.CollisionError):
        safe_fs.rename_exact(str(src), str(dst), RUN_ID)

    assert src.read_bytes() == b"source"
    assert dst.read_bytes() == b"target"
    assert (src.stat().st_mtime_ns, dst.stat().st_mtime_ns) == before


def test_case_only_second_step_failure_restores_source(tmp_path, monkeypatch):
    if _case_sensitive(tmp_path):
        pytest.skip("case-only two-step behavior requires a case-insensitive filesystem")
    src = tmp_path / "Song.MP3"
    dst = tmp_path / "Song.mp3"
    src.write_bytes(b"audio")
    real_rename = os.rename
    calls = 0

    def fail_second(old, new):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise KeyboardInterrupt()
        return real_rename(old, new)

    monkeypatch.setattr(safe_fs.os, "rename", fail_second)
    with pytest.raises(KeyboardInterrupt):
        safe_fs.rename_exact(str(src), str(dst), RUN_ID)
    assert src.exists()
    assert not os.path.exists(safe_fs.temp_name_for(str(dst), RUN_ID))


def test_case_only_double_failure_reports_stranded_temp(tmp_path, monkeypatch):
    if _case_sensitive(tmp_path):
        pytest.skip("case-only two-step behavior requires a case-insensitive filesystem")
    src = tmp_path / "Song.MP3"
    dst = tmp_path / "Song.mp3"
    src.write_bytes(b"audio")
    real_rename = os.rename
    calls = 0

    def fail_after_first(old, new):
        nonlocal calls
        calls += 1
        if calls >= 2:
            raise OSError("injected")
        return real_rename(old, new)

    monkeypatch.setattr(safe_fs.os, "rename", fail_after_first)
    with pytest.raises(safe_fs.StrandedFileError) as caught:
        safe_fs.rename_exact(str(src), str(dst), RUN_ID)
    assert caught.value.tmp_path == safe_fs.temp_name_for(str(dst), RUN_ID)


def test_identity_unavailable_and_hardlink_count(tmp_path, monkeypatch):
    source = tmp_path / "source.mp3"
    linked = tmp_path / "linked.mp3"
    source.write_bytes(b"audio")
    os.link(source, linked)
    assert safe_fs.link_count(str(source)) == 2

    monkeypatch.setattr(
        safe_fs.os,
        "stat",
        lambda *args, **kwargs: SimpleNamespace(st_dev=1, st_ino=0),
    )
    with pytest.raises(safe_fs.IdentityUnavailable):
        safe_fs.file_identity(str(source))


@pytest.mark.parametrize(
    "path",
    [r"C:\Music\a.mp3", r"\\server\share\a.mp3"],
)
def test_valid_windows_paths(path):
    assert safe_fs.validate_windows_path(path) == []


@pytest.mark.parametrize(
    "component, expected",
    [
        ("a" * 256, "255"),
        ("CON.mp3", "reserved"),
        ("song.", "trailing dot"),
        ("song ", "trailing space"),
        ("bad?.mp3", "illegal"),
    ],
)
def test_invalid_windows_components(component, expected):
    violations = safe_fs.validate_windows_path(f"C:\\Music\\{component}")
    assert any(expected in violation for violation in violations)


def test_utf16_boundaries_count_astral_characters_twice():
    assert safe_fs.validate_windows_path("C:\\" + "x" * 255) == []
    assert any(
        "255" in violation
        for violation in safe_fs.validate_windows_path("C:\\" + "x" * 256)
    )
    assert safe_fs.validate_windows_path("C:\\" + "x" * 251 + "😀") == []
    violations = safe_fs.validate_windows_path("C:\\" + "x" * 254 + "😀")
    assert any("255" in violation for violation in violations)


def test_contained_uses_component_boundary_and_case_insensitive_comparison(tmp_path):
    root = tmp_path / "Music"
    assert safe_fs.contained(str(root / "Artist" / "song.mp3"), str(root))
    assert not safe_fs.contained(str(tmp_path / "Music2" / "song.mp3"), str(root))
    assert safe_fs.contained(str(root).upper(), str(root).lower())


def test_sha256_and_atomic_json(tmp_path):
    source = tmp_path / "source.bin"
    source.write_bytes(b"raw bytes")
    assert safe_fs.sha256_file(str(source)) == hashlib.sha256(b"raw bytes").hexdigest()

    target = tmp_path / "state.json"
    safe_fs.write_json_atomic(str(target), {"unicode": "Björk"})
    assert json.loads(target.read_text(encoding="utf-8")) == {"unicode": "Björk"}
    assert not (tmp_path / "state.json.tmp").exists()


def test_atomic_json_failure_before_replace_preserves_old_file(tmp_path, monkeypatch):
    target = tmp_path / "state.json"
    target.write_bytes(b"old")

    def fail_replace(src, dst):
        raise OSError("injected")

    monkeypatch.setattr(safe_fs.os, "replace", fail_replace)
    with pytest.raises(OSError):
        safe_fs.write_json_atomic(str(target), {"new": True})
    assert target.read_bytes() == b"old"
