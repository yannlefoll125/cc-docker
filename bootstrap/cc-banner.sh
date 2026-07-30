#!/bin/bash
# cc-banner.sh — SessionStart hook. Prints an SSH-MOTD-style banner to the HUMAN
# summarizing who is logged in, for which organization, how (Anthropic API key vs
# Claude subscription via OAuth), and a short note on what the sandbox is.
#
# It must emit JSON with a `systemMessage` field: a SessionStart hook's plain
# stdout is injected into Claude's context, NOT shown in the terminal — only
# `systemMessage` is surfaced to the user.
#
# Baked into the image at /cc-banner.sh and wired in via `claude --settings
# /banner-settings.json` (run-as-hostuser.sh). Kept to pure shell on purpose: the
# base runtime image ships neither python nor jq (only stack modules add them), so
# the JSON config is scraped with grep/sed. Auth/account info is read, never the
# secrets themselves — the API key and OAuth tokens are never printed.

set -u

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# First "key": "value" string match in a JSON file (compact or pretty-printed).
json_str() {
  grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
    | head -1 | sed -E 's/^.*:[[:space:]]*"(.*)"$/\1/'
}

lines=()
lines+=("cc-docker sandbox — ${PROJECT_DIR##*/}")
lines+=("────────────────────────────────────────────────────────────")

if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -r /run/secrets/anthropic_api_key ]; then
  # API-key auth: identity/org aren't available offline (they belong to the key).
  lines+=("$(printf '%-12s: %s' 'Auth' 'Anthropic API key')")
  lines+=("$(printf '%-12s: %s' 'Billing' "the API key's organization")")
else
  cfg="$CONFIG_DIR/.claude.json"
  cred="$CONFIG_DIR/.credentials.json"
  name="$(json_str "$cfg" displayName)"
  email="$(json_str "$cfg" emailAddress)"
  org="$(json_str "$cfg" organizationName)"
  plan="$(json_str "$cred" subscriptionType)"
  [ -z "$plan" ] && plan="$(json_str "$cfg" seatTier)"
  # Title-case the plan word: team -> Team, max -> Max.
  [ -n "$plan" ] && plan="$(printf '%s' "${plan:0:1}" | tr '[:lower:]' '[:upper:]')${plan:1}"

  who="$email"
  [ -n "$name" ] && [ -n "$email" ] && who="$name <$email>"

  if [ -n "$who" ]; then
    lines+=("$(printf '%-12s: %s' 'Logged in' "$who")")
  else
    lines+=("$(printf '%-12s: %s' 'Logged in' 'not yet — first run prompts an OAuth login')")
  fi
  [ -n "$org" ] && lines+=("$(printf '%-12s: %s' 'Organization' "$org")")
  lines+=("$(printf '%-12s: %s' 'Auth' "Claude ${plan:-subscription} plan (OAuth)")")
fi

lines+=("────────────────────────────────────────────────────────────")
lines+=("Isolated Docker container. The host filesystem, your host")
lines+=("credentials, and other projects are NOT visible. Writable: the")
lines+=("mounts declared in cc-docker.yml plus ~/.claude (a per-project")
lines+=("volume); everything else is read-only or absent.")

# Join the lines with real newlines, then JSON-escape for the systemMessage string.
msg="$(printf '%s\n' "${lines[@]}")"
esc="$(printf '%s' "$msg" \
  | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
  | awk 'BEGIN{ORS=""} {print sep $0; sep="\\n"}')"
printf '{"systemMessage":"%s"}\n' "$esc"
