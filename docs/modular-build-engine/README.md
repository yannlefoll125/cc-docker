# Modular build engine — exploration

> **Status:** POC **implemented** (branch `modular-build-engine`, phases P0–P6 in
> [`roadmap.md`](roadmap.md)) after four code-grounded review passes (`review.md` …
> `review_4.md`). Acceptance demos pass, including the headline: editing a bootstrap
> script rebuilds only the bootstrap layer (toolchains stay cached) — the cascade is
> gone. Remaining `_(open, deferred)_` items are explicitly post-POC. Living doc.
>
> **Implementation plan:** see [`roadmap.md`](roadmap.md) — phased, dependency-ordered
> tasks with verification steps. This doc holds the design + rationale; the roadmap
> holds the build sequence.

## Why

`make build` (→ `build.sh`) rebuilds large parts of the image tree from scratch
far too often. The trigger that surfaced it: editing a runtime script
(`run-as-hostuser.sh`) forced a full rebuild of every image, ~5–10 min.

### Root cause

The cascade is **not** caused by "too many images." It's caused by some
runnable images also being **parents** of other images. The current graph is a
linear `FROM` chain:

```
cc-base ─┬─ cc-node20 ── cc-vue3 ── cc-full
         ├─ cc-zulu21
         └─ cc-pdf2md
```

`cc-base`, `cc-node20`, and `cc-vue3` are each *both* runnable *and* an ancestor
of something else. A linear `FROM` chain is a total order, so editing anything
early re-runs every layer after it. The volatile runtime scripts live in
`cc-base` — the earliest node — so editing them invalidates the whole tree.

**Principle:** the fix must get volatile content into layers that *nothing else
builds on top of*.

Three structural escape hatches were identified:

1. **One image, scripts last** — collapse to a single image; scripts become the
   final layers. Simple, but every user carries every toolchain (~2 GB).
2. **Bind-mount the scripts** — volatile files never live in a layer at all;
   topology-independent, near-zero engineering. Cost: images aren't
   self-contained (depend on the repo at run time).
3. **Make every runnable image a true leaf** — no runnable image is a parent of
   another; variants are built independently and share heavy work via
   multi-stage `COPY --from` from toolchain "module" images.

This document explores **option 3: the modular build engine.**

## The 4-band layer model

Every layer in an image falls into one of four bands. Ordering them
least-volatile → most-volatile (subject to dependency constraints) is what makes
the cache survive edits.

| # | Band | Name | Examples | Relocatable? | Volatility | Placement |
|---|------|------|----------|--------------|-----------|-----------|
| 1 | **Foundational apt** (+ claude) | **`base`** | `curl`, `ca-certificates`, `git`, `gosu`, `make`, `wl-clipboard`, `xclip`, `claude` | No (apt) | Very low | First — foundational (TLS, git, downloader) + clipboard feature |
| 2 | **Language / stack** | **`stack`** | Node (tarball), Zulu JDK (tarball) | **Yes** (self-contained dir) | Low (pinned versions) | Middle — expensive downloads |
| 3 | **Convenience apt** | **`extras`** | `ripgrep`, `fd`, `jq`, `fzf`, `bat`, `tree`, `vim`, `ruby-full` | No (apt) | Medium (added ad hoc) | After toolchains — so adding a tool doesn't bust the expensive downloads |
| 4 | **Bootstrap scripts** | **`bootstrap`** | `cc-wrapper.sh`, `run-as-hostuser.sh`, `sandbox.md` | n/a | High (edited often) | Last — baked leaf |

> Note: `ruby-full` sits in `extras` (not `stack`) because it's
> apt-only/non-relocatable — it can't be a `COPY --from` module, so despite being a
> language runtime it lives with the convenience apt rather than the stacks.

### Band names → image names

Each band has a one-word name, used as the image name (or prefix). Naming
concepts matters, and the band name doubles as the Docker image namespace.

- **`base`** — a single image: band 1 (foundational apt) + claude. Band name =
  full image name: `base`. Convenience apt (`extras`) is *not* baked in — see below.
- **`stack`** — the relocatable modules, one image each, band name as prefix:
  `stack/node`, `stack/zulu`.
- **`extras`** — names the convenience-apt concept (ripgrep/jq/ruby-full/…). *Not*
  in `base`; deferred to the future per-project apt refinement. No standalone image.
- **`bootstrap`** — names the baked bootstrap-scripts leaf; not an image, baked
  into the assembled final.

**`cc-` org prefix dropped** — `stack/zulu`, not `cc-stack/zulu`; the band
namespace disambiguates. **Assembled-final naming (resolved):** the assembled image
belongs to no band, so it takes the `cc/` namespace — `cc/<sorted-names>` (e.g.
`cc/node-zulu`), empty set → `cc/base`. Note `cc/base` (a runnable final:
foundation + bootstrap + `ENTRYPOINT`) is distinct from `base` (the shared
foundation image, with neither); the `cc/` prefix is exactly what disambiguates them.

Key insight: **OS-level apt is not monolithic.** It brackets the toolchains on
*both* sides — foundation below (dependency-forced), conveniences above
(cache-optimal). Scripts dead last is the placement that matters most.

### Relocatable vs non-relocatable

This distinction is what makes modularity possible:

- **Relocatable** (band 2): lives in one self-contained directory you can copy
  wholesale — `/usr/local/node`, the JDK tarball dir. These can be built once as a
  standalone stage/image and pulled in via `COPY --from`.
- **Non-relocatable** (bands 1 & 3): `apt install` scatters files across `/usr`,
  `/etc`, and dpkg state. Cannot be `COPY --from`'d cleanly → must be baked into
  a shared base image.

**Mapping to the modular design:**

- Band 1 (apt) → the shared **`base` image**. (Band 3 `extras` is deferred to
  per-project apt — not baked into `base`.)
- Band 2 (relocatables) → each a **`COPY --from` module** composed freely.
- Band 4 → the **`bootstrap` leaf**, baked last in every assembly.

#### Resolved placements

- **Node** — switch from the nodesource **apt** install to the **relocatable
  tarball** → `stack/node`. `corepack enable` is baked in at module-build time so
  yarn/pnpm shims live inside the copied node dir (vue was never a base concern —
  it's a package-manager install). This one module replaces both `cc-node20` and
  `cc-vue3`.
- **Zulu JDK 21** — switch from the Azul **apt repo** to the Zulu **tarball** →
  `stack/zulu` (image `stack/zulu:21`). Cleanly relocatable.
- **Ruby, Go, Rust** — out of scope. Ruby is apt-only (non-relocatable); Go/Rust
  were only ever a `cc-full` idea, and `cc-full` is explicitly not a POC target.
- **pdf2md (Python)** — deferred. It's `python3` (apt, non-relocatable) +
  `pip install pymupdf4llm`. A `stack/*` form needs a relocatable Python
  (python-build-standalone / uv); revisit post-POC. See open questions.

## Modular engine — concept

Instead of a fixed `FROM` chain, an image is **assembled** from:

```
shared base (band 1 apt + claude)
      +
selected band-2 modules  (COPY --from stack/node, stack/zulu, …)
      +
bootstrap (band 4: scripts)   ← always baked last
```

A project declares which modules it wants (e.g. `modules: [node, zulu]`); the
engine produces a Dockerfile (or drives BuildKit directly) that copies just
those toolchains onto the base and bakes the bootstrap layer.

### What this fixes

- **No cascade** — every runnable image is a leaf. Editing band-4 scripts
  rebuilds only the bootstrap layer, for every variant.
- **Cheap toolchain modules** — each toolchain builds once as its own stage and
  is cached independently; adding a module to one project doesn't rebuild others.
- **Lean images** — a project only carries the toolchains it selected.

### What it costs

- A real build subsystem to own: module definitions, assembly, caching strategy,
  and testing of combinations.

## Module anatomy

A module is **not just a Dockerfile.** `COPY --from` copies *files*, not `ENV` or
package state, so a module must also declare what to copy and what environment to
replay. A module is therefore a directory containing:

1. **`Dockerfile`** — a *staging* build that produces the relocatable artifact in
   a known directory (e.g. unpacks the node tarball into `/usr/local/node`). The engine only
   ever `COPY --from`s the declared artifact dir out of this image, so the
   staging image can be as fat as it needs to be — the bloat never reaches the
   final image.
2. **`module.yml`** — metadata the assembler needs.

### `module.yml` (draft schema)

```yaml
name: node
version: "20"                          # pin lives in metadata (not buried in the
                                       # Dockerfile); drives the tag stack/node:20
description: Node.js (relocatable tarball) with corepack (yarn/pnpm) enabled

# EXTRA apt (beyond what `base` already provides) needed ONLY to build the
# artifact in the staging image; discarded after COPY. Empty here: modules stage
# FROM base, which already ships curl + ca-certificates.
build_deps: []

# apt packages the copied artifact needs to actually RUN in the final image.
# The assembler must ensure these are present downstream (see "two kinds of
# apt dependency" below).
runtime_deps: []                       # prebuilt node runs on base's glibc alone
                                       # (node-gyp native addons would add build-essential)

# directories to COPY --from the module image into the final image.
artifacts:
  - /usr/local/node

# env to re-declare in the final image after the COPY (ENV is NOT inherited
# across COPY --from). COREPACK_HOME lives inside the copied dir so the
# yarn/pnpm shims travel with it. NOTE: the staging Dockerfile must
# `chmod -R a+rwX` this dir — it's built root-owned, but the container runs as the
# mapped host user, so a runtime `corepack prepare` would otherwise EACCES.
env:
  PATH: "/usr/local/node/bin:${PATH}"
  COREPACK_HOME: /usr/local/node/corepack
```

Zulu JDK 21, for comparison:

```yaml
name: zulu
version: "21"                          # drives the tag stack/zulu:21
description: Azul Zulu JDK 21 (relocatable tarball; replaces the apt-repo install)
build_deps: []                         # base already provides curl + ca-certificates
runtime_deps: []                       # headless java/javac need nothing extra
                                       # (AWT/fonts would add fontconfig)
artifacts:
  - /usr/local/zulu
env:
  JAVA_HOME: /usr/local/zulu
  PATH: "/usr/local/zulu/bin:${PATH}"
```

### Env merge convention (multiple modules)

When several modules are selected, the assembler merges their `env` into the
assembled final:

- **`PATH` must be written in prepend form** — `"<dirs>:${PATH}"`. The assembler
  strips the trailing `:${PATH}`, collects each module's `<dirs>`, dedups, and
  emits a **single** merged line in sorted-module order:
  `ENV PATH="/usr/local/node/bin:/usr/local/zulu/bin:${PATH}"`. (Naive chaining
  of per-module `ENV PATH` lines would also compose via `${PATH}` expansion, but a
  single deduped line keeps the Dockerfile clean and deterministic.)
- **Non-`PATH` keys** are emitted as-is (`ENV JAVA_HOME=…`, `ENV COREPACK_HOME=…`).
  If two modules set the **same** non-`PATH` key, the assembler **warns** — a real
  conflict that shouldn't arise between distinct modules.

### Two kinds of apt dependency

This is the refinement of "maybe we need to define apt package dependency":

- **`build_deps`** are apt packages needed to build the artifact in the *staging*
  image, **beyond what `base` already provides**. Since modules stage `FROM base`
  (curl + ca-certificates present), the usual fetch tools are already there, so
  `build_deps` is normally **empty** — list only extras a specific build needs. They
  live only in staging and add zero weight to the final image.
- **`runtime_deps`** must exist in the *final* image for the copied toolchain to
  work (e.g. a JDK needs `fontconfig` for AWT/fonts; a native-addon build needs
  `build-essential`). These are apt (non-relocatable), satisfied by a single
  `apt install` of the *union* of all selected modules' `runtime_deps` in the
  assembled final (after the `COPY --from`s, before per-project apt + bootstrap).
  **Do not** satisfy them by adding the package to `base`: `base` is band 1 (least
  volatile), so growing it to serve one module bloats *every* assembled image and
  busts the shared-base cache for *all* of them — exactly the cascade this design
  exists to avoid. The POC modules have empty `runtime_deps`, but the union-install
  mechanism has to exist for modules that don't.

### Staging base convention

`stack/*` modules stage **`FROM base`**. Staging on our own `base` image gives
modules `curl`/`ca-certificates` for free, shorter Dockerfiles, and — the clincher
— a **guaranteed identical ABI** to the final image (finals are also `FROM base`),
so a relocatable toolchain (binaries linked against a specific glibc/arch) is built
against the exact libc it will run on, eliminating "works in staging, breaks in
final" surprises. The only cost is that a `base` rebuild invalidates module caches,
but `base` is band-1 stable so that's rare and cheap. (`build.sh` must build `base`
before any `stack/*` — which it must do anyway.) `base` itself remains `FROM
debian:bookworm-slim`.

## POC — proposed architecture

### Config: modules live in `cc-docker.yml`

A project declares its toolchains:

```yaml
# cc-docker.yml
modules: [node, zulu]
```

Coexistence is by **clean separation**, not a dual-mode builder: the current
implementation moves to `legacy/` (its own `build.sh`/`Makefile`), and modular
becomes the default. At runtime, `cc-docker.yml` with `modules:` → modular path;
with the legacy `image:` field → runs a prebuilt legacy image as today. (See repo
layout below.)

### Schema & validation changes (required)

- **`cc-docker.yml` schema.** Today `cc-docker.schema.json` has `required: ["image"]`
  and `generate-compose.py` reads `config["image"]` unconditionally (a hard error if
  absent). Modular mode has `modules:`, not `image:`. So cc-config must make `image`
  optional, add a `modules` array, and encode the coexistence rule as a **`oneOf`:
  exactly one of `image` | `modules`**. Both present → validation error; neither →
  error; **base-only is `modules: []`** (→ `cc/base`), not an omitted config. Without
  this, the first modular `cc-docker.yml` fails schema validation on line one.
- **`module.yml` schema.** `module.yml` drives `COPY`/`ENV` codegen, so it needs its
  own `module.schema.json` + validation inside cc-assemble, mirroring cc-config's
  `validate_config` (per-error messages). Otherwise an `artifacts:`/`env:` typo
  surfaces as a broken Dockerfile far downstream instead of a clear config error.

### Separation of concerns (three actors)

Assembly is its own stage, distinct from cc-config. But we also want to keep
Python **off the host** (the whole reason cc-config runs in a container). That
splits the work across three actors:

| Actor | Runs in | Reads | Produces | Needs Docker? |
|-------|---------|-------|----------|---------------|
| **cc-config** | container (as today) | `cc-docker.yml` | `docker-compose.yml` (`image:` = the tag) **+ `.cc-docker/assembled.tag`** (sole tag computation) **+ `.cc-docker/assembled.modules`** (raw module-name list for the host) | no |
| **cc-assemble** _(new)_ | its **own** container | `cc-docker.yml` + `modules/*/module.yml` | assembled `Dockerfile` written to `.cc-docker/` (does **not** compute the tag) | no (pure text gen) |
| **launcher** (`init-cc.sh`) | host bash | the generated Dockerfile + `.cc-docker/{assembled.tag,assembled.modules}` | reads names + tag from the sidecars (never recomputes), runs `build.sh` scoped to those modules, then always `docker build`s the assembled image under a flock, then `docker compose run` | **yes** |

Both generators stay containerized (no host Python/PyYAML dependency); only the
actual `docker build`/`docker compose` calls run on the host, in bash. This keeps
assembly cleanly separate from cc-config while honoring the existing "no host
toolchain" design. `cc-assemble` is built as a container from the start (modeled
on cc-config's scaffolding — same base, `/out` mount, chown-back), not shortcut as
a host script.

### Lazy-at-launch flow

```
cc  →  cc-config   : cc-docker.yml → docker-compose.yml + .cc-docker/assembled.tag (cc/node-zulu)
                     + .cc-docker/assembled.modules  (node\nzulu — names sidecar)
    →  cc-assemble : modules:[node,zulu] + module.yml → .cc-docker/assembled.Dockerfile
    →  host bash   : build.sh base $(cat assembled.modules)  (scoped; greps each version:)
                     read tag from assembled.tag → always `docker build` it (flock)
                     docker compose run cc
```

The deterministic assembled tag (`cc/<sorted-names>`, e.g. `cc/node-zulu`) is
computed in exactly one place — **cc-config** — which writes it both as `image:` in
compose and to a sidecar `.cc-docker/assembled.tag`. The launcher reads the tag from
that sidecar (never recomputing it), so it builds and runs exactly what compose
references; cc-assemble doesn't compute the tag at all. Same module set → same tag →
reused instantly; editing a script rebuilds only the bootstrap layer of that one
assembled image.

The canonical sort is Python `sorted()` (Unicode codepoint order) in cc-config.
Because only cc-config computes the tag (decision C), there is no cross-language /
locale-dependent bash `sort` to disagree with it — closing review-2 #7.

### Host-side inputs: names, versions, mode

The scoped `build.sh` and version-aware tags need two things on the host without
re-parsing `cc-docker.yml` in bash:

- **Module names** — cc-config writes a second sidecar `.cc-docker/assembled.modules`
  (the raw name list, one per line) next to `assembled.tag`; the launcher runs
  `build.sh base $(cat .cc-docker/assembled.modules)`. This keeps cc-config the sole
  reader of `cc-docker.yml` (extends decision C) and avoids fragile name-from-tag
  splitting (a module named `foo-bar` would make `cc/foo-bar` ambiguous).
- **Module versions** — `build.sh` reads each module's `version:` with a light
  `grep '^version:' stack/<name>/module.yml` to tag `stack/<name>:<version>`. That's a
  *value read*, not the tag *algorithm* decision C protected, so it can't diverge; and
  `build.sh` needs it anyway to run standalone (build-all/CI). Precedent: `init-cc.sh`
  already `grep`s `anthropic_api_key_file` out of `cc-docker.yml`.
- **Mode detection** — the launcher branches on **sidecar presence**:
  `.cc-docker/assembled.tag` present → modular (assemble + build path); absent →
  legacy `image:` (run a prebuilt image as today). cc-config writes the sidecars only
  in modular mode, so no YAML parsing is needed to pick the branch.

### Cache correctness — always build, never presence-check

"Tag exists" ≠ "tag is current": editing a `module.yml` or a bootstrap script does
not change the `stack/*` or `cc/<names>` tag, so a presence check would silently
reuse a stale image. Only `docker build`, with its content-addressed layer cache,
knows whether a rebuild is actually needed. So:

- **`build.sh` always `docker build`s what it's asked to** — `base` + the named
  `stack/*` (or all of them, with no args) — a fast no-op when unchanged, a correct
  rebuild when a Dockerfile/context changes. The launcher invokes it **scoped to the
  project's modules** (`base` + the selected stacks) on every launch, so blocks are
  always current without ever rebuilding stacks the project doesn't use.
- The launcher then **always** runs `docker build` for the assembled final too (not
  "if missing"): a bootstrap edit rebuilds just the cap layer; a changed `stack/*`
  image invalidates its `COPY --from`; unchanged → sub-second no-op.
- A **`flock` keyed on the assembled tag, in a shared user-writable location**
  (`${XDG_RUNTIME_DIR:-/tmp}/cc-docker/locks/<sanitized-tag>.lock`) serialises
  concurrent `cc` invocations racing to build the same tag — including two *different*
  projects with the same `modules:` (the image is global per module set, so the lock
  can't live in a project's `.cc-docker/`). It must be user-writable and
  cross-project, so **not** `$CC_DOCKER_DIR` (which may be a root-owned/system install).
- **Latency:** every launch runs several sequential `docker build`s — `base` + each
  project stack + the final (four, for two modules) — each paying its own context
  send + cache-hash. Unchanged, they're all no-ops, but that's a few seconds, not
  instant; a fresh project pays the real build once. The **assembled-build fast-path**
  (open questions) exists precisely to skip this when nothing changed. `build.sh` with
  no args (build-all) stays available for CI / pre-warming.

### The three reusable build pieces (via `build.sh`)

```
base           band 1 (apt) + claude  — the shared base, FROM debian:bookworm-slim
stack/node:20  staging image holding /usr/local/node (corepack/yarn baked in)
stack/zulu:21  staging image holding /usr/local/zulu
```

### Assembled Dockerfile shape (band order)

```dockerfile
FROM base                                                      # band 1 + claude (shared)
COPY --from=stack/node:20 /usr/local/node  /usr/local/node    # band 2
COPY --from=stack/zulu:21 /usr/local/zulu  /usr/local/zulu    # band 2
ENV PATH="/usr/local/node/bin:/usr/local/zulu/bin:${PATH}"
ENV JAVA_HOME=/usr/local/zulu COREPACK_HOME=/usr/local/node/corepack
# [refinement] runtime_deps union apt-install here — modules that need apt at
#   runtime; after COPY --from, before per-project apt. Empty for POC modules.
# [refinement] per-project apt packages here (band 3, project-specific)
COPY <bootstrap scripts> ...                                   # bootstrap — baked last
ENTRYPOINT [...]
```

### Build mechanics: context, tags, entrypoint

- **Build context.** The assembled Dockerfile lives in the project's `.cc-docker/`,
  but its `COPY <bootstrap>` sources live in the cc-docker install dir. The only
  thing the final `COPY`s from context is the bootstrap scripts, so the context is
  scoped to exactly that dir — not the whole install tree, keeping `.git/`,
  `legacy/`, etc. off the daemon:
  `docker build -f .cc-docker/assembled.Dockerfile -t "$(cat .cc-docker/assembled.tag)" "$CC_DOCKER_DIR/bootstrap"`.
  `COPY` paths are then relative to `bootstrap/` (e.g. `COPY cc-wrapper.sh …`);
  `COPY --from=stack/*` needs no context (it pulls from local images).
- **Module tags are local-only and version-aware.** A module tags as
  `stack/<name>:<version>` (e.g. `stack/node:20`), the version coming from
  `module.yml`. The main win is **cache-busting** — a version bump produces a new tag
  rather than mutating `:latest`. (Two versions coexisting is only *theoretical*
  today: there's one `module.yml` per `stack/<name>/` dir pinning a single version,
  so nothing builds a second until there are separate module dirs.) Tags are never
  pushed, so a `stack/*` must exist locally — the launcher builds `base` + the
  project's stacks (scoped `build.sh`) before the final, so they're present by
  construction (no registry-pull surprise). Projects select by *name* in `modules:`
  (`modules: [node]`); the version is resolved from that module's `module.yml`.
- **`base` has no `ENTRYPOINT` and no scripts.** The scripts move to `bootstrap/`
  and are baked into the *final* image, which owns the `ENTRYPOINT`. So new `base`
  drops the `ENTRYPOINT ["/cc-wrapper.sh"]` and the three script `COPY`s that
  `images/base/Dockerfile` has today. (`stack/*` staging images `FROM base` inherit
  no entrypoint — harmless; they're never run.)
- **The assembled image is global per module set, not per project.** cc-assemble
  writes a Dockerfile into each project's `.cc-docker/`, but the resulting tag
  (`cc/<sorted-names>`) is shared: N projects with the same modules regenerate a
  byte-identical Dockerfile and resolve to one shared image. The per-project file is
  an idempotent build input, not a per-project image.

### claude placement note

`claude` is **universal** — every image needs it — and its install is relatively
stable, so it lives at the **end of the shared `base`** image (band 1), installed
once and shared by every assembled final via `FROM`. It is deliberately *not* in
the `bootstrap` leaf: `bootstrap` holds only the per-edit-volatile files (the entry
scripts + the `sandbox.md` prompt), whose `COPY` is the final layer, so editing them
busts nothing else.

### POC goals / checklist

- [ ] `base` image Dockerfile: band 1 apt (`curl ca-certificates git gosu make wl-clipboard xclip`) + claude, `FROM debian:bookworm-slim`, **no scripts and no `ENTRYPOINT`** (finals own it).
- [ ] Two `stack` modules with `Dockerfile` + `module.yml`: **node** (tarball,
      corepack/yarn baked in, `chmod -R a+rwX` COREPACK_HOME — replaces `node20` +
      `vue3`) and **zulu** (Zulu tarball → `stack/zulu:21`, replacing the apt-repo install). Both
      relocatable, empty `build_deps`/`runtime_deps`.
- [ ] Schema work: relax `cc-docker.schema.json` (`image` optional + `modules` array
      + precedence rule) and make `generate-compose.py` handle `modules:`; add a
      `module.schema.json` + validation inside cc-assemble.
- [ ] `cc-assemble` generator: `modules:` + `module.yml` → assembled Dockerfile
      (COPY --from + merged ENV + bootstrap COPY). cc-config writes `image:` +
      `.cc-docker/assembled.tag` + `.cc-docker/assembled.modules` (names sidecar).
      (`runtime_deps` union codegen is a post-POC refinement — both POC modules have
      empty `runtime_deps`.)
- [ ] NEW `build.sh` (a rewrite, not an extension): accepts an optional module list
      (`build.sh base node zulu`) and builds just those, `base` first; no args → all;
      reads each module's `version:` (light `grep`) to tag `stack/<name>:<version>`.
      Always `docker build` (cache decides).
- [ ] Launcher wiring: detect mode by sidecar presence; read names from
      `.cc-docker/assembled.modules`, invoke `build.sh base <names>` (scoped), read tag
      from `.cc-docker/assembled.tag`, always `docker build` the final under a `flock`,
      then `compose run`. Legacy `image:` path when no sidecar; don't error when
      `images/` is absent.
- [ ] Demonstrate: editing a script rebuilds only the bootstrap layer; adding a
      module to one project doesn't rebuild another's toolchains.

### Proposed repo layout (post-migration)

Clean cut: the current implementation moves wholesale into `legacy/`, and the new
modular solution becomes the **default** at the top level with its own `build.sh`
and `Makefile`.

```
legacy/                     # frozen current implementation, still runnable
  images/                   #   cc-base, cc-node20, cc-vue3, cc-zulu21, cc-pdf2md, cc-full
  build.sh                  #   old FROM cc-* graph builder
  Makefile                  #   old build target
  completions/

base/Dockerfile             # `base` (band 1 apt + claude), FROM debian:bookworm-slim
stack/node/Dockerfile       # `stack/node` staging build → /usr/local/node
stack/node/module.yml
stack/zulu/Dockerfile       # `stack/zulu` staging build → /usr/local/zulu
stack/zulu/module.yml
bootstrap/                  # baked band-4 scripts (cc-wrapper, run-as-hostuser, sandbox.md)
toolchain/
  config/                   # cc-config — SHARED, extended to compute the cc/<names> tag
  assemble/                 # cc-assemble — NEW generator (its own image)
  dev/                      # cc-dev — RETAINED as-is (cc-docker's own dogfooding dev env)
build.sh                    # NEW — builds `base`, then all `stack/*` (base first)
Makefile                    # NEW — default targets
init-cc.sh                  # launcher — modular-aware; still runs legacy `image:` too
```

Notes:
- Directory names mirror band names (`base/`, `stack/`, `bootstrap/`).
- **`toolchain/config` (cc-config) is shared, not legacy** — it still generates
  `docker-compose.yml`, now also computing the `cc/<sorted-names>` tag from
  `modules:`.
- **`init-cc.sh` stays a single launcher — but its menu breaks and must be
  rewritten.** Today it loops `for d in "$CC_DOCKER_DIR/images/"/*/` to build a menu
  and writes `image: <chosen>`; once `images/` moves to `legacy/`, that loop goes
  empty and it errors ("no images found"). For the POC: modular users hand-write
  `modules:` (menu deferred — decision D), and the launcher must branch on `modules:`
  vs legacy `image:` and **not error when `images/` is absent**.
- **`build.sh` is a rewrite, not an extension.** The current discovery globs
  (`images/*/Dockerfile`, `toolchain/*/Dockerfile`) and the `FROM cc-*` topo-sort
  don't carry over — the new layout has no `images/`, no `cc-` prefix, and no
  inter-image `FROM cc-*` chain. Only the `legacy/` copy keeps that machinery (and
  its `completions/build.bash`).
- The band-4 scripts get a canonical home in `bootstrap/`; `legacy/images/base/`
  keeps its own frozen copies.
- **`toolchain/dev` (cc-dev) is retained as-is** — it's cc-docker's own dogfooding
  dev environment, orthogonal to this redesign (neither a `stack` nor legacy).

`cc-assemble` lives at `toolchain/assemble/` (image name `cc-assemble`), a sibling
of `toolchain/config/` (cc-config).

## Future refinements _(post-POC)_

- **Per-project apt packages in `cc-docker.yml`.** Allow e.g. `apt: [postgresql-client,
  imagemagick]` → assembler emits an `apt install` layer in the assembled image
  (band 3, project-specific), placed after module COPYs and before the bootstrap
  layer. Lets a project add OS packages without a new module or a custom image.
- **Module `runtime_deps` union install** in the assembled image, for modules that
  need apt packages not already in `base`.
- **Module artifact checksums** — add an expected SHA (per-arch) to `module.yml` and
  verify the downloaded tarball in the staging build, for reproducible,
  tamper-evident modules. Version is pinned now; the digest is the next step.
- **Hashed tag + descriptive labels** (needed once per-project apt lands). The
  assembled identity becomes `<sorted-stacks>` + `<sorted-apt>`; a readable name
  like `cc/node-zulu-make-jq-…` gets unwieldy and can exceed the 128-char tag
  limit. So hash it: `cc/<short-hash>` as the tag, and attach **labels** for
  human-readable, filterable metadata. Note tags ≠ labels:
  - **Tag** = the `:name`; format-limited (128 chars, `[A-Za-z0-9_.-]`), unlimited
    in count but one meaningful identity per image → hash it.
  - **Labels** = `LABEL` key/value metadata; no hard count limit (bounded by image
    config size), but it's a **map — one value per key**. Multiple stacks/apt can't
    reuse a key. Use per-item boolean keys for clean filtering:
    `dev.cc.stack.node=true`, `dev.cc.apt.make=true` (namespaced reverse-DNS).
    `docker images --filter label=…` matches key-existence or exact key=value only
    (no substring), so per-item keys beat a delimited `dev.cc.stacks=node,zulu`
    value for "show every image that has node".

## Open questions

- **Selective module builds** — post-POC: instead of `build.sh` building *all*
  `stack/*`, build only those referenced across projects' `cc-docker.yml`
  `modules:`. POC builds all (only two). _(open, deferred)_
- **Assembled-build fast-path** — post-POC: skip the always-on `docker build` when
  nothing under `base/`/`stack/`/`bootstrap/` and the module set are unchanged since
  the last build, to save the ~1-2s cache-hashing per launch. POC always builds.
  _(open, deferred)_
- **Interactive `modules:` authoring in init-cc** — post-POC: today init-cc shows a
  numbered menu of `images/*` and writes `image: cc-<x>`. A modular menu needs
  module discovery from `stack/*`, a multi-select toggle, and a rule for offering
  legacy `image:` vs modular `modules:`. POC: user hand-writes `modules:` in
  `cc-docker.yml`; init-cc's launcher path only branches on `modules:` vs `image:`.
  _(open, deferred)_
- **Relocatable Python (for pdf2md)** — post-POC: package Python as a `stack/*`
  module via a relocatable distribution (python-build-standalone / uv), then
  install `pymupdf4llm` + the `pdf2md` wrapper into it. Unblocks the last of the
  user's real images. _(open, deferred)_

## Decisions log

- **2026-07-24 — Direction: modular build engine (escape hatch #3).** Explore
  making every runnable image a leaf, composing relocatable toolchains.
- **2026-07-24 — Module transport = separate module images (Option A).** Modules
  are standalone images (`stack/<name>`) pulled in via `COPY --from=stack/<name>`,
  not stages in a concatenated multi-stage Dockerfile. Rationale: each module
  becomes a global cache boundary + parallel build; the assembler only ever emits
  uniform `COPY --from` + `ENV` lines, never build logic, keeping the engine small.
- **2026-07-24 — A module = `Dockerfile` (staging) + `module.yml` (metadata).**
  Metadata declares `build_deps`, `runtime_deps`, `artifacts`, and `env`.
- **2026-07-24 — apt deps split into `build_deps` (staging-only) and
  `runtime_deps` (must exist in final image).**
- **2026-07-24 — `stack/*` modules stage `FROM base`** (not raw
  `debian:bookworm-slim`). Gives free build-deps + a guaranteed identical ABI to
  the final image (both are `FROM base`). `base` itself stays `FROM
  debian:bookworm-slim`. Coupling to `base` rebuilds is cheap (band-1 stable).
- **2026-07-24 — Modules are declared in `cc-docker.yml`** via `modules: [...]`.
  Coexists with the legacy `image:` field during migration.
- **2026-07-24 — Assembly runs lazily at `cc` launch time**, not as a separate
  explicit build step. Heavy pieces (`base` + module images) are pre-built by
  `build.sh`; the per-project assembled image is built on demand (always
  `docker build`, cache decides — see below).
- **2026-07-24 — Assembled-final image name = `cc/<sorted-names>`** (e.g.
  `cc/node-zulu`); empty module set → `cc/base`. The `cc/` namespace groups
  generated runnable finals, distinct from `base`/`stack/*`, and is greppable
  (`docker images 'cc/*'`). Hashed tags + descriptive labels deferred to the
  per-project-apt refinement.
- **2026-07-24 — Assembly is a separate stage from cc-config**, split across a new
  `cc-assemble` container (text generation) + the host launcher (`docker build`).
  Keeps Python off the host, mirroring cc-config's containerized-generator design.
- **2026-07-24 — Per-project apt packages** (`apt: [...]` in `cc-docker.yml`)
  deferred to a post-POC refinement.
- **2026-07-24 — `claude` lives at the end of the `base` image** (universal +
  stable, installed once and shared via `FROM`), not per assembled image. The leaf
  (`bootstrap`) holds only the entry scripts + the `sandbox.md` prompt.
- **2026-07-24 — Band 4 scripts are BAKED, not bind-mounted.** The modular leaf
  structure already kills the cascade, so an edit costs only a fast `bootstrap`
  rebuild; baking keeps images self-contained/portable. Core goal of the redesign.
- **2026-07-24 — Relocatable-where-possible; no inter-module dependencies.** Every
  `stack/*` module is a complete, self-contained relocatable dir. The assembler
  never resolves a dependency graph — it just `COPY --from`s the selected modules.
  Tradeoff: genuinely stacked toolchains (e.g. future JVM langs needing a JDK)
  would each bundle their own copy; acceptable, revisit only if it bites.
- **2026-07-24 — `vue3` dissolves into `stack/node`.** vue is a package-manager
  install, never a base concern. corepack/yarn is baked into `stack/node` at
  module-build time (shims live in the relocatable node dir). No `vue3` module,
  no inter-module link.
- **2026-07-24 — POC module set = `stack/node` + `stack/zulu`** (both switched to
  relocatable tarballs). Drawn from the user's real images (`node20`, `vue3`,
  `zulu21`). `cc-full`/Go/Rust/Ruby are NOT POC targets.
- **2026-07-24 — `pdf2md` deferred** — needs a relocatable Python module
  (python-build-standalone / uv); revisit post-POC.
- **2026-07-24 — New `build.sh` scope = building blocks; takes an optional module
  list.** Builds `base` first, then the named `stack/*` (or all, with no args) —
  they're `FROM base`, so ordering is trivial, no general graph needed. The launcher
  assembles per-project finals; blocks are built by the launcher invoking `build.sh`
  scoped to the project's modules (see #2 below).
- **2026-07-24 — Migration = clean cut via `legacy/`.** The current implementation
  (old `images/`, `build.sh`, `Makefile`, completions) moves into `legacy/` frozen;
  the modular solution becomes the default at top level with a NEW `build.sh` +
  `Makefile`. `cc-config` and `init-cc.sh` are shared (extended), not legacy.
- **2026-07-24 — `cc-assemble` built as a container from the start**, modeled on
  cc-config's scaffolding (no host-script shortcut, no host Python dep). Stays a
  separate image/stage from cc-config.
- **2026-07-24 — Env merge = single merged `PATH` line (option 2).** Modules
  declare `PATH` in prepend form `"<dirs>:${PATH}"`; assembler dedups and emits one
  merged line in sorted-module order, plus one `ENV k=v` per non-`PATH` var, warning
  on duplicate non-`PATH` keys.
- **2026-07-24 — init-cc interactive menu deferred (review #7).** For the POC the
  user hand-writes `modules: [...]` in `cc-docker.yml`; init-cc's launcher path only
  needs to branch on `modules:` (modular) vs `image:` (legacy) — wiring, not UX. The
  multi-select module-discovery menu is a post-POC item.
- **2026-07-24 — Tag has a single source of truth (resolves review #6).** cc-config
  is the sole tag computer: it writes `image: cc/<tag>` into compose AND a sidecar
  `.cc-docker/assembled.tag`. The launcher reads the tag from the sidecar (no
  recompute, no bash-parsing YAML); cc-assemble never computes it. Kills the
  drift-hazard of two identical algorithms in two containers.
- **2026-07-24 — Cache correctness = always `docker build`, never presence-check
  (resolves review #8/#9).** "Tag exists" ≠ "tag is current"; editing a `module.yml`
  or bootstrap script leaves the tag unchanged. So `build.sh` always builds
  `base`+`stack/*` and the launcher always builds the assembled final, letting
  Docker's layer cache decide (no-op when unchanged). A `flock` per assembled tag
  prevents concurrent-launch races. Fast-path (skip when nothing changed) deferred.
- **2026-07-24 — `base` = band 1 only (corrects review findings #4/#5).** Band 1 =
  `curl, ca-certificates, git, gosu, make, wl-clipboard, xclip` + claude.
  `wl-clipboard`/`xclip` stay — they back the `display:` clipboard feature; `make`
  stays — essential to the maintainer's in-container workflow. `build-essential` is
  NOT foundational (→ module `runtime_dep`/`extras` when needed). `extras`
  (convenience apt) is NOT baked into `base` — deferred to per-project apt. Corrects
  the earlier false "bands 1+3 today" claim.
- **2026-07-24 — `module.yml` carries `version:`; tags are version-aware (resolves
  review-2 #14).** The pin lives in module metadata, not just the staging Dockerfile;
  modules tag as `stack/<name>:<version>` (e.g. `stack/node:20`). Main win is
  cache-busting (a bump makes a new tag, not a mutated `:latest`); actual coexistence
  needs separate module dirs, so it's theoretical for now. Selection stays by name
  (`modules: [node]`), version resolved from module.yml. Checksums/SHAs deferred to a
  supply-chain refinement.
- **2026-07-24 — Module `zulu21` renamed → `zulu`** (falls out of version-aware
  tags): the version lives in `version:`/the tag, not the name. Image `stack/zulu:21`,
  artifact `/usr/local/zulu`, selected as `modules: [node, zulu]`. `node` was already
  version-agnostic. The legacy `cc-zulu21` image name is unaffected.
- **2026-07-24 — Review 3 batch applied (residual drift).** Concept diagram fixed to
  `band 1 apt + claude` (band 3 not in `base`); `flock` clarified as **per-tag in a
  shared location** (`$CC_DOCKER_DIR/.locks/`) since assembled images are global per
  module set; `runtime_deps` union codegen confirmed **post-POC** (dropped from the
  POC checklist); status header credits all three review passes; version-aware tags
  reframed as **cache-busting** (coexistence theoretical until separate module dirs);
  assembled build context scoped to `$CC_DOCKER_DIR/bootstrap` (not the whole tree).
  `build.sh` invoke-vs-prerequisite (#2) resolved below.
- **2026-07-24 — `cc` invokes `build.sh` scoped, every launch (resolves review-3
  #2 = option B).** Not a manual prerequisite and not a full build-all: the launcher
  runs `build.sh base <selected stacks>` (always `docker build`, cache no-ops), then
  always builds the final. Consistent with the never-presence-check ethos, but scoped
  so it never builds stacks the project doesn't use. `build.sh` with no args
  (build-all) stays for CI / pre-warming; the "run `build.sh` first" preflight error
  is dropped (blocks are present by construction).
- **2026-07-24 — Host gets module names via a sidecar; `build.sh` greps versions
  (resolves review-4 #1).** cc-config writes `.cc-docker/assembled.modules` (raw name
  list) next to `assembled.tag`, so the launcher runs `build.sh base $(cat
  assembled.modules)` without bash-parsing `cc-docker.yml` or splitting names out of
  the tag. `build.sh` reads each module's `version:` via a light `grep` to tag
  `stack/<name>:<version>` (a value read, not the tag algorithm — can't diverge; also
  needed for standalone build-all).
- **2026-07-24 — Launcher mode detection = sidecar presence (resolves review-4 #2).**
  `.cc-docker/assembled.tag` present → modular; absent → legacy `image:`. cc-config
  writes the sidecars only in modular mode, so no YAML parsing chooses the branch.
- **2026-07-24 — `image:` vs `modules:` = `oneOf` (resolves review-2 #5).** Schema
  requires exactly one of `image` | `modules`; both present → error, neither → error.
  Base-only (no toolchains) is expressed explicitly as `modules: []` → `cc/base`. No
  silent precedence rule.
- **2026-07-24 — Review 2 batch applied.** Buildability: assembled `docker build`
  uses `-f .cc-docker/assembled.Dockerfile` (context later scoped to
  `$CC_DOCKER_DIR/bootstrap` per review-3 #7) so `COPY` of the bootstrap scripts
  resolves; `stack/*` are local-only images (build.sh builds them; version-aware tags
  per #14); new `base` drops `ENTRYPOINT`/scripts (finals own it); the assembled
  image is global-per-module-set (per-project Dockerfile is an idempotent input). Semantics: `build_deps` = apt *beyond base* (node/zulu → empty);
  `runtime_deps` satisfied by a union `apt install` in the final, **not** by growing
  `base` (that re-introduces the cascade). `stack/node` staging must
  `chmod -R a+rwX $COREPACK_HOME` (root-built, container runs as mapped user).
  Canonical sort = Python `sorted()`; only cc-config computes it (closes #7).
  Required schema work: relax `cc-docker.schema.json` (`image` optional + `modules`)
  and add `module.schema.json` + cc-assemble validation. Migration: init-cc's
  `images/` menu loop and `build.sh`'s discovery/topo machinery are obsolete rewrites
  — only `legacy/` keeps them.
- **2026-07-24 — Bands are named (one word each): `base` (1+claude), `stack` (2),
  `extras` (3), `bootstrap` (4).** The name doubles as the image name/namespace:
  `base` (single image), `stack/<name>` (per-module). `cc-` org prefix dropped.
