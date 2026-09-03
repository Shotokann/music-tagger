"""
String similarity, title normalization, and core-title extraction.
Ported from v5 PowerShell: Get-NormalizedTitle, Get-CoreTitle, Get-StringSimilarity.
"""

import re
import unicodedata
import jellyfish


def remove_diacritics(text: str) -> str:
    """Strip diacritics/accents (e.g. 'Hliðskjálf' -> 'Hlidskjalf')."""
    nfkd = unicodedata.normalize("NFD", text)
    return "".join(c for c in nfkd if unicodedata.category(c) != "Mn")


def normalize_title(title: str) -> str:
    """
    Normalize for fuzzy comparison: strip all punctuation, collapse whitespace, lowercase.
    Ported from v5 Get-NormalizedTitle.
    """
    s = title.lower()
    # Replace ALL non-alphanumeric, non-space with spaces
    s = re.sub(r"[^\w\s]", " ", s, flags=re.UNICODE)
    # Also replace underscores
    s = s.replace("_", " ")
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def get_core_title(title: str) -> str:
    """
    Strip common suffixes, parentheticals, and prefixes for better matching.
    Ported from v5 Get-CoreTitle.
    """
    core = title.lower().strip()

    # Strip trailing parentheticals/brackets
    core = re.sub(r"\s*[\(\[][^)\]]*[\)\]]\s*$", "", core)

    # Strip leading "the "
    core = re.sub(r"^the\s+", "", core)

    # Strip trailing suffixes after dash/em-dash
    core = re.sub(
        r"\s+[-\u2013\u2014]\s+(?:mastered|remastered|live|instrumental|acoustic|"
        r"radio\s*edit|album\s*version|bonus\s*track|cover|demo|remix|edit|"
        r"single\s*version)\s*$",
        "", core
    )

    # Strip standalone trailing suffixes
    core = re.sub(r"\s+(?:mastered|remastered)\s*$", "", core)

    # Strip bitrate info
    core = re.sub(r"\s+\d+\s*k(?:bps)?\s*$", "", core)

    return core.strip()


def string_similarity(s1: str, s2: str) -> float:
    """Levenshtein-based similarity ratio (0.0 to 1.0)."""
    if s1 == s2:
        return 1.0
    if not s1 or not s2:
        return 0.0
    dist = jellyfish.levenshtein_distance(s1, s2)
    max_len = max(len(s1), len(s2))
    return round(1.0 - dist / max_len, 4)


def title_similarity(file_title: str, mb_title: str) -> float:
    """
    Compute best similarity between file title and MB title,
    trying normalized, core, and diacritics-removed variants.
    """
    norm_file = normalize_title(file_title)
    norm_mb = normalize_title(mb_title)
    core_file = get_core_title(norm_file)
    core_mb = get_core_title(norm_mb)

    # Exact match
    if norm_file == norm_mb or core_file == core_mb:
        return 1.0

    # Containment check
    if (norm_file in norm_mb or norm_mb in norm_file or
            core_file in core_mb or core_mb in core_file):
        if norm_file and norm_mb:
            ratio = min(len(norm_file), len(norm_mb)) / max(len(norm_file), len(norm_mb))
            return 0.85 + 0.10 * ratio

    # Levenshtein on normalized and core
    sim = max(
        string_similarity(norm_file, norm_mb),
        string_similarity(core_file, core_mb),
    )

    # Try diacritics removed
    if sim < 0.75:
        safe_file = remove_diacritics(norm_file)
        safe_mb = remove_diacritics(norm_mb)
        sim = max(sim, string_similarity(safe_file, safe_mb))

    return sim


def find_best_title_match(
    file_title: str,
    track_listing: dict,
    min_similarity: float = 0.70,
) -> tuple[str, float] | None:
    """
    Find the best matching track by title similarity.
    Returns (matched_title, similarity) or None.
    Ported from v5 Find-BestTitleMatch.
    """
    best_sim = 0.0
    best_title = None

    for key, mb_title in track_listing.items():
        sim = title_similarity(file_title, mb_title)
        if sim > best_sim:
            best_sim = sim
            best_title = mb_title

    if best_sim >= min_similarity and best_title:
        return (best_title, best_sim)
    return None


def clean_album_name(album_name: str) -> str:
    """
    Clean album name for MusicBrainz search.
    Ported from v5 Get-CleanAlbumName + fix_tags.py clean_album_name.
    """
    clean = album_name

    # Remove year prefix patterns
    clean = re.sub(r"^\(\d{4}\)\s*-?\s*", "", clean)
    clean = re.sub(r"^\[\d{4}\]\s*-?\s*", "", clean)
    clean = re.sub(r"^\d{4}\s*-\s*", "", clean)
    clean = re.sub(r"^\d{4}\s+", "", clean)

    # Remove year suffix patterns
    clean = re.sub(r"\s*[-\(]\s*\d{4}\s*\)?\s*$", "", clean)

    # Remove disc prefix/suffix
    clean = re.sub(r"(?i)^\[?(?:disc|cd)\s+#?\s*\d+\]?\s*-?\s*", "", clean)
    clean = re.sub(r"(?i)\s+disc\s+\d+\s*$", "", clean)
    clean = re.sub(r"(?i)\s+cd\s+#?\s*\d+\s*$", "", clean)

    # Strip known qualifier parentheticals/brackets
    clean = re.sub(
        r"(?i)\s*[\(\[]([^)\]]*?\b(?:edition|version|remaster(?:ed)?|ep|demo|split|"
        r"compilation|anniversary|bonus\s*tracks?|single)\b[^)\]]*?)[\)\]]\s*$",
        "", clean
    )

    # Strip trailing parens if remaining title >= 3 chars
    without_parens = re.sub(r"\s*\([^)]+\)\s*$", "", clean)
    if len(without_parens) >= 3:
        clean = without_parens

    # Strip trailing brackets
    without_brackets = re.sub(r"\s*\[[^\]]+\]\s*$", "", clean)
    if len(without_brackets) >= 3:
        clean = without_brackets

    return clean.strip()


def get_search_safe_string(text: str) -> str:
    """Strip special chars and diacritics for search fallback."""
    safe = remove_diacritics(text)
    safe = re.sub(r"\s*&\s*", " and ", safe)
    safe = re.sub(r"[^\w\s]", " ", safe, flags=re.UNICODE)
    safe = re.sub(r"\s+", " ", safe)
    return safe.strip()


def extract_year(folder_name: str) -> str | None:
    """Extract 4-digit year from folder name patterns."""
    for pattern in [
        r"^\[?(\d{4})\]?\s*-?\s*",
        r"^\((\d{4})\)\s*",
    ]:
        m = re.match(pattern, folder_name)
        if m:
            year = int(m.group(1))
            if 1900 <= year <= 2030:
                return str(year)
    return None
