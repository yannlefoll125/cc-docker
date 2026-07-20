#!/bin/bash

env

[ -n "$GIT_USER_NAME" ]  && echo "setting name '$GIT_USER_NAME'" && git config --global user.name  "$GIT_USER_NAME"
[ -n "$GIT_USER_EMAIL" ] && echo "setting email '$GIT_USER_EMAIL'" && git config --global user.email "$GIT_USER_EMAIL"
git config --global --add safe.directory "$PROJECT_DIR"

clear
claude --append-system-prompt "$(cat /sandbox.md)" "$@"
clear