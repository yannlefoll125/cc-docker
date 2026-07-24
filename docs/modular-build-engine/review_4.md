# Review 4 — Modular build engine design doc

> Fourth pass over [`README.md`](README.md), after `review.md`, `review_2.md`, and
> `review_3.md` were all incorporated. The doc is mature and internally consistent
> now; returns are diminishing. This pass surfaces **one substantive gap the
> review-3 #2 resolution newly created**, plus a few minor residuals. Findings only.

## Substantive

**1. How does the *host* obtain module names + versions? The scoped `build.sh` and
version-aware tags both need host-side `module.yml` reads the design otherwise
avoids.** Review 3 resolved #2 by having the launcher invoke `build.sh base
<selected stacks>` on every launch (decision lines 652–658, flow line 314), and #14
made stack tags version-aware — `stack/node:20`, with the version living in
`module.yml` (lines 392–401). Both push work onto the host (bash) that the doc's own
"single source of truth" principle deliberately kept *out* of bash:

- **Names.** To run `build.sh base node zulu`, the launcher needs the *list of module
  names*. The one host-readable artifact is `.cc-docker/assembled.tag` = `cc/node-zulu`.
  Deriving names by stripping `cc/` and splitting on `-` is fragile: a module named
  `foo-bar` (hyphen is legal in the `stack/*` namespace) makes `cc/foo-bar` ambiguous.
  So the launcher must either bash-parse `modules:` out of `cc-docker.yml` — the exact
  thing decision C (single tag source) avoided — or cc-config must emit a **second
  sidecar** (e.g. `.cc-docker/assembled.modules`, the raw name list).
- **Versions.** `build.sh` tags `stack/node:20`, but the `20` lives in
  `stack/node/module.yml`. So `build.sh` (host bash) must read each module's
  `version:` to build-and-tag correctly — host-side YAML reading again.

Neither is fatal (there's precedent: `init-cc.sh` already `grep`s
`anthropic_api_key_file` out of `cc-docker.yml`, line 198), but the doc is silent on
*where the host gets names and versions*, and the answer touches the same
"keep YAML parsing in containers" line the tag decision drew. Recommend: cc-config
writes a names sidecar alongside `assembled.tag`, and either `build.sh` is allowed a
documented light `grep '^version:'` on `module.yml`, or cc-config/cc-assemble emit
the `stack/<name>:<version>` build list too. Pick one and state it — right now the
scoped-`build.sh` step has no defined input on the host.

## Minor / residual

**2. Launcher mode-detection (modular vs legacy) is never spelled out.** The launcher
must "branch on `modules:` vs legacy `image:`" (lines 441, 483), but the doc doesn't
say *how* it detects the mode without bash-parsing `cc-docker.yml`. The clean answer
falls out of #1: cc-config only writes `.cc-docker/assembled.tag` (and the proposed
names sidecar) in modular mode, so "sidecar present → modular" is the branch. Worth
one sentence, since it's the same host/YAML tension.

**3. Decision-log entry still says versions "can coexist" without the review-3
caveat.** The body was correctly reframed to call coexistence "only *theoretical*
today" (lines 395–397), but decision line 637 still reads "modules tag as
`stack/<name>:<version>` … so versions can coexist." Minor drift between body and log;
the log entry could get the same "(cache-busting; coexistence needs separate module
dirs)" note.

**4. The flock dir `$CC_DOCKER_DIR/.locks/` assumes the install dir is user-writable.**
Lines 346–350 put the shared lock at `$CC_DOCKER_DIR/.locks/<sanitized-tag>.lock`. If
cc-docker is ever installed to a root-owned/system location (e.g. `/opt/cc-docker`),
the invoking user can't create `.locks/`. A user-writable, cross-project location
(`$XDG_RUNTIME_DIR/cc-docker/` or `/tmp/cc-docker-$UID/`) is a safer home for a
purely-runtime lock. Low priority, but `$CC_DOCKER_DIR` isn't guaranteed writable.

**5. The "a second or two" latency estimate may undercount.** Lines 351–357 describe
every launch as building `base` + the project's stacks + the final — with two
modules that's **four** sequential `docker build` invocations, each paying its own
context-send + cache-hash. "A second or two total" (line 355) reads optimistic for 4
back-to-back builds; the honest figure is probably a few seconds, which is also
exactly why the fast-path open question (lines 529–532) exists. Consider softening
the estimate or cross-referencing that open question here.

## Otherwise

Everything flagged in passes 1–3 remains resolved, and the review-3 batch (concept
diagram, per-tag flock, runtime_deps-as-post-POC, scoped `build.sh`, bootstrap-scoped
context) landed cleanly. Finding #1 is the only item I'd treat as blocking before
implementation, because the scoped-`build.sh` step currently has no defined host-side
input; the rest are polish.
