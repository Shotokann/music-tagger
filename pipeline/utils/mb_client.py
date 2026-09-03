"""
MusicBrainz API wrapper with rate limiting, retry, and caching.
Uses musicbrainzngs for the heavy lifting.
"""

import time
import musicbrainzngs
from ..config import MB_USER_AGENT, MB_CONTACT, MB_RATE_LIMIT, MAX_CANDIDATES

# Initialize musicbrainzngs
musicbrainzngs.set_useragent(
    "MusicTagEditor", "2.0", MB_CONTACT
)
musicbrainzngs.set_rate_limit(limit_or_interval=MB_RATE_LIMIT, new_requests=1)

_last_request_time = 0.0


def _rate_limit():
    """Enforce rate limiting between requests."""
    global _last_request_time
    now = time.time()
    elapsed = now - _last_request_time
    if elapsed < MB_RATE_LIMIT:
        time.sleep(MB_RATE_LIMIT - elapsed)
    _last_request_time = time.time()


def search_release_groups(artist: str, album: str, limit: int = 5) -> list:
    """Strategy 1: Search release-groups, then browse releases within."""
    _rate_limit()
    try:
        result = musicbrainzngs.search_release_groups(
            artist=artist, releasegroup=album, limit=limit
        )
        groups = result.get("release-group-list", [])
        all_releases = []

        for group in groups[:2]:  # Check top 2 groups
            _rate_limit()
            try:
                browse = musicbrainzngs.browse_releases(
                    release_group=group["id"], limit=25
                )
                all_releases.extend(browse.get("release-list", []))
            except Exception:
                pass

        return all_releases
    except Exception:
        return []


def search_releases_direct(artist: str, album: str, limit: int = 25) -> list:
    """Strategy 2: Direct release search."""
    _rate_limit()
    try:
        result = musicbrainzngs.search_releases(
            artist=artist, release=album, limit=limit
        )
        return result.get("release-list", [])
    except Exception:
        return []


def search_releases_safe(artist: str, album: str, limit: int = 25) -> list:
    """Strategy 3: Search with special chars/diacritics stripped."""
    from .matching import get_search_safe_string
    safe_artist = get_search_safe_string(artist)
    safe_album = get_search_safe_string(album)
    if safe_artist == artist and safe_album == album:
        return []  # No difference, skip
    return search_releases_direct(safe_artist, safe_album, limit)


def search_releases_by_label(artist: str, album: str, limit: int = 25) -> list:
    """Strategy 4: Label search (for game soundtracks, compilations)."""
    _rate_limit()
    try:
        result = musicbrainzngs.search_releases(
            label=artist, release=album, limit=limit
        )
        return result.get("release-list", [])
    except Exception:
        return []


def search_releases_album_only(album: str, limit: int = 25) -> list:
    """Strategy 5: Album-only search, no artist filter."""
    _rate_limit()
    try:
        result = musicbrainzngs.search_releases(
            release=album, limit=limit
        )
        return result.get("release-list", [])
    except Exception:
        return []


def get_release_by_id(release_id: str) -> dict | None:
    """Fetch full release data including recordings."""
    _rate_limit()
    try:
        result = musicbrainzngs.get_release_by_id(
            release_id, includes=["recordings", "media"]
        )
        return result.get("release")
    except Exception:
        return None


def multi_strategy_search(
    artist: str,
    clean_album: str,
    file_count: int = 0,
) -> list:
    """
    Run all 5 search strategies and return deduplicated releases.
    Ported from v5 Search-MusicBrainzReleases.
    """
    all_releases = []
    seen_ids = {}  # id -> index in all_releases

    def add_releases(releases):
        for rel in releases:
            rid = rel.get("id", "")
            if not rid:
                continue
            tracks = _get_total_tracks(rel)
            if rid not in seen_ids:
                seen_ids[rid] = len(all_releases)
                all_releases.append(rel)
            elif tracks > 0 and _get_total_tracks(all_releases[seen_ids[rid]]) == 0:
                # Replace the existing entry if this one has track count data
                all_releases[seen_ids[rid]] = rel

    # Strategy 2 first: Direct release search (has track counts in results)
    add_releases(search_releases_direct(artist, clean_album))

    # Strategy 1: Release-group search (browse may lack track counts)
    add_releases(search_release_groups(artist, clean_album))

    # Strategy 3: Fallback with stripped chars
    add_releases(search_releases_safe(artist, clean_album))

    # Strategy 4: Label search (only if nothing found)
    if not all_releases:
        add_releases(search_releases_by_label(artist, clean_album))

    # Strategy 5: Album-only (only if still nothing)
    if not all_releases:
        releases = search_releases_album_only(clean_album)
        # Filter by track count proximity if we know file count
        if file_count > 0 and releases:
            filtered = [
                r for r in releases
                if _get_total_tracks(r) >= file_count * 0.5
                and _get_total_tracks(r) <= file_count * 1.5
            ]
            add_releases(filtered if filtered else releases)
        else:
            add_releases(releases)

    return all_releases


def _get_total_tracks(release: dict) -> int:
    """Get total track count from a release's media list."""
    total = 0
    for media in release.get("medium-list", []):
        tc = media.get("track-count")
        if tc:
            total += int(tc)
    return total


def build_track_listing(release_data: dict) -> dict:
    """
    Build track listing from full release data.
    For multi-disc: plain keys only for disc 1 (prevents collision).
    Ported from v5 Build-TrackListing.
    Returns dict: key -> title (keys are int or "disc-track" strings).
    """
    track_listing = {}
    media_list = release_data.get("medium-list", [])
    is_multi_disc = len(media_list) > 1

    for medium in media_list:
        disc_num = int(medium.get("position", 1))
        for track in medium.get("track-list", []):
            track_num = int(track.get("position", 0))
            recording = track.get("recording", {})
            title = recording.get("title", track.get("title", ""))

            if is_multi_disc:
                # Always store disc-prefixed key
                track_listing[f"{disc_num}-{track_num}"] = title
                # Plain key only for disc 1
                if disc_num == 1:
                    track_listing[track_num] = title
            else:
                track_listing[track_num] = title

    return track_listing


def score_release(release: dict, file_count: int, is_special_edition: bool) -> int:
    """
    Score a release for ranking. Higher = better match.
    Ported from v5 Select-BestReleases.
    """
    total_tracks = _get_total_tracks(release)

    # Exact match with file count
    exact = 100000000 if (file_count > 0 and total_tracks == file_count) else 0

    # Status score
    status = release.get("status", "")
    status_score = {
        "Official": 2000000,
        "Promotion": 1500000,
        "Bootleg": 0,
    }.get(status, 1000000)

    # Format preference
    format_score = 0
    for media in release.get("medium-list", []):
        fmt = media.get("format", "")
        if fmt and ("CD" in fmt or "Digital" in fmt):
            format_score += 500000
        elif fmt and "Vinyl" in fmt:
            format_score += 100000
        else:
            format_score += 250000

    # Track count closeness (asymmetric)
    if file_count > 0:
        diff = total_tracks - file_count
        if diff >= 0:
            closeness = max(0, 50000 - diff * 500)
        else:
            closeness = max(0, 50000 - abs(diff) * 2000)
    elif is_special_edition:
        closeness = len(release.get("medium-list", [])) * 50000
    else:
        closeness = 0

    return exact + status_score + format_score + closeness + total_tracks


def rank_releases(releases: list, file_count: int, is_special_edition: bool) -> list:
    """Rank releases by score, return list of (release, score, total_tracks)."""
    scored = []
    for rel in releases:
        s = score_release(rel, file_count, is_special_edition)
        scored.append((rel, s, _get_total_tracks(rel)))
    scored.sort(key=lambda x: x[1], reverse=True)
    return scored
