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
Stage 5 mutates the library only with `--apply`, and refuses to do so until a dry run has
created `.dry-run-complete`. It writes `backup_manifest.json` before changing files;
`--rollback` must be used only with a verified manifest. Because the marker is not invalidated
when the plan changes, run `--dry-run` again after every manual approval edit and before every
`--apply`.
