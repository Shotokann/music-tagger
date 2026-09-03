# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

`AGENTS.md` is authoritative for layout, commands, pipeline data flow, safety gates, style, and
configuration. Keep it that way — anything another agent would also need belongs there, not here.

## Claude Code-specific bindings

- `python -m pipeline.stage5_execute --apply`, `--rollback`, and `python -m pipeline.fix_tags --apply`
  rewrite tags and rename files in the production library. Treat them as hard-to-undo actions
  under the approval rules in `~/AGENTS.md`: get an in-the-moment go-ahead before running any of
  them, even when the surrounding task was already approved. `--dry-run` and Stages 0–4 are safe
  to run without asking.
- Never point `MUSIC_DIR` at the OneDrive library in a test run you start autonomously; use a
  disposable copy as `AGENTS.md` describes.
