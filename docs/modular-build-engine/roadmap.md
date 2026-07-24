# Modular build engine — POC roadmap

> Implementation plan for the design in [`README.md`](README.md). Phases are ordered
> by dependency; each has a clear **objective**, the **work**, and **verification**
> (observable pass/fail, not "looks right"). Rationale for every choice lives in the
> README's decisions log — this doc is the *what to build and how to prove it*, not
> the *why*.
>
> **Scope:** the POC proves the design on the maintainer's real stacks (`node`,
> `zulu`). Everything under "Post-POC" is explicitly out of scope for now.
>
> **Definition of done (POC):** a project with `modules: [node, zulu]` launches via
> `cc` into a working container (node + java + claude); editing a bootstrap script
> rebuilds only the bootstrap layer in seconds; and adding a module to one project
> never rebuilds another's toolchains. (Phase 6 is exactly this, made testable.)

## Dependency overview

```
P0 migration scaffold ─┬─ P1 base ─┬─ P2 stack modules ─┬─ P4 build.sh ─┐
                       │           │                    │               ├─ P5 launcher ─ P6 acceptance
                       └───────────┴─ P3 schemas+generators ────────────┘
```

- **P1** needs only the repo skeleton from **P0**.
- **P2** needs **P1** (`stack/*` are `FROM base`).
- **P3** (schemas + cc-config/cc-assemble) needs **P2**'s `module.yml` files to
  generate against, but is otherwise parallel to **P4**.
- **P4** (`build.sh`) needs **P1/P2** (things to build).
- **P5** wires **P3 + P4** together at launch. **P6** is acceptance over **P5**.

> **Sandbox note.** Verification steps run `docker build`/`docker run`. Run them where
> a Docker daemon is available; inside the cc-docker sandbox this may need to be a
> host shell (`! <cmd>`). None of the *authoring* work needs Docker.

---

## P0 — Migration scaffold (legacy cut + skeleton)

**Objective.** Establish the clean-cut layout so legacy keeps working while the
modular tree is built alongside it.

**Work.**
- `git mv` the current implementation into `legacy/`: `images/`, `build.sh`,
  `Makefile`, `completions/`.
- Create `bootstrap/` with the canonical `cc-wrapper.sh`, `run-as-hostuser.sh`,
  `sandbox.md` (copies of today's `images/base/` scripts; `legacy/images/base/`
  keeps its frozen originals).
- Create empty skeletons: `base/`, `stack/node/`, `stack/zulu/`, `toolchain/assemble/`,
  new top-level `build.sh` + `Makefile` (stubs for now).

**Note.** `toolchain/` (cc-config, cc-dev, + new cc-assemble) stays top-level. Those
images are already built, and the *new* `build.sh` (P4) takes over building them; the
frozen `legacy/build.sh` only sees `legacy/images/`. `cc` (launching an existing
project) doesn't glob `images/`, so live launches keep working through the migration;
only `init-cc`'s new-project menu goes stale until its P5 rewrite.

**Verify.**
- `cd legacy && ./build.sh zulu21` still builds a legacy `cc-zulu21` image (from
  `legacy/images/`).
- A legacy project (`image: cc-zulu21`/`cc-dev`) still launches via `cc` (unchanged path).
- `bootstrap/` contains the three files; scripts are `chmod +x`.
- `git status` shows moves, not deletes+adds (history preserved).

---

## P1 — `base` image (band 1 + claude)

**Objective.** The minimal shared foundation every final and every module builds on.

**Work.**
- `base/Dockerfile`: `FROM debian:bookworm-slim`; `apt-get install` exactly
  `curl ca-certificates git gosu make wl-clipboard xclip`; install `claude`.
- **No scripts, no `ENTRYPOINT`** (finals own the entrypoint).

**Verify.**
- `docker build -t base base/` succeeds.
- `docker run --rm base sh -lc 'command -v claude curl git gosu make xclip wl-copy'`
  prints a path for each.
- `docker inspect -f '{{.Config.Entrypoint}}' base` → `[]`/`<no value>`.
- Image is debian/glibc based (`docker run --rm base ldd --version` shows glibc).

**Depends on:** P0.

---

## P2 — `stack/node` and `stack/zulu` modules

**Objective.** Two cleanly relocatable, version-tagged toolchain modules that stage
`FROM base`.

**Work.**
- `stack/node/`: `Dockerfile` unpacks the Node **tarball** into `/usr/local/node`,
  runs `corepack enable`, then `chmod -R a+rwX "$COREPACK_HOME"`. `module.yml`:
  `name: node`, `version: "20"`, `build_deps: []`, `runtime_deps: []`,
  `artifacts: [/usr/local/node]`, `env: {PATH: "/usr/local/node/bin:${PATH}",
  COREPACK_HOME: /usr/local/node/corepack}`.
- `stack/zulu/`: `Dockerfile` unpacks the Zulu 21 **tarball** into `/usr/local/zulu`.
  `module.yml`: `name: zulu`, `version: "21"`, `artifacts: [/usr/local/zulu]`,
  `env: {JAVA_HOME: /usr/local/zulu, PATH: "/usr/local/zulu/bin:${PATH}"}`.
- Both `FROM base`; both arch-detect the tarball (amd64/arm64).

**Verify.**
- `docker build -t stack/node:20 stack/node/` and `stack/zulu:21 stack/zulu/` succeed.
- `docker run --rm stack/node:20 /usr/local/node/bin/node --version` → `v20.*`;
  `yarn --version` works via corepack.
- `docker run --rm -u 1000:1000 stack/node:20 sh -lc 'corepack prepare pnpm@latest'`
  succeeds (COREPACK_HOME is writable by a non-root mapped user — the review-2 #10 check).
- `docker run --rm stack/zulu:21 /usr/local/zulu/bin/java -version` → `21.*`.
- **Relocatability:** a throwaway `FROM base` + `COPY --from=stack/node:20
  /usr/local/node /usr/local/node` image runs `node --version` (artifact self-contained).

**Depends on:** P1.

---

## P3 — Schemas + generators (cc-config extension, cc-assemble)

**Objective.** Config → compose + sidecars; modules → an assembled Dockerfile — all
YAML parsing stays in containers.

**Work.**
- **Schema:** relax `cc-docker.schema.json` to `oneOf` (`image` | `modules`); add the
  `modules` array. Update `generate-compose.py` to: accept `modules:`, compute the
  `cc/<sorted-names>` tag (Python `sorted()`), write `.cc-docker/assembled.tag` **and**
  `.cc-docker/assembled.modules`; keep the legacy `image:` path.
- **module.schema.json** + validation inside cc-assemble (mirror `validate_config`).
- **cc-assemble** (new container, sibling of cc-config): read `modules:` +
  `stack/*/module.yml` → emit `.cc-docker/assembled.Dockerfile`: `FROM base`, one
  `COPY --from=stack/<name>:<version>` per module, a single merged `ENV PATH`
  (sorted, deduped) + one `ENV k=v` per non-PATH var, then `COPY` bootstrap scripts,
  then `ENTRYPOINT`.
- _(P2 finding)_ `ENV PATH` covers `docker run`/`exec` and `claude` (non-login), but
  a login shell resets `PATH` via `/etc/profile`. Minor, but consider having
  cc-assemble also emit `/etc/profile.d/cc-stacks.sh` exporting the same PATH so
  interactive `bash -l` sessions see `/usr/local/*/bin`. Not needed for the cc flow.

**Verify.**
- Schema: `image` + `modules` together → validation error; neither → error;
  `modules: [node, zulu]` → OK; `image: cc-zulu21` → OK; `modules: []` → OK.
- cc-config: modular config → compose `image: cc/node-zulu`; `assembled.tag` =
  `cc/node-zulu`; `assembled.modules` = `node\nzulu`; `modules: []` → `cc/base`.
- cc-assemble output for `[node, zulu]` contains both `COPY --from=…:20/:21` lines,
  a single `ENV PATH="/usr/local/node/bin:/usr/local/zulu/bin:${PATH}"`,
  `JAVA_HOME`/`COREPACK_HOME`, the bootstrap `COPY`, and `ENTRYPOINT`.
- A `module.yml` with a typo'd key → cc-assemble fails with a clear per-field error.

**Depends on:** P2 (module.yml exist), P0.

---

## P4 — new `build.sh` (block builder)

**Objective.** Build `base` + named stacks, version-tagged, always via `docker build`.

**Work.**
- Rewrite (not extend): `build.sh [module …]`. With args, build `base` first, then
  each named `stack/<name>` — `grep '^version:' stack/<name>/module.yml` to tag
  `stack/<name>:<version>`. No args → discover and build `base` + all `stack/*` +
  all `toolchain/*`.
- Also builds the **toolchain images** (`cc-config`, `cc-assemble`, `cc-dev`):
  `docker build -t cc-<name> toolchain/<name>`. They moved out of the frozen
  `legacy/build.sh`'s reach (which only sees `legacy/`), so the new builder owns them.
- Always `docker build` (no presence check); no `FROM cc-*` discovery/topo-sort.

**Verify.**
- `./build.sh base node zulu` → `base`, `stack/node:20`, `stack/zulu:21` exist
  (`docker images`).
- Re-run with no changes → all cache no-ops (sub-second per image).
- Edit `stack/node/Dockerfile` → re-run rebuilds only node's changed layers.
- `./build.sh` (no args) builds `base` + every discovered `stack/*`.
- `./build.sh node` alone still builds `base` first (dependency respected).

**Depends on:** P1, P2.

---

## P5 — launcher wiring (`init-cc.sh`)

**Objective.** End-to-end lazy assembly at `cc` launch, modular + legacy.

**Work.**
- **Mode detection:** after running cc-config, branch on sidecar presence —
  `.cc-docker/assembled.tag` exists → modular; else legacy `image:` path.
- **Modular path:** run cc-config + cc-assemble (containers, forwarding
  `CC_DOCKER_DIR` etc.); read names from `.cc-docker/assembled.modules` →
  `build.sh base <names>`; read tag from `.cc-docker/assembled.tag`; under a
  `flock` at `${XDG_RUNTIME_DIR:-/tmp}/cc-docker/locks/<sanitized-tag>.lock`, run
  `docker build -f .cc-docker/assembled.Dockerfile -t <tag> "$CC_DOCKER_DIR/bootstrap"`;
  then `docker compose run`.
- **Legacy path:** unchanged (prebuilt `image:`). Do **not** error when `images/` is
  absent (it moved to `legacy/`).

**Verify.**
- Modular project (`modules: [node, zulu]`): `cc` drops into a container where
  `node --version`, `java -version`, and `claude` all work.
- Legacy project (`image: cc-zulu21`): `cc` still launches as before.
- `modules: []`: `cc` runs `cc/base` (claude works, no toolchains).
- Two concurrent `cc` in the same module set: the flock serialises them (no
  duplicate-build error; second waits then reuses).
- No `cc-docker.yml` at all → the current "run init-cc" guidance, not a crash.

**Depends on:** P1–P4.

---

## P6 — Acceptance (prove the design's promises)

**Objective.** Demonstrate the three properties the whole redesign exists for.

**Verify (each is a pass/fail demo).**
1. **Cascade killed.** Edit `bootstrap/run-as-hostuser.sh`; next `cc` rebuild touches
   only the bootstrap `COPY` layer — seconds, not the old 5–10 min. (Observe: single
   changed layer in build output; `base`/`stack` layers `CACHED`.)
2. **Isolation.** Project A `modules: [node]`, project B `modules: [zulu]`. Launch A,
   then B; building/adding to A leaves B's `stack/zulu:21` cache untouched (no rebuild
   in B's next launch).
3. **Sharing.** Two projects both `modules: [node, zulu]` resolve to the *same*
   `cc/node-zulu` image (built once; second launch's assembled build is a no-op).
4. **Correctness (no stale reuse).** Bump `stack/node`'s `version:` (+ Dockerfile) →
   next launch builds the new tag and the final picks it up; no silent stale image.

**Depends on:** P5.

---

## Post-POC (deferred — not in scope now)

Tracked in the README's Open questions / Future refinements; listed here for
completeness and rough ordering:

- **Interactive `modules:` authoring in init-cc** (multi-select menu, module
  discovery, legacy-vs-modular offer).
- **Per-project apt** (`apt: [...]` in `cc-docker.yml`) → union layer in the final;
  triggers the **hashed tag + descriptive labels** scheme.
- **Module `runtime_deps` union install** codegen in cc-assemble.
- **Relocatable Python module** → unblocks `pdf2md` (`stack/python` via
  python-build-standalone / uv).
- **Module artifact checksums** (per-arch SHA in `module.yml`, verified at staging).
- **Selective module builds** (`build.sh` builds only referenced modules).
- **Assembled-build fast-path** (skip the always-on `docker build` when nothing
  changed).

## Status

_(update as phases land)_

- [x] P0 — Migration scaffold (2026-07-24; legacy build verified: `cc-zulu21` builds
      from `legacy/images/`. Not committed yet.)
- [x] P1 — `base` (2026-07-24; builds, tools present, no ENTRYPOINT, glibc 2.36, claude runs)
- [x] P2 — `stack/node`, `stack/zulu` (2026-07-24; node v20.20.2/yarn 4.17.1, zulu
      21.0.12, corepack writable by uid 1000, relocatable via COPY --from)
- [x] P3 — Schemas + generators (2026-07-24; oneOf validates, cc-config writes
      tag/modules sidecars in modular mode + clears them in legacy, cc-assemble emits
      correct assembled.Dockerfile; legacy path intact)
- [ ] P4 — `build.sh`
- [ ] P5 — Launcher wiring
- [ ] P6 — Acceptance
