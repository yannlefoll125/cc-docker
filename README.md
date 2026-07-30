# Claude Code Docker Environment

Run Anthropic's [Claude Code](https://github.com/anthropics/claude-code) CLI in an isolated Docker container, one container per project.

## What this is (and isn't) for

The goal is **project isolation**, not network isolation from Anthropic.

Claude Code is a capable agent with broad filesystem and shell access. Run directly on a developer laptop, it can in principle read anything the logged-in user can read: other repositories, SSH keys, browser profiles, shell history, `~/.aws`, other projects' `.env` files, and so on. Even with good intentions, a single misinterpreted prompt — or a prompt-injection payload hidden in a dependency, issue, or web page — can cause the agent to pull context from one project into another.

Running Claude inside a per-project container fixes that. The container only sees:

- The current project directory (at its host path)
- A **dedicated per-project Docker volume** for Claude's config/state, mounted at `/home/hostuser/.claude` (with `CLAUDE_CONFIG_DIR` pointed at it). It is created fresh per project and never touches your host `~/.claude` — so your host Claude config, credentials, and every other project's transcripts/history are simply not present in the container.

It does **not** see other repos on your machine, your home directory, SSH keys, your host `~/.claude`, or any sibling project's working tree. A prompt injection inside project A cannot read project B's code, because project B isn't mounted — and project B's Claude transcripts, prompt history, and MCP configs live in B's own volume, so they can't be exfiltrated either.

> Because the config volume is decoupled from the host, it is mounted fully read-write with no masking, and it is a net security improvement over the previous host bind mount: a compromised agent can no longer write a hook into your *host* `~/.claude` execution context, and there is no cross-project `~/.claude.json` leak. See `docs/security-audit.md` (findings #1/#2).

What this does **not** do:

- It does not prevent code from being sent to Anthropic's API. That is inherent to using Claude Code — your prompts and file contents are sent to Anthropic as part of normal operation. If you don't want code leaving your machine at all, don't run Claude Code on it.
- It does not sandbox network access. The container can reach the internet like any other process.

Think of it as a seatbelt against *cross-project* leakage and agent-mediated accidents on your own filesystem, not as a confidentiality boundary against Anthropic.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Docker Compose](https://docs.docker.com/compose/install/)

## Scripts

### `build.sh`

Builds the reusable **building blocks** of the modular engine — the shared `base`
image, the `stack/*` toolchain modules, and cc-docker's own `toolchain/*` images
(`cc-config`, `cc-assemble`, `cc-dev`). It does **not** build the per-project runnable
images; the `cc` launcher assembles those on demand when invoked with `--build` (see
[Stack modules](#stack-modules)).

```bash
./build.sh              # base + all toolchain/* + all stack/*   (full / CI / pre-warm)
./build.sh node zulu    # base + just the named stack modules
```

`base` is always built first (everything stages `FROM base`). Every build is a plain
`docker build`, so Docker's layer cache makes it a fast no-op when nothing changed.
There's no dependency graph to maintain — modules are independent and *composed*, not
chained.

The frozen pre-modular builder (the old `FROM cc-*` topo-sort over `images/`) lives at
`legacy/build.sh`; see [Legacy images](#legacy-images).

### `init-cc.sh`

Source this into your shell to get the `cc` launcher (and the `init-cc` setup helper) — either
run `make install` from this repo (checks whether it's already sourced in `~/.bashrc` and appends
it if not, no-op if it's already there), or add the two lines yourself:

```bash
export CC_DOCKER_DIR=/path/to/cc-docker
source "$CC_DOCKER_DIR/init-cc.sh"
```

Sourcing this file defines three shell functions: `init-cc` (interactive setup — see note below),
`cc` (the launcher, see [`cc` (the launcher)](#cc-the-launcher)), and `migrate-cc` (upgrade a
pre-modular project to `modules:`, see [Legacy images](#legacy-images)).

Then, from any project directory, run `init-cc`. It prompts for:

- **Project root** (defaults to the current directory)
- **Modules** — space-separated stack module names (see `make stacks` for the list);
  blank for just `base`. Unknown names are rejected.
- **Git user name and email** (defaults to your global `git config` values)
- **Whether to add `.cc-docker/` to `.gitignore`**

It writes `.cc-docker/cc-docker.yml` with your `modules:` list; run `cc --build` to
assemble and build the image (plain `cc` just runs it). For a legacy prebuilt image (e.g. `cc-dev`)
or a hand-written raw `docker-compose.yml`, write `.cc-docker/cc-docker.yml` yourself
instead — see [Legacy images](#legacy-images).

When done, run Claude Code with `cc` from the project root (or any subdirectory).

### `cc` (the launcher)

Defined by `init-cc.sh` alongside `init-cc`. On each invocation it:

1. Walks up from the current directory to find `.cc-docker/`, so it works from any subdirectory
   of the project.
2. If `.cc-docker/cc-docker.yml` exists, regenerates `.cc-docker/docker-compose.yml` from it via
   the `cc-config` image, every time — generation only takes a few ms, so there's no staleness
   check to get wrong.
3. **Modular mode** (config has `modules:`): `cc-config` also writes the tag/module
   sidecars. By default `cc` is **run-only** — it does not (re)build; if the assembled
   image doesn't exist yet it fails fast with a hint. Pass `--build` (or set
   `CC_BUILD=1`) to build first: `cc` runs `cc-assemble` (→ `assembled.Dockerfile`),
   builds `base` + the selected stacks via `build.sh`, and builds the per-project final
   image (under a lock). All are plain `docker build`s, so unchanged pieces are cache no-ops.
4. Runs `docker compose -f .cc-docker/docker-compose.yml run --rm cc "$@"`.

Pass `--generate-only` (or set `CC_GENERATE_ONLY=1`) to stop after step 2/3 — `cc`
regenerates `.cc-docker/docker-compose.yml` (and the modular sidecars) from `cc-docker.yml`
and returns without assembling, building, or launching claude. Handy for inspecting the
generated compose file or wiring it into other tooling.

A `cc-docker.yml` is required. A project with only a hand-written
`.cc-docker/docker-compose.yml` and no `cc-docker.yml` (the old "raw compose" setup) is **no
longer run**: that file lives in the read-write project mount, so a compromised agent could
rewrite the compose that defines the next session's sandbox (`privileged`, `user: root`,
extra host mounts) with no generator in the loop to constrain it
(`docs/security-audit.md` #3). `cc` prints an error pointing at `migrate-cc`, which converts
the compose to a `cc-docker.yml` (the generator then hardens it).

So with a native `cc-docker.yml`, editing it and re-running `cc` always picks up config
changes (the compose file regenerates every time). Changes to the *image* — editing a
`bootstrap/` script, a stack, or the `modules:` list — need a `cc --build` to take effect;
that only rebuilds what changed, since the toolchains stay cached.

## Project Structure

```
.
├── .cc-docker-dev                # committed marker; see below
├── .cc-docker/                   # per-project, gitignored: config + generated artifacts
│   ├── cc-docker.yml             # native config (source of truth)
│   ├── docker-compose.yml        # generated from cc-docker.yml (never hand-edit)
│   ├── assembled.Dockerfile      # modular: generated recipe for the final image
│   ├── assembled.tag             # modular: final image tag (e.g. cc/node-zulu)
│   └── assembled.modules         # modular: selected module names (for the launcher)
├── base/
│   └── Dockerfile                # shared `base` image: Debian Bookworm slim + Claude CLI
├── stack/                        # relocatable toolchain modules, composed into finals
│   ├── node/                     # → stack/node:<version>   (Dockerfile + module.yml)
│   └── zulu/                     # → stack/zulu:<version>
├── bootstrap/                    # entrypoint scripts baked into every final image
│   ├── cc-wrapper.sh             #   root phase: match host UID/GID, re-exec via gosu
│   ├── run-as-hostuser.sh        #   user phase: git config, runs claude
│   └── sandbox.md                #   appended to claude's system prompt
├── toolchain/                    # cc-docker's own tooling images
│   ├── config/                   # cc-config: cc-docker.yml → docker-compose.yml (+ sidecars)
│   ├── assemble/                 # cc-assemble: modules → assembled.Dockerfile
│   └── dev/                      # cc-dev: this repo's own dev environment (see below)
├── build.sh                      # modular block builder
├── docs/modular-build-engine/    # the design, reviews, and roadmap
└── legacy/                       # frozen pre-modular impl (old cc-* images + builder)
```

`.cc-docker-dev` (a file at the repo root, not inside `.cc-docker/`) is a marker committed to this
repo only — it's what lets `cc-dev` refuse to run in any other project (see
[Why cc-dev is restricted to this repo](#why-cc-dev-is-restricted-to-this-repo)).

## Usage

**1. Build the blocks** (base + modules + toolchain images) — once, and after edits:

```bash
./build.sh
```

**2. Set up your project** — run `init-cc` (prompts for modules + git identity), or
hand-write `.cc-docker/cc-docker.yml` (see [Setting up a project](#setting-up-a-project)):

```yaml
modules: [node, zulu]
git:
  name: Your Name
  email: you@example.com
mounts:
  - path: .
```

**3. Build the image, then run Claude Code:**

```bash
cc --build          # first run (and after any image/module change): assemble + build
cc                  # subsequent runs: just launch the already-built image
cc --generate-only  # only regenerate docker-compose.yml from cc-docker.yml; don't build or run
```

`cc` works from the project root or any subdirectory (see [`cc` (the launcher)](#cc-the-launcher)).
Plain `cc` is run-only and launches fast; `cc --build` (or `CC_BUILD=1`) assembles and builds
your project's image first. Either way it then mounts your project files, Claude
credentials, and auth state into the container. See [The container environment](#the-container-environment)
for how ownership and credentials work.

## Stack modules

Instead of a fixed set of prebuilt images chained by `FROM`, a project's image is
**composed** from `base` plus the relocatable toolchain modules it selects in
`cc-docker.yml`:

| Module | Provides |
|--------|----------|
| `node` | Node.js (tarball) with corepack/yarn — replaces the old `cc-node20`/`cc-vue3` |
| `zulu` | Azul Zulu JDK — replaces the old `cc-zulu21` |
| `python3` | CPython (relocatable python-build-standalone) with pip |
| `pdf2md` | `pdf2md` CLI — PDF → Markdown via pymupdf4llm (self-contained; bundles its own interpreter) |

Select them with `modules:` (e.g. `modules: [node, zulu]` for a project needing both;
`modules: []` for just `base`). The result is a single assembled image tagged
`cc/<sorted-modules>` (e.g. `cc/node-zulu`), built by `cc --build`. Run `make stacks`
to list the available modules with their versions.

Each module is a directory under `stack/` with a `Dockerfile` (a *staging* build that
downloads the toolchain into one self-contained dir) and a `module.yml` (metadata:
version, artifact dirs, env). Adding a toolchain is just: create `stack/<name>/` with
those two files — no build graph to edit.

### How the modular build works

`base` (Debian slim + Claude CLI, no entrypoint) is the shared foundation. Each
`stack/*` module builds `FROM base` and packages a relocatable toolchain into one
directory. For a given project, `cc-assemble` generates a Dockerfile that
`COPY --from`s the selected modules onto `base`, merges their env, and bakes the
`bootstrap/` scripts + `ENTRYPOINT` — producing the runnable `cc/<modules>` image.
Because the volatile bootstrap scripts are the *last* layers, editing them rebuilds
only that tail while the toolchains stay cached — the design's core win. See
[`docs/modular-build-engine/`](docs/modular-build-engine/) for the full design,
reviews, and rationale.

## The container environment

`base` is a Debian Bookworm slim image with the Claude Code CLI pre-installed. It is
the shared foundation every project's assembled image is built on; stack modules add
toolchains and the `bootstrap/` scripts provide the entrypoint.

### The `hostuser` model

The defining feature of the container is that it runs Claude Code as a user whose UID and GID match yours on the host. At startup, the entrypoint (baked from `bootstrap/`) reads the UID/GID from the project directory (via the `PROJECT_DIR` environment variable):

```bash
HOST_UID=$(stat -c "%u" "$PROJECT_DIR")
HOST_GID=$(stat -c "%g" "$PROJECT_DIR")
```

It then creates a `hostgroup`/`hostuser` pair with those IDs and drops privileges to that user via [gosu](https://packages.debian.org/bookworm/gosu) before running `claude`. The result: any file Claude creates inside the project directory is owned by you on the host — no `root`-owned artifacts, no `chown` cleanup after the container exits.

You don't have to bind-mount the whole project — mounting only selected subdirectories (to limit what Claude can see) is a supported setup too. The `cc` launcher forwards your host UID/GID to the container as `CC_HOST_UID`/`CC_HOST_GID`, so the entrypoint uses those directly (independent of any mount); when `$PROJECT_DIR` isn't bind-mounted it no longer needs to stat a mount to recover them.

The Claude config lives in a per-project Docker **named volume** (`cc-claude-<slug>`) mounted at `/home/hostuser/.claude`, not a host bind. It's root-owned on first mount, so the entrypoint chowns the mountpoint to your UID before dropping to `hostuser`; from then on the volume persists across runs (Docker doesn't remove named volumes on `run --rm`), holding this project's credentials, settings, transcripts, and memory — isolated from the host and from other projects.

### The two-phase entrypoint

Startup is split across two scripts because privilege drop requires root:

| Phase | Script | Runs as | What it does |
|-------|--------|---------|--------------|
| 1 | `cc-wrapper.sh` | root | Reads host UID/GID from `$PROJECT_DIR`, creates `hostgroup`/`hostuser`, `chown`s the home dir, re-execs via `gosu hostuser` |
| 2 | `run-as-hostuser.sh` | hostuser | Applies `GIT_USER_NAME`/`GIT_USER_EMAIL` if set, marks `$PROJECT_DIR` as a git safe directory, clears the terminal, runs `claude` |

### Never bake in a `USER`

Neither `base` nor any `stack/*` module should create a fixed user or set a `USER`
directive. The UID match happens at runtime from the `$PROJECT_DIR` mount, so baking in
a user would break the ownership alignment. Stack modules only *add relocatable tooling*
(a self-contained toolchain dir); the entrypoint is baked once, into the assembled
final, from `bootstrap/` — no module touches it.

## Setting up a project

The quick way is `init-cc` (see [`init-cc.sh`](#init-ccsh)) — it prompts for modules and
git identity and writes the config for you. To do it by hand, create
`.cc-docker/cc-docker.yml` in your project root, selecting the toolchain modules you
need with `modules:`:

```yaml
modules: [node, zulu]   # or [] for just base; see Stack modules for what's available
git:
  name: Your Name
  email: you@example.com
mounts:
  - path: .
```

(A legacy prebuilt image can be used instead with `image: cc-…` — see
[Legacy images](#legacy-images). Exactly one of `modules:` or `image:` is required.)

Then from your project root:

```bash
# Build the blocks once, from the cc-docker checkout
/path/to/cc-docker/build.sh

# Start Claude Code in your project
cc
```

`cc` generates `.cc-docker/docker-compose.yml` from `cc-docker.yml`, assembles and
builds your project's image, and runs it (see
[Configuring cc-docker](#configuring-cc-docker-cc-dockeryml) for the full schema). The resulting
compose file's volume mounts are the key pieces:

| Mount / setting | Purpose |
|-----------------|---------|
| `${PWD}:${PWD}` + `working_dir` + `PROJECT_DIR` | Mounts your project at its host path inside the container. Using the same path on both sides means Claude Code's per-project state bucket (keyed by cwd) is unique per project on the host — sessions from different repos stay separate in `~/.claude/projects/`. |
| `cc-claude-<slug>:/home/hostuser/.claude` (+ `CLAUDE_CONFIG_DIR`) | A per-project Docker **named volume** holding all of Claude's config/state — credentials, `settings.json`, transcripts, memory, and `.claude.json`. Fully read-write, decoupled from the host, isolated per project, and persistent across runs. `CLAUDE_CONFIG_DIR` points Claude Code at it so even `.claude.json` (normally at `$HOME`) lands inside the volume. To inspect it from the host: `docker run --rm -v cc-claude-<slug>:/v alpine ls /v`. |
| `CC_HOST_UID` / `CC_HOST_GID` (env) | Your host UID/GID, forwarded so the entrypoint can create `hostuser` and chown the config volume without stat-ing a mount. |
| `.cc-docker/.claude:$PROJECT_DIR/.claude` | Overlays the project-level Claude context (settings, plans, todos) into the gitignored `.cc-docker/.claude/`, so Claude's project-level writes never land in the committed/shared project tree. Scaffolded by `cc` on first run (`.cc-docker/.claude/settings.json`), and `cc` also adds `.claude/` to your project's `.gitignore` so the overlay doesn't show up as untracked inside the container. |

## Configuring cc-docker (`cc-docker.yml`)

`.cc-docker/docker-compose.yml` is a generated, disposable artifact, regenerated on every `cc`
invocation from a shorter declarative config, `.cc-docker/cc-docker.yml`. The generation is done by
`cc-config` (`toolchain/config/`) — a small tool that reads `cc-docker.yml` and writes
`docker-compose.yml`. Don't hand-edit `docker-compose.yml` — edit `cc-docker.yml`
instead, `cc` regenerates it for you.

**Tracking:** the whole `.cc-docker/` directory is gitignored. Using cc-docker is currently
treated as a personal choice — nothing about your setup (image, mounts, git identity, the
generated compose file) is committed, so nothing project-specific ends up in git history. If a
future need arises to let a project *share* a config across contributors, the clean way to do
that is splitting `.cc-docker/` into a tracked subdir (shared config) and a gitignored one
(per-developer overrides + the generated artifact) — not done today, but worth knowing the
current all-gitignored setup is a deliberate starting point, not an oversight.

`cc-docker.yml` fields:

Exactly one of `modules` or `image` is required (a `oneOf` in the schema — supplying
both, or neither, is a validation error).

| Field | Type | Required | Description |
|-------|------|----------|--------------|
| `modules` | list | one of | Modular: toolchain stack modules to compose, e.g. `[node, zulu]`. `[]` means just `base`. `cc --build` builds the assembled `cc/<sorted-modules>` image. |
| `image` | string | one of | Legacy: a prebuilt image to run directly, e.g. `cc-dev` or a `legacy/` image. Mutually exclusive with `modules`. |
| `git.name` / `git.email` | string | no | Git identity, exposed to the container as `GIT_USER_NAME` / `GIT_USER_EMAIL`. |
| `env` | map | no | Extra environment variables merged into the `cc` service. |
| `readonly` | boolean | no | If true, all mounts declared in `mounts` are read-only. Defaults to `false`. |
| `mounts` | list | no | Project paths to bind-mount. Each entry is `{path, exclude}`: `path` (required) is relative to the project root — use `"."` for the whole project; `exclude` is a list of glob patterns (relative to `path`) to shadow out with a `tmpfs` (directories) or a read-only `/dev/null` bind (files). |
| `extra_mounts` | list | no | Raw docker compose volume entries, appended verbatim — no validation. |
| `display` | string | no | `auto` (default) \| `wayland` \| `x11` \| `disabled` — forwards the host clipboard display socket so `claude` can paste images. `auto` forwards Wayland only; X11 needs an explicit `x11` (trusted cookie = full input access — see #5). See [Clipboard image paste](#clipboard-image-paste-x11wayland). |
| `anthropic_api_key_file` | string | no | Host path to a file containing your raw Anthropic API key. Delivered as a Docker secret and exported as `ANTHROPIC_API_KEY`. Optional — omit to use per-project OAuth login (an interactive `claude` login on first run, persisted in the project's config volume). See [API key auth](#api-key-auth-optional). |
| `docker_socket` | boolean | no | If true, mounts the host's `/var/run/docker.sock` into the container and grants `hostuser` access to it. Grants **root-equivalent access to the host Docker daemon** — see [Why cc-dev is restricted to this repo](#why-cc-dev-is-restricted-to-this-repo) for what that means. Defaults to `false`. Note `base` ships no `docker` CLI, so a plain `modules:` project still needs one installed some other way to actually use the socket. |
| `permission_mode` | string | no | Passed through to `claude --permission-mode` (`acceptEdits` \| `auto` \| `bypassPermissions` \| `manual` \| `dontAsk` \| `plan`). Omit to use claude's own default. Only takes effect with `modules:` — frozen `legacy/` (`image:`) entrypoints predate this option and ignore it. |

Example:

```yaml
modules: [node]
git:
  name: Your Name
  email: you@example.com
mounts:
  - path: .
    exclude:
      - node_modules
      - .env
```

`cc-config` validates `cc-docker.yml` against a JSON Schema
(`toolchain/config/cc-docker.schema.json`) before generating anything — an unknown key, supplying
neither (or both) of `modules`/`image`, or a `mounts` entry without a `path` all fail with a
readable error instead of silently producing a broken compose file.

The `cc` launcher does this automatically on every invocation (see [`cc` (the launcher)](#cc-the-launcher)).
To generate it by hand instead (e.g. for debugging):

```bash
docker run --rm \
  -e PROJECT_DIR="$PWD" \
  -v "$PWD/.cc-docker:/out" \
  -v "$PWD:/project:ro" \
  cc-config
```

### Clipboard image paste (X11/Wayland)

`base` ships `wl-clipboard` and `xclip`, so `claude` can paste images from the host clipboard.
Getting the clipboard's *contents* across the container boundary needs the host's display socket
forwarded in — a container has no access to the host's X11/Wayland session by default. `cc`
handles this automatically: it reads `$WAYLAND_DISPLAY`/`$DISPLAY` etc. from your host shell and
forwards them to `cc-config`, which wires up the right mount and env vars for you. `display: auto`
is the default.

**Wayland forwards automatically; X11 does not.** Under `auto`, a Wayland session is forwarded
freely, but an X11 session is **not** — X11 has no inter-client isolation, so forwarding its
(trusted) cookie would let the container keylog your whole session and inject synthetic
keystrokes into host windows (arbitrary host command execution — see `docs/security-audit.md`
#5). On an X11-only host, `auto` forwards nothing and prints a warning. To use image paste on
X11 anyway, set `display: x11` explicitly: that's an informed opt-in to the trusted-cookie risk,
and each run reminds you of it. (Untrusted X cookies aren't offered — the X Security extension
would then block the container from reading the clipboard, defeating the point, the same way
`ssh -X` breaks paste where `ssh -Y` works.)

To see what it detected, check the generated `.cc-docker/docker-compose.yml` for a
`WAYLAND_DISPLAY`/`DISPLAY` entry under `environment`. If no display was forwarded (a headless
box, an X11 host under `auto`, or you ran `cc-config` by hand without going through `cc`),
generation prints a warning and skips forwarding — pasting just won't work, nothing else is
affected.

Override with the `display` field in `cc-docker.yml` if needed:

```yaml
display: disabled  # disable forwarding entirely
# display: wayland # force Wayland instead of auto-detecting
# display: x11     # force X11 (forwards a TRUSTED cookie — full input access; trusted projects only)
```

(Not `off`: YAML parses a bare `off` as the boolean `false`, which would fail schema
validation — `disabled` sidesteps that footgun.)

Drag-and-drop of files into the terminal isn't fixed by this: the terminal emulator inserts the
dropped file's absolute *host* path as text, and that path only resolves inside the container if
it happens to fall under one of the configured mounts.

### API key auth (optional)

By default, `claude` inside the container authenticates via OAuth: because the config volume
starts empty and is decoupled from your host `~/.claude`, the first `claude` run in a project
prompts an interactive OAuth login, and the resulting token persists in that project's volume for
later runs (see [The `hostuser` model](#the-hostuser-model)). If you'd rather use a raw Anthropic
API key instead — e.g. for a CI-like box with no interactive login, or a key scoped separately
from your personal account — set `anthropic_api_key_file` in `cc-docker.yml` to a host file
containing just the key:

```yaml
anthropic_api_key_file: ~/.config/cc-docker/anthropic_api_key
```

```bash
mkdir -p ~/.config/cc-docker
printf '%s' 'sk-ant-...' > ~/.config/cc-docker/anthropic_api_key
chmod 600 ~/.config/cc-docker/anthropic_api_key
```

The key is delivered as a real [Docker secret](https://docs.docker.com/compose/how-tos/use-secrets/)
— a file mounted at `/run/secrets/anthropic_api_key` — rather than an environment variable, so it
never appears in the generated `docker-compose.yml`, in `docker inspect`, or in the container's
environment. `run-as-hostuser.sh` reads the file and exports it as `ANTHROPIC_API_KEY` right
before launching `claude`.

This field is optional and off by default: omit it and auth falls back to the per-project OAuth
login described above. When set, it takes precedence for that run; `claude` records the one-time
key approval in `~/.claude.json` (inside the project's config volume), so later runs (with or
without the key) won't need to re-approve it.

### IntelliJ: schema-validated editing

`cc-docker.schema.json` is [JSON Schema draft-07](https://json-schema.org/specification-links.html#draft-7),
which IntelliJ supports natively — no plugin needed. To get autocomplete and inline validation
while editing `cc-docker.yml`:

1. **Settings → Languages & Frameworks → Schemas and DTDs → JSON Schema Mappings**
2. Click **+**, add a mapping:
   - **Schema file**: `toolchain/config/cc-docker.schema.json` (path inside your `cc-docker` checkout)
   - **Schema version**: `JSON Schema version 7`
   - **File path pattern**: `cc-docker.yml`
3. Apply. Any open `.cc-docker/cc-docker.yml` now gets key completion and red squiggles on
   unknown/misspelled keys.

This is a per-developer IDE setting (`.idea/` is gitignored), so each contributor registers it
once locally.

## Developing cc-docker itself

Working on cc-docker means running `./build.sh` (`docker build`), `docker
compose`, and `init-cc.sh` — all of which need Docker access. The stock
`base` (and the assembled project images built on it) deliberately has neither
the `docker` CLI nor access to a daemon, since giving a project container control
of the host's Docker daemon is a real capability, not just another mount.

For this repo specifically, `toolchain/dev/` builds a `cc-dev` image that adds
the `docker` CLI + `docker compose` plugin and talks to the **host's** Docker
daemon over the mounted socket (Docker-out-of-Docker: containers/images built
from inside `cc-dev` are ordinary siblings on the host daemon, not nested/
isolated). It also includes `python3`/`python3-yaml`/`python3-jsonschema` so
you can run `toolchain/config/generate-compose.py` directly, without
rebuilding the `cc-config` image on every edit.

Bootstrap:

```bash
./build.sh                # builds base + all toolchain/* (incl. cc-dev) + all stacks
```

`.cc-docker/` is gitignored (see [Tracking](#configuring-cc-docker-cc-dockeryml)), so a fresh
clone has no config yet. `cc-dev` is a legacy-style prebuilt image (a `toolchain/` image, not a
`stack/*` module), so write `.cc-docker/cc-docker.yml` by hand with `image:`:

```yaml
image: cc-dev
mounts:
  - path: .
docker_socket: true  # required: gives cc-dev the docker CLI/daemon access above
```

Then `cc` generates `.cc-docker/docker-compose.yml` from it and runs it. Add personal
`extra_mounts` entries as needed (e.g. a screenshot tool's temp dir) — they're not required for
cc-dev itself.

### Why cc-dev is restricted to this repo

Mounting the host's Docker socket grants **root-equivalent access to the host
daemon** — a container that can talk to the socket can, among other things,
launch new privileged containers with arbitrary host mounts. That's a much
bigger capability than the filesystem isolation the rest of cc-docker provides,
so `cc-dev` is deliberately locked down two ways:

- **Not a composable module.** `cc-dev` lives in `toolchain/dev/`, not `stack/`,
  so it can't be selected via `modules:` for an ordinary project — you'd have to
  deliberately set `image: cc-dev`. (`build.sh` builds it along with the other
  `toolchain/*` images.)
- **Refuses to run outside this repo.** `cc-dev`'s entrypoint
  (`toolchain/dev/dev-wrapper.sh`) checks for a committed `.cc-docker-dev`
  marker file at the project root before starting, and exits with an error if
  it's missing. Only this repo has that marker, so even a compose file that
  explicitly references `cc-dev` won't start it elsewhere. Copying the marker
  into another project is a deliberate, explicit way to lift the restriction —
  it isn't something that happens by accident.

### Caveat: nested mounts don't path-translate

Docker-out-of-Docker means the **host** daemon resolves every bind-mount
source, not the `cc-dev` container. cc-docker's same-path convention
(`${PWD}:${PWD}`) and build contexts resolve correctly this way. But a `~`
in a mount source is expanded by whichever process reads the compose file —
inside `cc-dev`, `~` is `/home/hostuser`, which the host daemon can't resolve.
The config dir is now a **named volume** (`cc-claude-<slug>`), which the host
daemon resolves fine, so that particular breakage is gone; but any remaining
home-relative bind source in a nested compose is still resolved against the
wrong home. Use `cc-dev` for
building, editing, and non-interactive smoke tests; do full interactive runs
from the host.

### Telling cc-dev's containers/images apart from native ones

Since `cc-dev` shares the host daemon, `docker ps`/`docker images` on the host
mixes containers/images it creates in with ones started natively. `cc-dev`
shadows `/usr/bin/docker` with a shim (`toolchain/dev/docker-shim.sh`) that
tags everything it creates:

- `docker run`/`docker create` get a `cc-dev-<subcommand>-<id>` name (unless
  you passed your own `--name`) plus a `cc-dev=1` label.
- `docker build` gets the `cc-dev=1` label (the image keeps its own `-t` tag).
- `docker compose` runs get named via `COMPOSE_PROJECT_NAME=cc-dev` (set as an
  image `ENV`), so compose containers come out `cc-dev-<service>-<n>`.

Discriminate on the host with:

```bash
docker ps -a --filter name=^cc-dev       # anything named with the cc-dev prefix
docker ps -a --filter label=cc-dev        # run/create/compose containers
docker images --filter label=cc-dev       # images built from inside cc-dev
```

Everything else (`ps`, `images`, `inspect`, ...) passes through the shim
unchanged.

`cc-dev`'s entrypoint (`toolchain/dev/dev-wrapper.sh`) also stops any
still-running `cc-dev=1` containers when the session ends — normal exit or
`docker stop`/`compose down` on the `cc-dev` container itself — so a run/create
you forgot to clean up doesn't linger on the host daemon. This doesn't cover
`docker compose` containers started from inside `cc-dev`, since those are
tracked by their own `com.docker.compose.project=cc-dev` label rather than
`cc-dev=1`.

## Legacy images

The pre-modular implementation is preserved under `legacy/` and still works: the old
`FROM cc-*` image tree (`cc-base`, `cc-node20`, `cc-vue3`, `cc-zulu21`, `cc-full`), the
graph-based `legacy/build.sh`, and its Makefile + completions.

```bash
legacy/build.sh            # build every legacy image (topo-sort over legacy/images/)
legacy/build.sh zulu21     # build cc-zulu21 and its dependencies only
```

To run a project on a prebuilt legacy image, set `image:` in `cc-docker.yml` instead of
`modules:`:

```yaml
image: cc-zulu21
mounts:
  - path: .
```

New projects should prefer the modular `modules:` path; `legacy/` exists so existing
setups keep working through the transition.

### Migrating a pre-modular project

`migrate-cc` (defined in `init-cc.sh` alongside `init-cc`/`cc`) upgrades an existing project
to the modular engine. Run it from anywhere in the project — it walks up to find `.cc-docker/`
like `cc` does, or takes an explicit project root: `migrate-cc /path/to/project`. It handles both
legacy shapes:

- **`cc-docker.yml` in `image:` mode** — rewrites the `image:` line to an equivalent `modules:`
  line, leaving every other field untouched.
- **A hand-written `docker-compose.yml` with no `cc-docker.yml`** (the oldest raw setup) —
  reverse-engineers a `cc-docker.yml` from it (image, git identity from `.env` or the
  `environment:` block, `docker_socket`, `anthropic_api_key_file`), and lets `cc` regenerate the
  compose file on its next run. This migration is now **required** for such projects: `cc` no
  longer runs a bare hand-written compose (it left the sandbox-defining compose file writable
  from inside the container — `docs/security-audit.md` #3).

Legacy image → module mapping:

| Legacy image | Modules |
|---|---|
| `cc-base` | *(none — base only)* |
| `cc-node20` | `node` |
| `cc-vue3` | `node` |
| `cc-zulu21` | `zulu` |
| `cc-pdf2md` | `pdf2md` |
| `cc-full` | `node python3` *(Ruby + extra CLI tooling have no module — a note is printed)* |

An unknown image (e.g. `cc-dev` or a custom one) prompts for a module list, or is kept as-is in
`image:` mode when left blank.

Before touching disk, migrate-cc prints the exact `cc-docker.yml` it proposes to write, the backup it
will take, and any advisories, then asks for confirmation — answer `n` (the default) and nothing is
written. On approval it backs up anything it overwrites to `<file>.bak`. migrate-cc never builds —
afterwards run `cc --build` (modular) or `cc` (a kept `image:`).

When reverse-engineering a raw `docker-compose.yml`, migrate-cc parses the `cc` service's `volumes:`
list (both short `src:tgt` and long `type: bind` forms) and sorts each entry: project binds (same
host path in and out, at or under the compose's `working_dir`) become `mounts:` entries — `path: .`
for the whole root, or a relative `path:` for a subdirectory; the host Docker socket becomes
`docker_socket: true`; mounts cc-config now re-adds itself (any legacy `~/.claude*` host binds — it
provides the config volume instead — and the display sockets) are dropped; and anything else (custom
host paths, caches, named volumes) is carried into `extra_mounts:` verbatim. A wholly read-only project maps to `readonly: true`; a mix of read-only
and read-write project mounts can't be expressed by the all-or-nothing `readonly:` flag, so migrate-cc
leaves them read-write and warns.

## Configuration

Claude Code permissions are configured in `.claude/settings.local.json`. Edit this file to adjust which tools and operations Claude is allowed to perform inside the container.

### Git identity (optional)

By default, the container has no git user identity. Set it in `cc-docker.yml` via the `git:`
block:

```yaml
git:
  name: Your Name
  email: you@example.com
```

`.cc-docker/` is gitignored (see
[Tracking](#configuring-cc-docker-cc-dockeryml)), so this is per-developer and never committed.
The values are applied via `git config --global` at container startup
(`bootstrap/run-as-hostuser.sh`).
