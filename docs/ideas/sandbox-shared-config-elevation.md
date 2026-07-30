# Idea: Per-Project CC Sandbox Isolation + Controlled Shared Config

> **Status (2026-07-30): the "Core fix" baseline below is now IMPLEMENTED.**
> `generate-compose.py` mounts `~/.claude` as a per-project Docker named volume
> (`cc-claude-<slug>`) and sets `CLAUDE_CONFIG_DIR=/home/hostuser/.claude`, so
> config, credentials, transcripts/memory, and `.claude.json` all live inside
> the volume. `cc-wrapper.sh` chowns the mountpoint on start; the host UID/GID
> arrives via `CC_HOST_UID`/`CC_HOST_GID`. See `docs/security-audit.md` #1/#2
> status notes. The remaining sections (shared read-only `commands/`+`skills/`
> and the write-elevation question) are the still-open follow-ups.

## Baseline assumption

**`~/.claude` inside the container is now a sandbox-specific Docker named
volume, not a host bind mount.** This is already implemented (see "Core fix"
below for the mechanism). Everything past this point — including the shared
`commands/`/`skills/` refinement and the write-elevation question — assumes
that starting point: no host filesystem is involved, and each project has
its own isolated, persistent volume for Claude Code config, credentials,
history, memory, and cache.

## Problem (background — already solved by the baseline above)

Current setup hardens `~/.claude` on the host via bind mounts, which:
- Collides with Claude Code's OAuth credentials file (`.credentials.json` and
  `history.jsonl` were getting null-masked, causing a login-success-then-fail
  loop).
- Doesn't isolate state (history, memory, cache) between projects sharing the
  same host `~/.claude`.

## Core fix: per-project config volume, no host bind mount

Point Claude Code's config dir at a **named Docker volume**, not a host bind
mount, via `CLAUDE_CONFIG_DIR`. One volume per project.

```bash
docker volume create claude-config-<project-name>
```

```yaml
environment:
  - CLAUDE_CONFIG_DIR=/home/hostuser/.claude-sandbox
volumes:
  - claude-config-<project-name>:/home/hostuser/.claude-sandbox
```

Properties:
- **No host leakage** — nothing on the host filesystem to protect; the volume
  never touches host paths.
- **No cross-project leakage** — each project's history/memory/cache/creds
  are isolated in their own volume.
- **No repeated OAuth** — the volume persists across container restarts, so
  login survives until the volume is deliberately removed.
- **Safe to run unrestricted** — since the sandbox boundary (no host mount,
  no cross-project mount) does the real safety work, CC can run in auto mode
  or fully unrestricted (`bypassPermissions`) *inside* the container without
  that being reckless.

## Refinement (later): shared, read-only `commands/` and `skills/`

Once per-project isolation is solid, reintroduce sharing deliberately rather
than defaulting to shared state:

- Mount a separate shared volume **read-only** into each project's config
  dir, scoped to just `commands/` and `skills/` (file-level, not merging the
  whole `~/.claude` tree back together).
- Keeps credentials/history/memory strictly per-project even as
  commands/skills become shared.
- Audit any skill/command that hardcodes `~/.claude/...` paths before
  symlinking — they may assume the old shared location.

## Open question: how does CC get *write* access to shared config?

CC is often the one drafting a new command/skill worth sharing. Two patterns:

### Pattern A — Staging + promotion (preferred)

- CC gets a **local, always-writable staging dir** inside its own
  per-project volume (e.g. `commands-staging/`), separate from the
  read-only shared mount.
- CC drafts/iterates freely there, fully unrestricted, zero risk to shared
  state.
- Promotion to the shared volume happens via a **host-side step** (script or
  manual review) — not something triggered from inside the container.
- Mirrors the existing git-like model: draft → review → commit.
- Boundary is enforced by something CC cannot reach, regardless of its
  permission mode.

### Pattern B — Temporary remount elevation

- Shared volume is read-only by default; a host-side control (script,
  sidecar, or manual command) remounts it `rw` for a bounded window, then
  back to `ro`.
- Only a real boundary if the toggle is **not reachable from inside the
  container** — if CC can trigger its own elevation, it's effectively
  permanent write access with extra steps.
- Only makes sense if a human (or an out-of-container watcher) is the one
  flipping the mount each time — which cuts against the "convenience" goal.

**Leaning: Pattern A.** Keeps the "run CC fully unrestricted" goal intact
(unrestricted *within* its own staging area), and never asks the shared/host
boundary to trust CC's judgment.

## Next step (not yet done)

Sketch the actual promote script / docker-compose config for Pattern A when
ready to implement.
