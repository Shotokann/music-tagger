import pytest
from mutagen.id3 import ID3
from mutagen.mp4 import MP4

from pipeline import config
from pipeline.utils import tag_io
from tests.fixtures_audio import make_m4a, make_mp3


ALL_TAGS = {
    "title": "Title",
    "artist": "Artist",
    "album_artist": "Album Artist",
    "album": "Album",
    "track": "3/12",
    "year": "2026",
    "disc": "1/2",
}


@pytest.mark.parametrize("maker", [make_mp3, make_m4a])
def test_round_trip_all_friendly_keys(tmp_path, maker):
    suffix = ".mp3" if maker is make_mp3 else ".m4a"
    path = maker(tmp_path / f"track{suffix}", **ALL_TAGS)
    actual = tag_io.read_tags(str(path))
    assert {key: actual[key] for key in ALL_TAGS} == ALL_TAGS


def test_m4a_zero_totals_are_returned_without_slash(tmp_path):
    path = make_m4a(tmp_path / "track.m4a")
    mp4 = MP4(path)
    mp4.tags["trkn"] = [(3, 0)]
    mp4.save()
    assert tag_io.read_tags(str(path))["track"] == "3"


@pytest.mark.parametrize("maker", [make_mp3, make_m4a])
def test_apply_tags_sets_and_deletes_with_one_save(tmp_path, monkeypatch, maker):
    suffix = ".mp3" if maker is make_mp3 else ".m4a"
    path = maker(tmp_path / f"track{suffix}", title="Old", disc="1/2", year="2020")
    cls = ID3 if maker is make_mp3 else MP4
    real_save = cls.save
    saves = 0

    def counting_save(self, *args, **kwargs):
        nonlocal saves
        saves += 1
        return real_save(self, *args, **kwargs)

    monkeypatch.setattr(cls, "save", counting_save)
    tag_io.apply_tags(str(path), {"title": "New"}, ["disc"])

    actual = tag_io.read_tags(str(path))
    assert actual["title"] == "New"
    assert actual["disc"] == ""
    assert actual["year"] == "2020"
    assert saves == 1


def test_delete_tags_removes_selected_frame_only(tmp_path):
    path = make_mp3(tmp_path / "track.mp3", title="Keep", disc="1/2")
    tag_io.delete_tags(str(path), ["disc"])
    tags = ID3(path)
    assert tags.get("TPOS") is None
    assert str(tags["TIT2"]) == "Keep"


def test_unsupported_format_and_invalid_values(tmp_path):
    wav = tmp_path / "track.wav"
    wav.write_bytes(b"RIFF")
    with pytest.raises(tag_io.UnsupportedFormatError):
        tag_io.write_tags(str(wav), {"title": "No-op forbidden"})
    with pytest.raises(tag_io.TagValueError):
        tag_io.parse_track_value("abc")


def test_m4a_writer_surfaces_invalid_track_value(tmp_path):
    path = make_m4a(tmp_path / "track.m4a")
    with pytest.raises(tag_io.TagValueError):
        tag_io.write_tags(str(path), {"track": "abc"})


def test_config_writable_extensions_match_writer_dispatch():
    assert config.WRITABLE_EXTENSIONS == set(tag_io._WRITERS)


@pytest.mark.parametrize("maker", [make_mp3, make_m4a])
def test_stage5_run_temp_name_remains_readable_and_writable(tmp_path, maker):
    suffix = ".mp3" if maker is make_mp3 else ".m4a"
    source = maker(tmp_path / f"track{suffix}", title="Old")
    temporary = tmp_path / f"track{suffix}.20260904T120000-deadbeef.tmp"
    source.rename(temporary)

    assert tag_io.read_tags(str(temporary))["title"] == "Old"
    tag_io.apply_tags(str(temporary), {"title": "Restored"}, [])
    assert tag_io.read_tags(str(temporary))["title"] == "Restored"
