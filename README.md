# Music Tagger

Music Tagger is a staged Python workflow for inventorying a music library, resolving albums
against MusicBrainz, using Chromaprint/AcoustID as fallback evidence, planning and validating
tag or filename changes, and applying an approved plan.

## Setup

Use Python 3.10 or newer. Install the dependencies and create the ignored local configuration:

```powershell
python -m pip install -r requirements-dev.txt
Copy-Item .env.example .env
```

Edit `.env` with the local music-library path, `fpcalc` path, AcoustID API key, and MusicBrainz
contact address.

## Pipeline

Run the stages in order from the repository root:

```powershell
python -m pipeline.stage0_inventory
python -m pipeline.stage1_resolve
python -m pipeline.stage2_fingerprint
python -m pipeline.stage3_plan
python -m pipeline.stage4_validate
python -m pipeline.stage5_execute --dry-run
```

Review `data/validation_report.txt`, `approved_plan.json`, and the dry-run output.
Stage 5 mutates the library only with `--apply`. A successful dry run binds
`.dry-run-complete` to the exact bytes of `approved_plan.json`; `--apply` refuses a changed or
legacy marker and consumes a valid marker before its first mutation.

Each apply has a printed run ID and writes `journal.<run_id>.jsonl` plus
`backup_manifest.<run_id>.json`. To preview or perform recovery, use the exact ID:

```powershell
python -m pipeline.stage5_execute --rollback --run-id <run_id> --dry-run
python -m pipeline.stage5_execute --rollback --run-id <run_id>
```

An interrupted or unresolved run blocks later applies until rollback finishes cleanly. If a
human investigation decides that a run must not be rolled back, freeze it explicitly:

```powershell
python -m pipeline.stage5_execute --acknowledge-run <run_id> --note "reason"
```

Acknowledgement is not recovery: it permanently disables rollback through Stage 5 for that
run. Legacy `backup_manifest.json` and `execution_log.json` are preserved as evidence and are
never overwritten by the hardened executor.
