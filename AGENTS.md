# Repository Guidelines

## Project Structure & Module Organization

The current implementation is the staged Python workflow in `pipeline/`. Run stages in numeric order: inventory, MusicBrainz resolution, fingerprinting, plan generation, validation, and execution. Shared metadata, matching, filename, API, and fingerprint helpers live in `pipeline/utils/`; path and matching policy lives in `pipeline/config.py`. Generated plans, reports, logs, and manifests are stored in `data/` and may contain machine-specific paths.

Every pre-Python generation is frozen under `legacy/`; `legacy/Restore-UnicodeFilenames-MusicBrainz-v5.ps1` is the behavioural reference. `pipeline/fix_tags.py` is a separate folder-structure-based tag fixer. Treat dry-run text and CSV files as operational artifacts, not source modules.

The `.ps1` and `.pl` scripts are the pre-Python generations of this tool. When a helper's docstring says "Ported from v5 …", the PowerShell function of that name in `legacy/Restore-UnicodeFilenames-MusicBrainz-v5.ps1` is the behavioural reference.

## Build, Test, and Development Commands

There is no build step. From the repository root, use Python 3.10+ and install the runtime libraries explicitly:

```powershell
python -m pip install -r requirements-dev.txt
python -m compileall pipeline
python -m pipeline.stage0_inventory
python -m pipeline.stage1_resolve
python -m pipeline.stage2_fingerprint
python -m pipeline.stage3_plan
python -m pipeline.stage4_validate
python -m pipeline.stage5_execute --dry-run
```

Review `data/validation_report.txt`, `approved_plan.json`, and the dry-run output before using `python -m pipeline.stage5_execute --apply`. Use `--rollback` only with a verified `backup_manifest.json`. `python -m pipeline.fix_tags` previews standalone fixes; add `--apply` only after review.

- Each stage also works as a script because it prepends its grandparent dir to `sys.path`; module form and script form are equivalent.
- Only Stage 5 and `fix_tags.py` take CLI flags. Stages 0–4 have none. Stage 1 resumes automatically from an existing `resolved.json`, and Stage 2 fingerprints only anomaly/not-found albums. To force a full re-resolve, delete `data/resolved.json`.
- Verification without touching the library: run `compileall`, then call the Stage 3 and 4 pure functions in memory against the read-only `data/runs/2026-04-13/` archive and compare their results with its saved plans and report. Do not run the stage entry points, which overwrite live artifacts.

## Pipeline Data Flow

Every stage is a pure function of the JSON files in `data/`, so the contract between stages is the file schema, not Python imports. The stage files never import each other.

| Stage | Reads | Writes | Notes |
|---|---|---|---|
| 0 inventory | `MUSIC_DIR` | `inventory.json` | Groups files into albums keyed by `album_key`; detects disc folders and flags `.m4p` as DRM. |
| 1 resolve | `inventory.json` | `resolved.json` | Per album: `status` ∈ `matched`/`anomaly`/`skipped`/`not_found`/`error`, plus `track_listing`, `match_score`. Saves every 10 albums. |
| 2 fingerprint | `resolved.json`, `inventory.json` | `fingerprints.json` | Only albums with status `anomaly` or `not_found`. Runs `fpcalc` then AcoustID. |
| 3 plan | all three above | `change_plan.json` | Per-file `confidence`, `source`, `tag_changes`, `rename`, `has_changes`. |
| 4 validate | `change_plan.json` | `validation_report.txt`, `approved_plan.json` | Sets `approved` per file. |
| 5 execute | `approved_plan.json` | `execution_log.json`, `backup_manifest.json`, `.dry-run-complete` | Only stage that mutates the library. |

Key decision points, all in `stage3_plan.py` unless noted:

- **Album status drives the title source.** `matched`/`anomaly` use the MusicBrainz release title and track listing; `skipped`/`not_found` fall back to `clean_album_name(folder)` and the filename-derived title. Track lookup order: disc-qualified key (`"1-6"`), then plain track number, then fuzzy title match at 0.70, then a fingerprint override if its score ≥ 0.8.
- **Confidence is album-level, derived from `match_score`:** ≥ 0.85 high, ≥ 0.70 medium, else (or no score) low. Stage 4 auto-approves high and medium only; low-confidence files land in `approved_plan.json` with `approved: false` and need their flag flipped by hand to apply.
- **Matching policy lives in `config.py`, not the stages.** `SKIP_ARTISTS`, `SKIP_ALBUMS` (fnmatch globs) and `HARDCODED_RELEASES` were migrated from the v5 PowerShell script and are the intended place to fix a bad match — add a hardcoded release ID rather than special-casing a stage. `MATCH_THRESHOLD` (0.70) is what separates `matched` from `anomaly` in Stage 1.
- **Tag writing is format-gated.** `WRITABLE_EXTENSIONS` excludes DRM formats; `tag_io.py` only has writers for MP3 (ID3) and M4A (MP4 atoms), and `write_tags` is what Stage 5 calls. Adding FLAC/WAV write support means extending `tag_io.py`, not Stage 5.

## Stage 5 Safety Gates

`--apply` refuses to run unless `data/.dry-run-complete` exists, and it always writes `backup_manifest.json` (original tags + paths) before touching a file. `--rollback` replays that manifest. Do not weaken or skip these checks, and never delete the marker or manifest to "clean up" — they are the only undo path. The marker is not invalidated when the plan changes, so re-run `--dry-run` after any edit to `approved_plan.json` before `--apply`.

## Coding Style & Naming Conventions

Follow existing Python style: four-space indentation, type hints on public helpers, `snake_case` functions and variables, and `UPPER_CASE` constants. Keep stage entry points named `stageN_purpose.py` and reusable logic in `pipeline/utils/`. Preserve Unicode text and use `pathlib` or `os.path` consistently within the file being edited. No formatter or linter is configured; keep imports grouped and run `compileall` before submitting.

Every stage after 0 re-wraps stdout/stderr as UTF-8 for Windows consoles. Keep that block in any new stage — MusicBrainz data contains characters the default `cp1252` console cannot encode.

## Testing Guidelines

Focused pytest tests live under `tests/`; no coverage threshold is configured. Name new files `test_<module>.py`. For pipeline changes, test against a small disposable music directory, inspect generated JSON, and exercise Stage 5 in `--dry-run` mode. Never use a production library as an unreviewed test fixture.

## Commit & Pull Request Guidelines

Never commit directly to `main`. Every change, including doc-only edits, goes on a topic branch (`git switch -c <topic>`) and reaches `main` through a pull request. Use short, imperative subjects such as `Handle multi-disc album filenames`. Keep commits scoped to one behavior. Pull requests should describe affected stages, sample inputs, validation commands, and dry-run results; call out tag or rename behavior and include redacted report excerpts when useful.

## Security & Configuration

Runtime paths, API identity, and the AcoustID credential come from environment variables or the gitignored root `.env`; `.env.example` documents the supported names. Do not commit secrets, personal paths, music files, or unredacted generated data. Redact filenames before sharing logs.

`MUSIC_DIR` may point at the production library through `.env`. Repoint it at a disposable copy before testing behaviour changes; `FPCALC_PATH` may name a local Chromaprint install or resolve from `PATH`.

`data/` is gitignored because it is generated from the real library and contains personal paths. The April 2026 artifacts are preserved locally as read-only files under `data/runs/2026-04-13/`, and the March 2026 outputs of the v5 PowerShell script under `data/runs/2026-03-04-v5/`; treat them as reference for schema shape, not as test fixtures. The only intended manual edits are flipping `approved` flags in `approved_plan.json` and deleting `resolved.json` to force a full re-resolve.
