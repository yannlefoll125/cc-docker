# Idea: SSH-MOTD-Style Startup Banner via SessionStart Hook

## Goal

When a Claude Code session starts inside a project sandbox, show a visible
banner (like an SSH login MOTD) summarizing the environment: which sandbox,
which config volume is mounted, who/what is running, and any other useful
heads-up info — before the session becomes interactive.

## Native support status

No first-class "custom welcome screen" feature exists yet. `companyAnnouncements`
in `settings.json` can inject static text into CLI output, but only augments
the fixed banner — it can't replace it or show dynamic content. Fully
custom welcome screens (custom title, image, tips) are still open feature
requests, not shipped.

## Mechanism: `SessionStart` hook

A `SessionStart` hook fires once per session — after config loads, before
the first prompt — and re-fires on `/clear`. It's the documented, supported
way to run environment setup and surface a banner.

**Critical detail:** plain `stdout` from the hook is *not* shown to the
user — it gets silently injected into Claude's own context instead. To make
the banner actually visible in the terminal, the hook must emit JSON with a
`systemMessage` field.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/banner.sh" }
        ]
      }
    ]
  }
}
```

```bash
#!/usr/bin/env bash
# .claude/hooks/banner.sh
BANNER=$(cat <<EOF
┌──────────────────────────────────────────┐
│  Sandbox: ${PROJECT_NAME}
│  Config volume: ${CLAUDE_CONFIG_DIR}
│  User: $(whoami)
│  Host: $(hostname)
│  Mounts:
$(mount | grep -E '/workspace|claude-config' | sed 's/^/│    /')
└──────────────────────────────────────────┘
EOF
)
python3 -c "
import json
print(json.dumps({'systemMessage': '''$BANNER'''}))
"
```

Since the hook is a real shell script, it can surface anything useful:
mounted volumes, `CLAUDE_CONFIG_DIR`, active user, hostname, git branch,
whether the shared read-only `commands/`/`skills/` volume is mounted, etc.

## Constraints to design around

- **No `/dev/tty` access.** Command hooks run without a controlling
  terminal (as of Claude Code 2.1.139+), so raw ANSI escape sequences /
  direct terminal painting won't work. Stick to plain text and box-drawing
  characters passed via `systemMessage`.
- **Two output channels, two audiences.** `systemMessage` = visible to the
  human. `hookSpecificOutput.additionalContext` = visible to Claude itself.
  Worth emitting both if the banner content (e.g. "you're in an isolated
  sandbox, don't assume host state") is also useful for Claude to know.
- **Keep it fast.** Slow `SessionStart` hooks delay startup, and a failing
  hook can block the session — keep logic simple/fast or push slow checks
  async.

## Fit with sandbox isolation work

Natural pairing with the per-project Docker volume approach: the banner
becomes the human-facing confirmation that isolation is actually in effect
for *this* session — which volume is mounted, which project it's scoped to
— rather than trusting it silently.

## Status: implemented

Shipped as a baked-in image feature (not a per-project `.claude/` file):

- `bootstrap/cc-banner.sh` — the `SessionStart` hook. Pure shell: the base
  runtime image ships neither python nor jq (only stack modules add them), so it
  scrapes `$CLAUDE_CONFIG_DIR/.claude.json` (`displayName`, `emailAddress`,
  `organizationName`) and `.credentials.json` (`subscriptionType`) with
  `grep`/`sed`. It distinguishes **Anthropic API key** auth (`ANTHROPIC_API_KEY`
  / `/run/secrets/anthropic_api_key` present) from **Claude subscription via
  OAuth**, and prints a short note on what the sandbox is. Secrets themselves are
  never printed. Output is `{"systemMessage": …}` so it's visible to the human.
- `bootstrap/banner-settings.json` — registers the `SessionStart` hook.
- `bootstrap/run-as-hostuser.sh` — launches claude with
  `--settings /banner-settings.json`, so the hook is trusted (explicitly passed
  by the launcher) and merges with the user's own settings.
- `toolchain/assemble/assemble.py` — band 4 COPYs both files into the final image.

Notes for anyone extending it: there is **no `PROJECT_NAME`** env var — the
banner derives the project name from `PROJECT_DIR`. Building the `systemMessage`
JSON by hand needs real escaping (backslash/quote) — the script joins its lines
and escapes them rather than splicing text into a `'''…'''` Python literal.
Takes effect after a `cc --build` (baked into the image).
