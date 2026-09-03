"""
Audio fingerprinting via fpcalc + AcoustID API lookup.
"""

import json
import subprocess
import time
import requests
from ..config import FPCALC_PATH, ACOUSTID_API_KEY, ACOUSTID_RATE_LIMIT

_last_acoustid_time = 0.0


def generate_fingerprint(filepath: str) -> dict | None:
    """
    Run fpcalc on a file and return {duration, fingerprint}.
    Returns None on failure.
    """
    if not FPCALC_PATH:
        raise RuntimeError("FPCALC_PATH is not set; add it to .env")

    try:
        result = subprocess.run(
            [FPCALC_PATH, "-json", filepath],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return None
        data = json.loads(result.stdout)
        return {
            "duration": data.get("duration", 0),
            "fingerprint": data.get("fingerprint", ""),
        }
    except Exception:
        return None


def lookup_acoustid(duration: float, fingerprint: str) -> list:
    """
    Look up a fingerprint via the AcoustID API.
    Returns list of matches: [{score, recording_id, title, artist, releases: [...]}]
    """
    if not ACOUSTID_API_KEY:
        raise RuntimeError("ACOUSTID_API_KEY is not set; add it to .env")

    global _last_acoustid_time

    # Rate limit
    now = time.time()
    elapsed = now - _last_acoustid_time
    if elapsed < ACOUSTID_RATE_LIMIT:
        time.sleep(ACOUSTID_RATE_LIMIT - elapsed)
    _last_acoustid_time = time.time()

    try:
        resp = requests.post(
            "https://api.acoustid.org/v2/lookup",
            data={
                "client": ACOUSTID_API_KEY,
                "duration": str(int(duration)),
                "fingerprint": fingerprint,
                "meta": "recordings releases",
            },
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()

        results = []
        for match in data.get("results", []):
            score = match.get("score", 0)
            for recording in match.get("recordings", []):
                rec_id = recording.get("id", "")
                title = recording.get("title", "")
                artists = recording.get("artists", [])
                artist_name = artists[0].get("name", "") if artists else ""

                releases = []
                for rel_group in recording.get("releasegroups", []):
                    for rel in rel_group.get("releases", []):
                        releases.append({
                            "id": rel.get("id", ""),
                            "title": rel.get("title", ""),
                        })

                results.append({
                    "score": score,
                    "recording_id": rec_id,
                    "title": title,
                    "artist": artist_name,
                    "releases": releases,
                })

        return results
    except Exception:
        return []


def fingerprint_and_lookup(filepath: str) -> dict | None:
    """
    Generate fingerprint and look up via AcoustID in one call.
    Returns best match or None.
    """
    if not ACOUSTID_API_KEY:
        raise RuntimeError("ACOUSTID_API_KEY is not set; add it to .env")

    fp = generate_fingerprint(filepath)
    if not fp or not fp["fingerprint"]:
        return None

    matches = lookup_acoustid(fp["duration"], fp["fingerprint"])
    if not matches:
        return None

    # Return best match (highest score)
    best = max(matches, key=lambda m: m["score"])
    best["fingerprint_duration"] = fp["duration"]
    return best
