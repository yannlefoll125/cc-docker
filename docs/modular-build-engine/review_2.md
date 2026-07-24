# Review 2 — Modular build engine design doc

> Second pass over [`README.md`](README.md). The [first review](review.md) covered
> internal contradictions, stale "today" claims, and high-level gaps. This pass
> deliberately looks at different angles the first one didn't: **buildability
> mechanics** (build context, image references), **schema & validation**, the
> **correctness of the assembly algorithm**, and **concrete migration breakage** in
> the existing scripts. Findings only — no edits to the design doc. There is minimal
> overlap with review.md; where a point extends a review-1 finding it says so.

## Buildability — will the assembled `docker build` actually work?

**1. The assembled build context is never specified.** The assembled Dockerfile
ends with `COPY <bootstrap scripts> ...` (line 318), and cc-assemble writes that
Dockerfile into the *project's* `.cc-docker/` (line 276). But the bootstrap scripts
live in the **cc-docker install dir** (`bootstrap/`, line 362), not in the project.
So the host `docker build` step needs `-f .cc-docker/assembled.Dockerfile` with its
**context pointed at `$CC_DOCKER_DIR/bootstrap/`** (or the repo root) — not the
project. The doc never pins down the `-f`/context split, yet it's the one thing that
determines whether `COPY` can find its sources. This is the most concrete
buildability gap: as drawn, the COPY has no valid context.

**2. `COPY --from=stack/node` depends on a local-only image with an implicit tag.**
Lines 313–314 use `COPY --from=stack/node`. That resolves to `stack/node:latest`,
and since these modules are never pushed to a registry, the image **must already
exist locally** or BuildKit will attempt a registry pull and fail. The doc relies on
"build.sh builds base + stacks first," but doesn't state the tag (`:latest`
implied) or that a missing/mistagged module surfaces as a confusing pull error
rather than a clear "run build.sh first." Worth an explicit note on tagging + a
preflight existence check with a good error message.

**3. New `base` must drop the `ENTRYPOINT` and the scripts — stated only by
implication.** Today `images/base/Dockerfile` bakes the three scripts *and* sets
`ENTRYPOINT ["/cc-wrapper.sh"]`. In the new model those move to `bootstrap/` and are
baked into finals, so new `base` has no scripts and should set no entrypoint. That's
correct, but the doc never says base loses its ENTRYPOINT — and `stack/*` staging
images (`FROM base`) would then inherit whatever base declares. Harmless (staging is
never run), but the base Dockerfile's loss of ENTRYPOINT should be called out since
finals now own it.

## Schema & validation

**4. The `cc-docker.yml` schema migration is unaddressed — and it's mandatory
work.** `toolchain/config/cc-docker.schema.json` has `"required": ["image"]` (line
7) and `generate-compose.py` reads `image = config["image"]` unconditionally (line
192, a hard `KeyError` if absent). Modular mode has no `image:` — it has `modules:`.
So the schema must: make `image` optional, add a `modules` array, and encode the
coexistence rule (see #5). The doc says cc-config is "extended," but never mentions
the schema file or this required relaxation — a reader implementing the POC would hit
a schema-validation failure on the very first modular `cc-docker.yml`.

**5. `image:` vs `modules:` precedence is undefined (both-present / neither-present).**
The coexistence rule (lines 261–266) is "`modules:` → modular, `image:` → legacy."
But: what if **both** are present? What if **neither**? The schema can't express
"exactly one of" with the current `required: ["image"]`; it needs a `oneOf`/`anyOf`
constraint. Undefined precedence here is a real footgun during migration when a
config is edited from one form to the other.

**6. `module.yml` has no schema or validator, breaking the project's own pattern.**
The project validates `cc-docker.yml` against a JSON Schema with clear per-error
messages (`validate_config`, lines 40–49). `module.yml` is presented only as a
"draft schema" (line 155) with no mention of a validator inside cc-assemble. Given
module.yml drives `COPY`/`ENV` codegen, an unvalidated `artifacts:`/`env:` typo
would produce a broken Dockerfile far downstream. A `module.schema.json` mirroring
the existing pattern is the natural fix and should be a POC checklist item.

## Assembly-algorithm correctness

**7. The deterministic tag depends on cross-language, cross-locale sort agreement.**
Review 1 flagged that cc-config *and* cc-assemble both compute the tag (dual source
of truth). Sharper point: the tag is `<sorted,names>` (line 296) and PATH is merged
"in sorted-module order" (line 207). cc-config is Python (`sorted()`, Unicode
codepoint order) and the launcher/build side is bash (`sort`, **locale-dependent**
by default). If those disagree for any module set, cc-config writes
`image: cc/node-zulu21` into compose while the launcher builds/looks for a different
ordering — the compose reference and the built tag diverge and `compose run` fails
on a missing image. The doc must specify one canonical sort (e.g. `LC_ALL=C`,
ASCII) and ideally compute the tag in exactly one place.

**8. `build_deps` in the module examples contradict the "FROM base gives them for
free" decision.** The resolved staging decision (lines 240–248) says staging
`FROM base` gives modules `curl`/`ca-certificates`/`build-essential` "for free." Yet
both module.yml examples still declare `build_deps: [curl, ca-certificates]` (lines
163, 189). Either base already provides them (making these `build_deps` redundant
no-ops) or it doesn't (contradicting the decision). Also note — per review 1 #5 —
`build-essential` is **not** in base today, so "for free" is only true for
`curl`/`ca-certificates`. Reconcile: decide what base guarantees and strip
redundant `build_deps`, or drop the "for free" claim.

**9. `runtime_deps` "rely on base already containing them" quietly re-bloats band 1.**
The two satisfaction options (lines 221–227) are (a) base already has the package or
(b) union `apt install` in the final. Option (a) means growing `base` to satisfy one
module — but `base` is band 1 (least volatile); every addition bloats *every*
assembled image and busts the base cache for *all* of them, which is exactly the
cascade the design exists to avoid. The doc presents (a) and (b) as equals; (a)
should be discouraged with that rationale. (Extends review 1 #10, which was about
where the union install lands in band order.)

**10. Baked `COREPACK_HOME` is root-owned; runtime `corepack prepare` by the mapped
user will fail.** `corepack enable` runs at module-build time as root, and
`COREPACK_HOME=/usr/local/node/corepack` lives inside the copied (root-owned) dir
(lines 104, 180). The container runs as the mapped host user (`run-as-hostuser.sh`,
`gosu`). Pre-prepared yarn/pnpm work read-only, but any runtime `corepack prepare`
/ version switch needs to write under `COREPACK_HOME` and will hit EACCES. Either
document that only the baked PM versions are usable, or `chmod -R a+rwX` the corepack
dir at module-build time (the pattern `cc-full` already uses for Rust's
`/opt/rust`).

## Concrete migration breakage in existing scripts

**11. `init-cc.sh` hard-codes `$CC_DOCKER_DIR/images/` — which the migration
empties.** init-cc iterates `for d in "$CC_DOCKER_DIR/images/"/*/` (line 21) to build
its menu. The migration moves `images/` to `legacy/images/` (line 352), so the menu
goes empty and init-cc errors ("no images found", line 26). Review 1 #7 noted the
*flow* is unaddressed; concretely, this exact loop and error path break and must be
rewritten to offer modules. (`init-cc.sh` also still writes `image: ${chosen_image}`
at lines 100–107 — it never emits `modules:` at all.)

**12. `build.sh` discovery globs `images/*/Dockerfile toolchain/*/Dockerfile` and
the `FROM cc-*` graph — both obsolete under the new layout.** The current builder
(line 36) discovers via those globs and infers deps from `FROM cc-<name>` /
`COPY --from=cc-<name>` (lines 65–68). The new top-level layout has `base/` +
`stack/*/` (no `images/`, no `cc-` prefix, no inter-image `FROM cc-*` chain), so the
NEW `build.sh` is a near-total rewrite, not an extension — build "base, then all
`stack/*`" as stated (line 470), but the doc should be explicit that none of the
current discovery/topo-sort machinery carries over (only the legacy copy keeps it).

**13. Per-project regeneration of an identical assembled Dockerfile is redundant.**
cc-assemble writes the Dockerfile per project into `.cc-docker/` (line 276), but the
resulting image tag is **global per module set** (`cc/node-zulu21` shared across all
projects with the same modules, line 296). So N projects with `modules: [node]` each
regenerate a byte-identical Dockerfile to build one shared image. Not wrong, but the
per-project placement implies per-project images, which isn't the case — a caching
note (or a shared assemble dir keyed by tag) would clarify intent.

## Supply chain / reproducibility

**14. Module artifacts have no version or checksum in `module.yml`.** The node/zulu
modules download tarballs, and the doc calls versions "pinned" (line 55), but the
`module.yml` draft (lines 157–196) has **no `version` and no checksum/digest field**
— pinning lives only inside the staging Dockerfile, invisible to the assembler and
unverified. For reproducible, tamper-evident module builds, module.yml should carry
the version (also useful for tagging `stack/node:20` and cache-busting per #8 of
review 1) and ideally an expected SHA. Currently a silently-changed upstream tarball
would be baked with no signal.

## Minor

- **`stack/node` etc. use an implicit `:latest` tag**, so there's no way to have two
  node versions coexist as modules; fine for the POC (one version) but worth noting
  as a constraint of name-only tags.
- **`completions/build.bash`** (referenced in build.sh's header, lines 17–18) moves
  to `legacy/` per the layout (line 354); the new top-level `build.sh` ships without
  completion. Trivial, but the header comment shouldn't be copied verbatim into the
  new script.
