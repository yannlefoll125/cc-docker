# Review 3 — Modular build engine design doc

> Third pass over [`README.md`](README.md), after [`review.md`](review.md) and
> [`review_2.md`](review_2.md) were both incorporated. The doc is in good shape now;
> this pass is a re-read looking mainly for **residual drift introduced by the edits**
> and **new tensions the revisions created**, not fresh design angles. Findings only.

## Contradictions the edits left behind

**1. The "Modular engine — concept" block still says `bands 1 + 3`.** Line 127
reads `shared base (bands 1 + 3, apt)`. But the whole point of the review-1 fix —
now settled in lines 69–70, 102–103, and decision line 616 — is that **band 3
(`extras`) is *not* in `base`**; it's deferred to per-project apt. This one diagram
is a leftover from the old "bands 1+3 today" claim that didn't get propagated. Should
read `band 1 (apt) + claude`. (Line 356 already has it right, so this is an isolated
straggler.)

**2. Does the `cc` launcher run `build.sh`, or is `build.sh` a prerequisite?** The
lazy-flow diagram makes it a step of every launch — line 315: `host bash → build.sh
— always docker build base + stack/...`. But two other places treat `build.sh` as a
*separate/manual* thing: the launcher "preflights their presence with a clear **run
`build.sh` first** error" (lines 390–391), and decision line 585 scopes `build.sh`
to "building blocks only… the launcher assembles per-project finals lazily." These
can't all be true: if `cc` invokes `build.sh` itself, the "run build.sh first"
preflight is dead code; if `build.sh` is a manual prerequisite, the flow diagram
shouldn't list it as a launch step. Pick one and make the flow, the preflight, and
the decision agree.

**3. `flock` scope contradicts the "global per module set" property.** The
cache-correctness section says the flock "serialises concurrent `cc` invocations in
the **same project**" (lines 344–345), while decision line 614 says "**a `flock` per
assembled tag**." These differ, and the difference matters: lines 398–402 establish
that the assembled image is **global per module set** (`cc/node-zulu` shared across
projects). So two *different* projects with the same `modules:` race to build the
same tag — a per-project flock wouldn't prevent that; only a per-tag lock in a
**shared** location would. The doc also never says where the lock file lives (it
can't be in a project's `.cc-docker/` if it's meant to be cross-project). Resolve to
per-tag + a shared lock path.

**4. `runtime_deps` union install: POC or post-POC?** Three places disagree. The
assembled-shape comment marks it `# [refinement] runtime_deps union apt-install`
(lines 369–370), Future refinements lists "Module `runtime_deps` union install" as
post-POC (lines 492–493) — but the POC checklist says cc-assemble generates "COPY
--from + merged ENV + **runtime_deps union** + bootstrap COPY" (line 424). Either the
union-install codegen is in the POC assembler or it isn't. (Given both POC modules
have empty `runtime_deps`, the cleanest resolution is: mechanism deferred, checklist
line 424 should drop "runtime_deps union.")

## Minor / polish

**5. Status header credits only `review.md`.** Line 4 says "A code-grounded review
(`review.md`) has been fully incorporated," but the decisions log shows review 2 was
also applied in full (line 636, "Review 2 batch applied," plus the version/`oneOf`/
buildability decisions). The status undersells what's been folded in — mention both,
or say "the review passes."

**6. "Two versions can coexist as distinct tags" is slightly overstated.** Line 387
implies `stack/node:20` and, say, `stack/node:22` can coexist — but there's **one
`module.yml` per `stack/<name>/` dir** (line 448), pinning a single `version:`, and
`build.sh` builds only what's defined. So nothing actually builds a second version
concurrently; coexistence is theoretical until there are separate module dirs. The
version-aware tag is still well-justified as **cache-busting** (a bump makes a new
tag rather than mutating `:latest`) — just lead with that rather than coexistence.

**7. Build context is the entire `$CC_DOCKER_DIR`.** Line 382 builds with context
`$CC_DOCKER_DIR` so `COPY bootstrap/…` resolves — correct, but that context now
includes `.git/`, `legacy/` (the whole frozen tree), `images/`, `toolchain/`, etc.,
all uploaded to the daemon on every assembled build. A `.dockerignore` scoping the
context to `bootstrap/` (the only thing the final actually `COPY`s) would keep the
always-on build cheap and is worth a line in the build-mechanics section.

## Confirmed resolved

For the record, the substantive items from passes 1–2 are genuinely closed, not
papered over: claude band 1-vs-4 (now consistently band 1, lines 404–411); assembled
naming `cc/<sorted-names>` with the `base` vs `cc/base` distinction spelled out
(lines 79–83); staging-base single rule (`FROM base`, lines 248–258); single tag
source of truth via the `.cc-docker/assembled.tag` sidecar (lines 320–330); band-1
contents corrected to match the real `base` incl. `make`/`wl-clipboard`/`xclip`
(decision line 616); schema `oneOf` + `module.schema.json` (lines 277–289);
build-context/entrypoint/COREPACK perms mechanics (lines 376–402); and the
init-cc/`build.sh` migration breakage called out explicitly (lines 467–477). Nice
turnaround.
