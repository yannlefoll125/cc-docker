# Review — Modular build engine design doc

> Review of [`README.md`](README.md) against the current implementation
> (`build.sh`, `init-cc.sh`, `toolchain/config/generate-compose.py`, the schema,
> and every `images/*/Dockerfile`). Findings only — no edits to the design doc.

## Overall

The doc is strong: the root-cause analysis (runnable-images-as-parents, not image
count) is correct and well-argued, the 4-band model is a clean framing, and the
decisions log is excellent provenance. The problems are mostly (1) drift between
the prose and its own decisions log, and (2) claims about "today" that don't match
the actual code. Findings are grouped by severity below.

## Internal contradictions

**1. `claude` is in band 1 in the table but band 4 in the prose.** The band table
(line 54) puts `claude` in band 1 (`base`), and the decisions log agrees (line
450). But the "claude placement note" opens with *"The 4-band model lists claude
in band 4 (volatile-ish)"* (line 323). The table never lists it in band 4. The
note's whole framing ("pragmatically move it out of band 4 to base") argues
against a placement the model doesn't actually specify. Either the note is stale
or the table is — reconcile.

**2. Assembled-final naming is simultaneously "open" and "resolved."** Lines 74–75
and line 489 mark assembled-final naming `_(open)_`, but the decisions log (lines
440–444) resolves it firmly to `cc/<sorted-names>` (e.g. `cc/node-zulu21`, empty
set → `cc/base`). These directly contradict. Compounding it, the examples don't
use the resolved form: line 289 writes `image: node-zulu21`, line 298
`node-zulu21`, and the flow/shape sections never show the `cc/` prefix. Pick one
and make every example consistent — right now a reader can't tell if the tag is
`node-zulu21` or `cc/node-zulu21`.

**3. Staging-base convention states two different rules in one subsection.** Lines
231–238 state the convention as *"FROM debian:bookworm-slim"* with an ABI-matching
rationale — then lines 240–248 say *"Resolved: stack/* modules stage FROM base,
not raw debian:bookworm-slim."* The opening paragraph is superseded pre-decision
text left in place; as written the subsection asserts both. The "Resolved" block
should replace the opening claim, not sit beneath it.

## Claims that don't match the current code

**4. "base (bands 1 + 3 today)" is not true today.** Lines 54, 66–69, and 94
present the current `base` as already holding convenience apt (band 3: `ripgrep`,
`fd`, `jq`, `fzf`, `bat`, `tree`, `vim`, `ruby-full`). It doesn't —
`images/base/Dockerfile` is minimal, and *all* of those tools live only in
`cc-full`. Merging extras into `base` is a **new design choice**, not the status
quo; the doc should frame it that way rather than "today."

**5. The band-1 example list doesn't match `images/base/Dockerfile`.** Line 54
lists band 1 as `curl, ca-certificates, git, build-essential, gosu, claude`. The
actual base installs `curl, ca-certificates, git, gosu, make, wl-clipboard, xclip`
+ claude. So:
- `build-essential` is listed as band-1 foundational but is **not** in base today
  — it's in `cc-full`.
- `make`, `wl-clipboard`, `xclip` **are** in base today but appear nowhere in the
  band model. `wl-clipboard`/`xclip` back the `display:` clipboard feature
  (cc-config forwards the socket) — they're not optional trivia. The model needs to
  place them, or the doc should note they're being dropped/relocated.

## Gaps (unaddressed but load-bearing)

**6. The tag is computed twice, with no single source of truth.** The "three
actors" table (line 276) and lines 296–299 have *both* cc-config (to write
`image:` into compose) and cc-assemble compute the deterministic tag
"identically." Two independent implementations of the same algorithm in two
different containers is a drift hazard. Consider one actor computing it and passing
it to the other, or extracting a shared helper — the doc doesn't say why the
duplication is acceptable.

**7. `init-cc.sh`'s interactive flow is unaddressed.** init-cc is named as a
shared, extended actor, but today it presents a numbered menu of `images/*/` and
writes `image: cc-<x>`. Nothing in the doc covers how a user *produces* a
`modules:` config interactively — module discovery, a multi-select menu, or how the
menu behaves when both legacy `image:` and modular `modules:` are offered. This is
a real hole given init-cc is one of the migration's "shared, not legacy" pieces.

**8. No module cache-invalidation / staleness story.** The lazy flow (line 291)
says the launcher will "ensure base + stack/* exist (build.sh)," and the
assembled-image check is specified ("tag missing → build"). But: (a) how is
"exists" checked for base/stack — image presence only? (b) If a `module.yml` or a
module `Dockerfile` changes, its `stack/*` tag doesn't change, so a stale cached
module image would be silently reused. There's no version/hash on module tags. The
whole doc is about cache correctness, so this deserves a paragraph.

**9. Lazy-build UX: first-run latency and concurrency.** Building the assembled
image (and possibly base + all stacks via build.sh) *inside* the `cc` launch means
the first `cc` in a fresh project pays a potentially multi-minute build inline —
ironic given the motivation was killing long rebuilds. There's also no mention of a
lock to stop two concurrent `cc` invocations racing to build the same tag. Worth at
least acknowledging.

**10. `runtime_deps` union install has no home in the band diagram.** Line 224 says
the assembler emits a union `apt install` of runtime_deps "in the final image," but
the assembled Dockerfile shape (lines 311–320) only shows a `[refinement]
per-project apt` comment — no slot for runtime_deps. Where does it fall in band
order relative to the module COPYs? Moot for the POC (both modules are empty) but
the mechanism the doc says "has to exist" isn't placed.

**11. `toolchain/dev/` is missing from the proposed repo layout.** The repo has
`toolchain/dev/` (cc-dev, `dev-wrapper.sh`, `docker-shim.sh`), but the
post-migration layout (lines 350–369) lists only `toolchain/config/` and
`toolchain/assemble/`. Is cc-dev shared, legacy, or dropped? Unstated.

## Minor / polish

- **Status overstates completeness.** The header says "All substantive decisions
  are made," yet assembled-final naming is still flagged open (see #2) — a
  substantive, user-visible naming decision. Soften or resolve.
- **"bootstrap is scripts only" but includes `sandbox.md`** (lines 57, 327) — a
  markdown doc, not a script. Tiny terminology mismatch.
- **`ruby-full` listed as a "convenience apt" extra** (line 56) sits oddly next to
  `jq`/`vim` — it's a full language runtime. It's there because it's
  apt-only/non-relocatable (line 107), which is defensible, but the band assignment
  (a language in "extras" rather than "stack") is worth a one-line justification
  since it blurs the stack-vs-extras distinction the model rests on.
- **ASCII root-cause graph (lines 19–23) is hard to parse** — the `└─ cc-zulu21`
  line sits under the `cc-node20 … cc-full` row, visually implying zulu21 descends
  from node20 when it descends from base. A clearer tree would help since this
  diagram carries the core argument.
- **`base` vs `cc/base` naming collision.** Empty module set → assembled image
  `cc/base` (line 442), while the shared foundation image is `base`. Two
  near-identical names for different things (one has bootstrap+ENTRYPOINT, one
  doesn't). The `cc/` namespace disambiguates, but a sentence calling this out
  would prevent confusion.
