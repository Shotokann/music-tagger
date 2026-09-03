import importlib
import os

import pytest

import pipeline.config as config
from pipeline.utils import fingerprint


def test_load_dotenv_parses_values_without_overriding_environment(
    tmp_path, monkeypatch
):
    dotenv_path = tmp_path / ".env"
    dotenv_path.write_text(
        "\ufeff# comment\n"
        "PLAIN = value\n"
        "DOUBLE=\"quoted value\"\n"
        "SINGLE='single value'\n"
        "MALFORMED\n"
        "EXISTING=from-file\n",
        encoding="utf-8",
    )
    monkeypatch.delenv("PLAIN", raising=False)
    monkeypatch.delenv("DOUBLE", raising=False)
    monkeypatch.delenv("SINGLE", raising=False)
    monkeypatch.delenv("MALFORMED", raising=False)
    monkeypatch.setenv("EXISTING", "from-environment")

    config._load_dotenv(str(dotenv_path))

    assert os.environ["PLAIN"] == "value"
    assert os.environ["DOUBLE"] == "quoted value"
    assert os.environ["SINGLE"] == "single value"
    assert "MALFORMED" not in os.environ
    assert os.environ["EXISTING"] == "from-environment"


def test_music_dir_honors_environment_and_expands_home(tmp_path, monkeypatch):
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.setenv("MUSIC_DIR", "~/test-music")

    reloaded = importlib.reload(config)

    assert reloaded.MUSIC_DIR == os.path.normpath(str(tmp_path / "test-music"))


def test_fpcalc_path_is_empty_when_no_source_can_resolve_it(monkeypatch):
    monkeypatch.delenv("FPCALC_PATH", raising=False)
    monkeypatch.delenv("LOCALAPPDATA", raising=False)
    monkeypatch.setattr(config.os.path, "isfile", lambda path: False)
    monkeypatch.setattr(config.shutil, "which", lambda command: None)

    reloaded = importlib.reload(config)

    assert reloaded.FPCALC_PATH == ""


def test_fingerprint_requires_api_key_before_running_fpcalc(monkeypatch):
    monkeypatch.setattr(fingerprint, "ACOUSTID_API_KEY", "")

    def unexpected_generate(filepath):
        pytest.fail("generate_fingerprint must not run without an API key")

    monkeypatch.setattr(fingerprint, "generate_fingerprint", unexpected_generate)

    with pytest.raises(
        RuntimeError,
        match=r"ACOUSTID_API_KEY is not set; add it to \.env",
    ):
        fingerprint.fingerprint_and_lookup("example.mp3")


def test_is_skip_album_uses_globs():
    assert config.is_skip_album("Jerry Lehrer", "Project Warlock OST")
    assert config.is_skip_album("Any Artist", "120 Bible Songs for Children")
    assert not config.is_skip_album("Any Artist", "An Ordinary Album")


def test_get_hardcoded_release_id_handles_regex_and_substring_patterns():
    assert config.get_hardcoded_release_id("Burzum", "Burzum") == (
        "c6e9caed-aeb3-4de7-b47e-0c9c9b91a1dc"
    )
    assert config.get_hardcoded_release_id("Enya", "The Very Best of Enya") == (
        "51be8f43-dac9-4450-a588-9b91e6f98ea1"
    )
    assert config.get_hardcoded_release_id("Burzum", "Burzum Live") is None
