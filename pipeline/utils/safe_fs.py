"""Windows filesystem safety primitives used by mutating pipeline stages."""

import hashlib
import json
import os
from typing import Any


class SafeFilesystemError(Exception):
    """Base class for filesystem safety failures."""


class IdentityUnavailable(SafeFilesystemError):
    """Raised when Windows cannot provide a stable file identity."""


class CollisionError(SafeFilesystemError):
    """Raised when a rename destination is occupied by another file."""


class StrandedFileError(SafeFilesystemError):
    """Raised when a failed case-only rename cannot restore its source name."""

    def __init__(self, tmp_path: str):
        super().__init__(f"File stranded at temporary path: {tmp_path}")
        self.tmp_path = tmp_path


def sha256_file(path: str) -> str:
    """Return the SHA-256 digest of a file's raw bytes."""
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_identity(path: str) -> tuple[str, str]:
    """Return the stable Windows volume/file-index identity for *path*."""
    stat_result = os.stat(path, follow_symlinks=False)
    if stat_result.st_ino == 0:
        raise IdentityUnavailable(f"File identity unavailable: {path}")
    return str(stat_result.st_dev), str(stat_result.st_ino)


def link_count(path: str) -> int:
    """Return the number of hard links to *path*."""
    return os.stat(path, follow_symlinks=False).st_nlink


def is_case_only_rename(src: str, dst: str) -> bool:
    """Return whether two same-directory paths differ only by letter case."""
    src_abs = os.path.abspath(src)
    dst_abs = os.path.abspath(dst)
    return (
        os.path.normcase(os.path.dirname(src_abs))
        == os.path.normcase(os.path.dirname(dst_abs))
        and os.path.normcase(src_abs) == os.path.normcase(dst_abs)
        and src_abs != dst_abs
    )


def temp_name_for(dst: str, run_id: str) -> str:
    """Return the deterministic temporary name for a case-only rename."""
    return f"{dst}.{run_id}.tmp"


def rename_exact(src: str, dst: str, run_id: str) -> str:
    """Rename without replacement, including exact-case changes on Windows."""
    if os.path.exists(dst) and not os.path.samefile(src, dst):
        raise CollisionError(f"Rename destination exists: {dst}")

    if is_case_only_rename(src, dst):
        tmp = temp_name_for(dst, run_id)
        if os.path.exists(tmp):
            raise CollisionError(f"Temporary rename path exists: {tmp}")
        os.rename(src, tmp)
        try:
            os.rename(tmp, dst)
        except BaseException:
            try:
                os.rename(tmp, src)
            except BaseException as restore_error:
                raise StrandedFileError(tmp) from restore_error
            raise
        return dst

    os.rename(src, dst)
    return dst


_RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{number}" for number in range(1, 10)),
    *(f"LPT{number}" for number in range(1, 10)),
}
_ILLEGAL_CHARS = set('<>:"/\\|?*')


def _utf16_length(value: str) -> int:
    return len(value.encode("utf-16-le")) // 2


def validate_windows_path(path: str) -> list[str]:
    """Return Windows path violations; an empty list means the path is valid."""
    violations: list[str] = []
    if _utf16_length(path) >= 260:
        violations.append("full path is 260 UTF-16 code units or longer")

    drive, tail = os.path.splitdrive(path)
    components = [part for part in tail.replace("/", "\\").split("\\") if part]
    for component in components:
        if _utf16_length(component) > 255:
            violations.append(f"component exceeds 255 UTF-16 code units: {component!r}")
        if component.endswith("."):
            violations.append(f"component has a trailing dot: {component!r}")
        if component.endswith(" "):
            violations.append(f"component has a trailing space: {component!r}")
        base = component.split(".", 1)[0].upper()
        if base in _RESERVED_NAMES:
            violations.append(f"reserved device name: {component!r}")
        if any(char in _ILLEGAL_CHARS or ord(char) < 32 for char in component):
            violations.append(f"component contains an illegal character: {component!r}")
    return violations


def contained(path: str, root: str) -> bool:
    """Return whether *path* resolves inside *root* (or is the root itself)."""
    resolved_path = os.path.normcase(os.path.realpath(path))
    resolved_root = os.path.normcase(os.path.realpath(root))
    return resolved_path == resolved_root or resolved_path.startswith(
        resolved_root.rstrip("\\/") + os.sep
    )


def write_json_atomic(path: str, obj: Any) -> None:
    """Durably publish JSON by replacing the destination with a flushed temp file."""
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8", newline="\n") as output:
        json.dump(obj, output, indent=2, ensure_ascii=False)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(tmp_path, path)
