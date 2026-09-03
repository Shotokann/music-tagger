"""
Pipeline configuration: paths, API keys, skip lists, hardcoded release IDs.
Migrated from legacy/Restore-UnicodeFilenames-MusicBrainz-v5.ps1.
"""

import glob
import os
import re
import shutil

# ── Paths ──────────────────────────────────────────────────────────────────────

PIPELINE_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(PIPELINE_DIR)
DATA_DIR = os.path.join(REPO_ROOT, "data")


def _load_dotenv(path: str) -> None:
    """Load simple KEY=VALUE entries without overriding the environment."""
    if not os.path.isfile(path):
        return

    with open(path, encoding="utf-8-sig") as dotenv_file:
        for raw_line in dotenv_file:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue

            key, separator, value = line.partition("=")
            if not separator:
                continue

            key = key.strip()
            value = value.strip()
            if not key:
                continue
            if (
                len(value) >= 2
                and value[0] == value[-1]
                and value[0] in {'"', "'"}
            ):
                value = value[1:-1]
            os.environ.setdefault(key, value)


def _expand(path: str) -> str:
    """Expand environment variables and home markers, then normalize a path."""
    return os.path.normpath(os.path.expanduser(os.path.expandvars(path)))


def _resolve_fpcalc_path() -> str:
    configured_path = os.environ.get("FPCALC_PATH")
    if configured_path:
        return _expand(configured_path)

    path_hit = shutil.which("fpcalc")
    if path_hit:
        return path_hit

    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        pattern = os.path.join(
            local_app_data,
            "Microsoft",
            "WinGet",
            "Packages",
            "AcoustID.Chromaprint_*",
            "chromaprint-fpcalc-*",
            "fpcalc.exe",
        )
        for candidate in glob.glob(pattern):
            if os.path.isfile(candidate):
                return candidate
    return ""


_load_dotenv(os.path.join(REPO_ROOT, ".env"))

MUSIC_DIR = _expand(os.environ.get("MUSIC_DIR") or "~/OneDrive/Music/Music")
FPCALC_PATH = _resolve_fpcalc_path()

# ── API Keys & User-Agent ─────────────────────────────────────────────────────

ACOUSTID_API_KEY = os.environ.get("ACOUSTID_API_KEY", "")
MB_CONTACT = os.environ.get("MB_CONTACT", "ShotokanDeity@gmail.com")
MB_USER_AGENT = f"MusicTagEditor/2.0 ({MB_CONTACT})"

# ── Rate Limits ────────────────────────────────────────────────────────────────

MB_RATE_LIMIT = 1.1       # seconds between MusicBrainz calls
ACOUSTID_RATE_LIMIT = 0.35  # seconds between AcoustID calls

# ── File Extensions ────────────────────────────────────────────────────────────

SUPPORTED_EXTENSIONS = {".mp3", ".m4a", ".m4p", ".wav", ".flac", ".ogg", ".wma"}
WRITABLE_EXTENSIONS = {".mp3", ".m4a", ".wav", ".flac"}  # excludes DRM
FINGERPRINTABLE_EXTENSIONS = {".mp3", ".m4a", ".wav", ".flac", ".ogg"}

# ── Matching Thresholds ───────────────────────────────────────────────────────

MATCH_THRESHOLD = 0.70        # album-level: below = anomaly
SIMILARITY_THRESHOLD = 0.75   # track-level title similarity
MAX_CANDIDATES = 6            # max release candidates to evaluate

# ── Disc Folder Detection ─────────────────────────────────────────────────────

DISC_FOLDER_RE = re.compile(
    r"(?i)^(?:.*\s)?(?:Disc|CD|Part)\s*#?\s*(\d+)(?:\s.*)?$"
)

# Special subfolders that should use grandparent as album
SPECIAL_SUBFOLDERS_RE = re.compile(r"(?i)^(Instrumentals?|Various Artists)$")

# ── Skip Lists (migrated from v5 lines 47-136) ────────────────────────────────

SKIP_ARTISTS = {
    "Kevin MacLeod",
    "Sunday School Sing-Along",
    "Crimson Moonlight",
    "Elgibbor",
    "Grave Declaration",
    "Pantokrator",
    "Slechtvalk",
    "Bloodline Severed",
    "Drottnar",
    "In the Midst of Lions",
    "Dawntreader",
    "Deus Invictus",
    "Deuteronomium",
    "Mortal Treason",
    "Ill Harmonics",
    "Divulgence",
    "Music Imaginary",
    "Royal Tailor",
    "We are Leo",
}

# Format: (artist_glob, album_glob) — checked with fnmatch
SKIP_ALBUMS = [
    # Fan compilations
    ("Slipknot", "*Clan*"),
    ("Slipknot", "*Crows*"),
    # Indie game soundtracks
    ("Jerry Lehr*", "*Project Warlock*"),
    ("Bethesda Softworks", "*"),
    ("Dragon Age", "*"),
    ("Tavern Songs*", "*"),
    # Children's/educational
    ("*", "*120 Bible Songs*"),
    # Self-released/demo-only
    ("Amon Amarth", "*Thor Arise*"),
    ("Amon Amarth", "*Fimbul Winter*"),
    ("Amon Amarth", "*Release Shows*"),
    ("Belphegor", "*Kruzifixion*"),
    ("Belphegor", "*Bloodbath in Paradise*"),
    ("Mastodon", "*9 Song Demo*"),
    ("Mastodon", "*Lifesblood*"),
    ("Mastodon", "*March of the Fire Ants*"),
    ("Windir", "*Sogneriket*"),
    ("Finntroll", "*Rivfader*"),
    # Compilations/unofficial
    ("Skrillex", "*Originals*"),
    ("Skrillex", "*Remixes*"),
    ("Skrillex", "*Unknown*"),
    ("Static-X", "*Beneath*Between*Beyond*"),
    ("Static-X", "*Push It*"),
    ("Static-X", "*Rarities*"),
    ("Staind", "*Fade"),
    ("Staind", "*For You"),
    ("Staind", "*Singles 1996*"),
    ("Staind", "*iTunes Originals*"),
    ("Seether", "*B-Sides*Rarities*"),
    ("Various Artists", "*Brutal Christmas*"),
    ("Various Artists", "*Best of Club Hits*"),
    ("Vitamin String Quartet", "*"),
    # Underground / niche
    ("Antestor", "*Despair*"),
    ("Antestor", "*Return*Black Death*"),
    ("Antestor", "*Defeat of Satan*"),
    ("Antestor", "*Det Tapte Liv*"),
    ("Antestor", "*Forsaken*"),
    ("Becoming the Archetype", "*Celestial Completion*"),
    ("Becoming the Archetype", "*Celestial Progression*"),
    ("Becoming the Archetype", "*Dichotomy*"),
    ("Becoming the Archetype", "*I Am*"),
    ("Becoming the Archetype", "*O Holy Night*"),
    ("Behemoth", "*Bewitching the Pomerania*"),
    ("Behemoth", "*Forest Dream Eternally*"),
    ("Extol", "*Paralysis*"),
    ("Daath", "*Futility*"),
    ("Dagon", "*Terraphobic*"),
    ("Joe Farren*", "*"),
    ("Leo", "*Metal Covers*"),
    ("Britt Nicole", "*Gold*"),
    ("Apocalyptica", "*Harmageddon*"),
    # Singles/EPs not in MB
    ("Eluveitie", "*Thousandfold*Single*"),
    ("Eluveitie", "*Meet The Enemy*"),
    ("Eluveitie", "*Slania Evocation*Metal Hammer*"),
    ("DevilDriver", "*Winter Kills*"),
    # Empty/unknown
    ("Tiesto", "*Unknown*"),
    ("*", "Unknown"),
]

# ── Hardcoded Release IDs (migrated from v5 lines 1119-1191) ─────────────────
# For albums that text search can't reliably find

HARDCODED_RELEASES = {
    # (artist_pattern, album_pattern): release_id
    ("PPK", "Russian Trance"): "f1dd707d-df3a-4642-aeb0-d7d45638cb4a",
    ("Enya", "Very Best"): "51be8f43-dac9-4450-a588-9b91e6f98ea1",
    ("Gareth Coker", "Will of the Wisps"): "f020c40a-a37c-478f-8c32-2cc0e1d3285d",
    ("Behemoth", "Demonica"): "8ed49acf-ce06-4ae0-b1af-0c85dd42b9d7",
    ("Burzum", "Filosofem"): "42c7dcc2-f0a3-4262-8537-e6ec2edbc133",
    ("Burzum", r"^Burzum$"): "c6e9caed-aeb3-4de7-b47e-0c9c9b91a1dc",
    ("Rammstein", "Sehnsucht"): "5e5b814d-61f5-4da5-bc43-9bf0da2c7fed",
    ("Rammstein", "Liebe ist"): "aeca8864-2ad1-3a9f-adb9-0a393c7f95c8",
    ("Machine Head", "Blackening"): "84370af2-ac1a-4759-9277-553dec2cb9e7",
}


def is_skip_artist(artist: str) -> bool:
    return artist in SKIP_ARTISTS


def is_skip_album(artist: str, album: str) -> bool:
    from fnmatch import fnmatch
    for artist_pat, album_pat in SKIP_ALBUMS:
        if fnmatch(artist, artist_pat) and fnmatch(album, album_pat):
            return True
    return False


def get_hardcoded_release_id(artist: str, album: str) -> str | None:
    """Check if this artist/album has a hardcoded MusicBrainz release ID."""
    for (artist_pat, album_pat), release_id in HARDCODED_RELEASES.items():
        if artist_pat == artist or artist_pat in artist:
            # album_pat might be a regex (starts with ^) or a substring
            if album_pat.startswith("^"):
                if re.match(album_pat, album):
                    return release_id
            elif album_pat in album:
                return release_id
    return None
