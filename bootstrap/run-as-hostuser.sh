#!/bin/bash

env

# Optional API-key auth via Docker secret (see cc-docker.yml's
# anthropic_api_key_file). Exported here, after the `env` dump above, so the
# key never lands in that output. When absent, this is a no-op and claude
# falls back to the mounted ~/.claude OAuth login.
if [ -r /run/secrets/anthropic_api_key ]; then
  export ANTHROPIC_API_KEY="$(cat /run/secrets/anthropic_api_key)"
fi

[ -n "$GIT_USER_NAME" ]  && echo "setting name '$GIT_USER_NAME'" && git config --global user.name  "$GIT_USER_NAME"
[ -n "$GIT_USER_EMAIL" ] && echo "setting email '$GIT_USER_EMAIL'" && git config --global user.email "$GIT_USER_EMAIL"
git config --global --add safe.directory "$PROJECT_DIR"

permission_mode_args=()
[ -n "$CC_PERMISSION_MODE" ] && permission_mode_args=(--permission-mode "$CC_PERMISSION_MODE")

# Tells the sandbox-context SessionStart hook (ssh: feature — see cc-config's
# sync_sandbox_context_hook) that this session already gets /sandbox.md as a
# real system prompt, so the hook must not inject it a second time as context.
export CC_SANDBOX_PROMPTED=1

clear
claude --append-system-prompt "$(cat /sandbox.md)" "${permission_mode_args[@]}" "$@"
clear