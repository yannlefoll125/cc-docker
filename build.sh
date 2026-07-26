#!/usr/bin/env bash
# build.sh — modular cc-docker build engine: builds the reusable *building blocks*
# (base, stack/* modules, toolchain/* images). It does NOT build the per-project
# assembled finals — the `cc` launcher does those lazily. See
# docs/modular-build-engine/roadmap.md.
#
# Usage:
#   ./build.sh                 # base + all toolchain/* + all stack/*  (pre-warm / CI)
#   ./build.sh node zulu       # base + the named stack modules only   (launcher path)
#   ./build.sh base            # just base
#
# `base` is always built first — stack modules and toolchain images stage FROM base.
# Every build is a plain `docker build` (no presence check): Docker's layer cache
# makes it a no-op when nothing changed and a correct rebuild when it did.
set -euo pipefail
cd "$(dirname "$0")"

module_version() {  # $1=stack name → prints version: value from module.yml
  grep -E '^version:' "stack/$1/module.yml" | head -1 \
    | sed -E "s/^version:[[:space:]]*//; s/^[\"']//; s/[\"']$//"
}

build_base() {
  echo ">>> building base"
  docker build -t base base
}

build_stack() {
  local name=$1 dir="stack/$1" version
  [[ -f "$dir/module.yml" ]] || { echo "error: no such stack module: '$name' ($dir/module.yml missing)" >&2; exit 1; }
  version="$(module_version "$name")"
  [[ -n "$version" ]] || { echo "error: stack module '$name' has no version: in module.yml" >&2; exit 1; }
  echo ">>> building stack/$name:$version"
  docker build -t "stack/$name:$version" "$dir"
}

build_toolchain() {
  local name=$1 dir="toolchain/$1"
  [[ -f "$dir/Dockerfile" ]] || return 0
  echo ">>> building cc-$name"
  if [[ "$name" == dev ]]; then
    # cc-dev's Dockerfile also COPYs the shared bootstrap/ entrypoint chain
    # (cc-wrapper.sh, run-as-hostuser.sh, sandbox.md), so it needs the repo
    # root as build context, not just toolchain/dev.
    docker build -t "cc-$name" -f "$dir/Dockerfile" .
  else
    docker build -t "cc-$name" "$dir"
  fi
}

# base first — everything else stages FROM it.
build_base

if [[ $# -eq 0 ]]; then
  # no args: full pre-warm — every toolchain image and every stack module.
  for d in toolchain/*/Dockerfile;  do [[ -f "$d" ]] && build_toolchain "$(basename "$(dirname "$d")")"; done
  for d in stack/*/module.yml;      do [[ -f "$d" ]] && build_stack     "$(basename "$(dirname "$d")")"; done
else
  # scoped: base + the named stack modules ("base" is a no-op, already built).
  for arg in "$@"; do
    [[ "$arg" == base ]] && continue
    build_stack "$arg"
  done
fi
