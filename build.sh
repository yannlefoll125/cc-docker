#!/usr/bin/env bash
# build.sh — modular cc-docker build engine.
# See docs/modular-build-engine/roadmap.md (design in docs/modular-build-engine/README.md).
#
# Usage (target, roadmap P4):
#   ./build.sh [module ...]   # build `base` + the named stacks (+ toolchain images)
#   ./build.sh                # no args → base + all toolchain/* + all stack/*
#
# STUB: not implemented yet (roadmap P4). The frozen pre-modular builder — which
# still builds the old cc-* images — lives at legacy/build.sh.
set -euo pipefail

echo "build.sh: modular builder not implemented yet (see docs/modular-build-engine/roadmap.md, P4)." >&2
echo "         For the pre-modular images, use: legacy/build.sh" >&2
exit 1
