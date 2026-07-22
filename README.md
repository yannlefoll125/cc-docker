# Claude Code Docker Environment

Run Anthropic's [Claude Code](https://github.com/anthropics/claude-code) CLI in an isolated Docker container, one container per project.

## What this is (and isn't) for

The goal is **project isolation**, not network isolation from Anthropic.

Claude Code is a capable agent with broad filesystem and shell access. Run directly on a developer laptop, it can in principle read anything the logged-in user can read: other repositories, SSH keys, browser profiles, shell history, `~/.aws`, other projects' `.env` files, and so on. Even with good intentions, a single misinterpreted prompt — or a prompt-injection payload hidden in a dependency, issue, or web page — can cause the agent to pull context from one project into another.

Running Claude inside a per-project container fixes that. The container only sees:

- The current project directory (at its host path)
- `/home/hostuser/.claude` and `/home/hostuser/.claude.json` — your Claude auth/settings

It does **not** see other repos on your machine, your home directory, SSH keys, or any sibling project. A prompt injection inside project A cannot exfiltrate code from project B, because project B isn't mounted.

What this does **not** do:

- It does not prevent code from being sent to Anthropic's API. That is inherent to using Claude Code — your prompts and file contents are sent to Anthropic as part of normal operation. If you don't want code leaving your machine at all, don't run Claude Code on it.
- It does not sandbox network access. The container can reach the internet like any other process.

Think of it as a seatbelt against *cross-project* leakage and agent-mediated accidents on your own filesystem, not as a confidentiality boundary against Anthropic.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Docker Compose](https://docs.docker.com/compose/install/)

## Scripts

### `build.sh`

Builds the `cc-*` Docker images in dependency order.

```bash
./build.sh              # build every discovered image
./build.sh vue3         # build cc-vue3 and its transitive dependencies only
```

Images are auto-discovered from `images/*/Dockerfile`. Dependencies are inferred by scanning each Dockerfile for `FROM cc-<name>` and `COPY --from=cc-<name>` directives, then a topological sort ensures each image is built after anything it depends on. Dependency cycles are detected and reported as errors.

Adding a new image is just: create `images/<name>/Dockerfile` — no edits to `build.sh` required.

### `init-cc.sh`

Interactive setup for a new project. Source it into your shell first — either run `make install`
from this repo (checks whether it's already sourced in `~/.bashrc` and appends it if not, no-op
if it's already there), or add the two lines yourself:

```bash
export CC_DOCKER_DIR=/path/to/cc-docker
source "$CC_DOCKER_DIR/init-cc.sh"
```

Sourcing this file defines two shell functions: `init-cc` (setup, below) and `cc` (the launcher,
see [`cc` (the launcher)](#cc-the-launcher)).

Then, from any project directory, run:

```bash
init-cc
```

It will prompt for:

- **Project root** (defaults to the current directory)
- **Image** — numbered menu, auto-discovered from the `images/` directory
- **Git user name and email** (defaults to your global `git config` values)
- **Configuration type** — *cc-docker native config (`cc-docker.yml`)*, preselected, or *raw
  `docker-compose.yml`*
- **Whether to add `.cc-docker/` to `.gitignore`**

Native writes only `.cc-docker/cc-docker.yml` — the `cc` launcher generates
`docker-compose.yml` from it on demand (see [Configuring cc-docker](#configuring-cc-docker-cc-dockeryml)).
Raw writes `.cc-docker/docker-compose.yml` + `.cc-docker/.env` directly, same as before — edit
those by hand as needed.

When done, run Claude Code with `cc` from the project root (or any subdirectory).

### `cc` (the launcher)

Defined by `init-cc.sh` alongside `init-cc`. On each invocation it:

1. Walks up from the current directory to find `.cc-docker/`, so it works from any subdirectory
   of the project.
2. If `.cc-docker/cc-docker.yml` exists, regenerates `.cc-docker/docker-compose.yml` from it via
   the `cc-config` image, every time — generation only takes a few ms, so there's no staleness
   check to get wrong.
3. Otherwise, if a hand-written `.cc-docker/docker-compose.yml` exists, uses it directly — no
   regeneration. This is what keeps existing raw-compose projects working unchanged.
4. Runs `docker compose -f .cc-docker/docker-compose.yml run --rm cc "$@"`.

So with a native `cc-docker.yml`, editing it and re-running `cc` always picks up the change —
no manual regenerate step needed.

### Shell completion

Add one line to your `~/.bashrc` (use the actual path where you cloned this repo):

```bash
source /path/to/cc-docker/completions/build.bash
```

This gives `./build.sh <TAB>` completion against the live list of images. The image list is read at completion time, so adding or removing an image directory is reflected immediately — no re-sourcing needed.

## Project Structure

```
.
├── .cc-docker-dev                # committed marker; see below
├── .cc-docker/                   # created by init-cc per project, gitignored (personal, not committed)
│   ├── cc-docker.yml             # native config (source of truth), or:
│   ├── docker-compose.yml        # ...generated from it, or hand-written (raw)
│   └── .env                      # raw only: git identity
├── images/
│   ├── base/
│   │   ├── cc-wrapper.sh        # Entrypoint (root phase): matches host UID/GID, re-execs via gosu
│   │   ├── run-as-hostuser.sh   # User phase: applies git config, clears terminal, runs claude
│   │   └── Dockerfile           # Debian Bookworm slim + Claude Code CLI (cc-base)
│   ├── node20/
│   │   └── Dockerfile           # cc-base + Node.js 20 (cc-node20)
│   ├── vue3/
│   │   └── Dockerfile           # cc-node20 + Yarn via corepack (cc-vue3)
│   └── zulu21/
│       └── Dockerfile           # cc-base + Azul Zulu JDK 21 (cc-zulu21)
└── toolchain/                    # cc-docker's own tooling images, not offered by init-cc's menu
    ├── config/                   # cc-config: generates docker-compose.yml from cc-docker.yml
    └── dev/                      # cc-dev: this repo's own dev environment (see below)
```

`.cc-docker-dev` (a file at the repo root, not inside `.cc-docker/`) is a marker committed to this
repo only — it's what lets `cc-dev` refuse to run in any other project (see
[Why cc-dev is restricted to this repo](#why-cc-dev-is-restricted-to-this-repo)).

## Usage

**1. Build the images:**

```bash
./build.sh
```

**2. Set up your project** (see [`init-cc.sh`](#init-ccsh) — prompts for image, git identity, and
config type):

```bash
init-cc
```

**3. Run Claude Code:**

```bash
cc
```

`cc` works from the project root or any subdirectory (see [`cc` (the launcher)](#cc-the-launcher)).
This mounts your project files, Claude credentials, and auth state into the container. See [The cc-base environment](#the-cc-base-environment) for how ownership and credentials work.

## Images

| Image | Description |
|-------|-------------|
| `cc-base` | Debian Bookworm slim + Claude Code CLI (installed via official install script). General-purpose starting point. |
| `cc-node20` | Extends `cc-base` with Node.js 20 from NodeSource. |
| `cc-vue3` | Extends `cc-node20` with Yarn (via corepack). Use for Vue 3 projects. |
| `cc-zulu21` | Extends `cc-base` with Azul Zulu JDK 21. Use for Java projects. |

### Dependency tree

`build.sh` derives this chain from `FROM`/`COPY --from` directives automatically, so new images slot in without any manual configuration.

```
cc-base
├── cc-node20
│   └── cc-vue3
└── cc-zulu21
```

## The cc-base environment

`cc-base` is a Debian Bookworm slim image with the Claude Code CLI pre-installed. It is designed to be a general-purpose starting point that other images (like `cc-vue3`) extend by adding project-specific tooling.

### The `hostuser` model

The defining feature of `cc-base` is that it runs Claude Code as a user whose UID and GID match yours on the host. At startup, the entrypoint reads the UID/GID from the project directory (via the `PROJECT_DIR` environment variable):

```bash
HOST_UID=$(stat -c "%u" "$PROJECT_DIR")
HOST_GID=$(stat -c "%g" "$PROJECT_DIR")
```

It then creates a `hostgroup`/`hostuser` pair with those IDs and drops privileges to that user via [gosu](https://packages.debian.org/bookworm/gosu) before running `claude`. The result: any file Claude creates inside the project directory is owned by you on the host — no `root`-owned artifacts, no `chown` cleanup after the container exits.

You don't have to bind-mount the whole project — mounting only selected subdirectories (to limit what Claude can see) is a supported setup too. If `$PROJECT_DIR` itself isn't bind-mounted, Docker creates it inside the container owned by `root`, so the entrypoint falls back to the always-mounted `~/.claude`/`~/.claude.json` mounts to recover your real host UID/GID.

The same ownership logic applies to the config mounts. `~/.claude` and `~/.claude.json` are mounted into `/home/hostuser/.claude` and `/home/hostuser/.claude.json`, so credentials and settings are read and written with your UID — they stay in sync with your host login without any permission tricks.

### The two-phase entrypoint

Startup is split across two scripts because privilege drop requires root:

| Phase | Script | Runs as | What it does |
|-------|--------|---------|--------------|
| 1 | `cc-wrapper.sh` | root | Reads host UID/GID from `$PROJECT_DIR`, creates `hostgroup`/`hostuser`, `chown`s the home dir, re-execs via `gosu hostuser` |
| 2 | `run-as-hostuser.sh` | hostuser | Applies `GIT_USER_NAME`/`GIT_USER_EMAIL` if set, marks `$PROJECT_DIR` as a git safe directory, clears the terminal, runs `claude` |

### Extending cc-base

When building a child image, only add tooling — do not create a fixed user or set a `USER` directive. The UID match happens at runtime from the `$PROJECT_DIR` mount, so baking in a user would break the ownership alignment. `cc-node20` and `cc-vue3` are canonical examples: `cc-node20` adds Node.js 20 on top of `cc-base`, and `cc-vue3` layers Yarn via corepack on top of `cc-node20` — neither touches the entrypoint.

---

To use the Vue 3 image, update `docker-compose.yml` to reference `cc-vue3`, or run the container directly:

```bash
docker run -it --rm \
  -v "$PWD":"$PWD" \
  -w "$PWD" \
  -e PROJECT_DIR="$PWD" \
  -v ~/.claude:/home/hostuser/.claude \
  -v ~/.claude.json:/home/hostuser/.claude.json \
  cc-vue3
```

## Using cc-claude in another project

The quickest way is `init-cc` (see [Scripts](#scripts) above) — it prompts for image, git
identity, and config type, and writes native config by default. If you prefer to do it manually,
create `.cc-docker/cc-docker.yml` in your project root yourself:

```yaml
image: cc-base  # or cc-vue3 for Vue 3 projects, or any other extension of cc-base
git:
  name: Your Name
  email: you@example.com
mounts:
  - path: .
```

Then from your project root:

```bash
# Build cc-base first (only needed once), from the cc-docker checkout
/path/to/cc-docker/build.sh

# Start Claude Code in your project
cc
```

`cc` generates `.cc-docker/docker-compose.yml` from `cc-docker.yml` and runs it (see
[Configuring cc-docker](#configuring-cc-docker-cc-dockeryml) for the full schema). The resulting
compose file's volume mounts are the key pieces:

| Mount / setting | Purpose |
|-----------------|---------|
| `${PWD}:${PWD}` + `working_dir` + `PROJECT_DIR` | Mounts your project at its host path inside the container. Using the same path on both sides means Claude Code's per-project state bucket (keyed by cwd) is unique per project on the host — sessions from different repos stay separate in `~/.claude/projects/`. Also the source of the host UID/GID used to create `hostuser`. |
| `~/.claude:/home/hostuser/.claude` | Persists Claude credentials and settings; mounted at the `hostuser` home path so ownership matches your host login |
| `~/.claude.json:/home/hostuser/.claude.json` | Persists Claude's top-level auth/config state; same ownership rationale |
| `.cc-docker/.claude:$PROJECT_DIR/.claude` | Overlays the project-level Claude context (settings, plans, todos) into the gitignored `.cc-docker/.claude/`, so Claude's project-level writes never land in the committed/shared project tree. Scaffolded by `cc` on first run (`.cc-docker/.claude/settings.json`), and `cc` also adds `.claude/` to your project's `.gitignore` so the overlay doesn't show up as untracked inside the container. |

## Configuring cc-docker (`cc-docker.yml`)

`.cc-docker/docker-compose.yml` is either hand-written (the *raw* option in `init-cc`) or a
generated, disposable artifact regenerated on every `cc` invocation from a shorter declarative
config, `.cc-docker/cc-docker.yml` (the *native* option, preselected). The generation is done by
`cc-config` (`toolchain/config/`) — a small tool that reads `cc-docker.yml` and writes
`docker-compose.yml`. When native, don't hand-edit `docker-compose.yml` — edit `cc-docker.yml`
instead, `cc` regenerates it for you.

**Tracking:** the whole `.cc-docker/` directory is gitignored. Using cc-docker is currently
treated as a personal choice — nothing about your setup (image, mounts, git identity, the
generated compose file) is committed, so nothing project-specific ends up in git history. If a
future need arises to let a project *share* a config across contributors, the clean way to do
that is splitting `.cc-docker/` into a tracked subdir (shared config) and a gitignored one
(per-developer overrides + the generated artifact) — not done today, but worth knowing the
current all-gitignored setup is a deliberate starting point, not an oversight.

`cc-docker.yml` fields:

| Field | Type | Required | Description |
|-------|------|----------|--------------|
| `image` | string | yes | Docker image to run as the `cc` service, e.g. `cc-node20`. |
| `git.name` / `git.email` | string | no | Git identity, exposed to the container as `GIT_USER_NAME` / `GIT_USER_EMAIL`. |
| `env` | map | no | Extra environment variables merged into the `cc` service. |
| `readonly` | boolean | no | If true, all mounts declared in `mounts` are read-only. Defaults to `false`. |
| `mounts` | list | no | Project paths to bind-mount. Each entry is `{path, exclude}`: `path` (required) is relative to the project root — use `"."` for the whole project; `exclude` is a list of glob patterns (relative to `path`) to shadow out with a `tmpfs` (directories) or a read-only `/dev/null` bind (files). |
| `extra_mounts` | list | no | Raw docker compose volume entries, appended verbatim — no validation. |
| `display` | string | no | `auto` (default) \| `wayland` \| `x11` \| `disabled` — forwards the host clipboard display socket so `claude` can paste images. See [Clipboard image paste](#clipboard-image-paste-x11wayland). |

Example:

```yaml
image: cc-node20
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
(`toolchain/config/cc-docker.schema.json`) before generating anything — an unknown key, a missing
`image`, or a `mounts` entry without a `path` all fail with a readable error instead of silently
producing a broken compose file.

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

`cc-base` ships `wl-clipboard` and `xclip`, so `claude` can paste images from the host clipboard.
Getting the clipboard's *contents* across the container boundary needs the host's display socket
forwarded in — a container has no access to the host's X11/Wayland session by default. `cc`
handles this automatically: it reads `$WAYLAND_DISPLAY`/`$DISPLAY` etc. from your host shell and
forwards them to `cc-config`, which wires up the right mount and env vars for you. Nothing to
configure — `display: auto` is the default.

To see what it detected, check the generated `.cc-docker/docker-compose.yml` for a
`WAYLAND_DISPLAY`/`DISPLAY` entry under `environment`. If neither your host's Wayland nor X11
session is set (e.g. a headless box, or you ran `cc-config` by hand without going through `cc`),
generation prints a warning and skips forwarding — pasting just won't work, nothing else is
affected.

Override with the `display` field in `cc-docker.yml` if needed:

```yaml
display: disabled  # disable forwarding entirely
# display: wayland # force Wayland instead of auto-detecting
# display: x11     # force X11 instead of auto-detecting
```

(Not `off`: YAML parses a bare `off` as the boolean `false`, which would fail schema
validation — `disabled` sidesteps that footgun.)

Drag-and-drop of files into the terminal isn't fixed by this: the terminal emulator inserts the
dropped file's absolute *host* path as text, and that path only resolves inside the container if
it happens to fall under one of the configured mounts.

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
`cc-base` (and every other image in `images/`) deliberately has neither the
`docker` CLI nor access to a daemon, since giving a project container control
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
./build.sh dev            # builds cc-base, then cc-dev, on the host
```

`.cc-docker/` is gitignored (see [Tracking](#configuring-cc-docker-cc-dockeryml)), so a fresh
clone has no config yet. `init-cc`'s image menu won't offer `cc-dev` (it lives in `toolchain/`,
not `images/`), so write `.cc-docker/cc-docker.yml` by hand instead:

```yaml
image: cc-dev
mounts:
  - path: .
extra_mounts:
  - /var/run/docker.sock:/var/run/docker.sock  # required: gives cc-dev the docker CLI/daemon access above
```

Then `cc` generates `.cc-docker/docker-compose.yml` from it and runs it. Add further personal
`extra_mounts` entries as needed (e.g. a screenshot tool's temp dir) — they're not required for
cc-dev itself.

### Why cc-dev is restricted to this repo

Mounting the host's Docker socket grants **root-equivalent access to the host
daemon** — a container that can talk to the socket can, among other things,
launch new privileged containers with arbitrary host mounts. That's a much
bigger capability than the filesystem isolation the rest of cc-docker provides,
so `cc-dev` is deliberately locked down two ways:

- **Not offered as a choice.** `cc-dev` lives in `toolchain/dev/`, not
  `images/`. `init-cc`'s image menu only scans `images/*`, so `cc-dev` never
  shows up as something you'd pick for an ordinary project. (`build.sh` still
  builds it — it scans both `images/*` and `toolchain/*`.)
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
So launching a full nested interactive `cc` session (which mounts
`~/.claude`) from inside `cc-dev` won't work correctly. Use `cc-dev` for
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

## Configuration

Claude Code permissions are configured in `.claude/settings.local.json`. Edit this file to adjust which tools and operations Claude is allowed to perform inside the container.

### Git identity (optional)

By default, the container has no git user identity. With a native `cc-docker.yml` (`init-cc`'s
default), set it via the `git:` block:

```yaml
git:
  name: Your Name
  email: you@example.com
```

With a raw `docker-compose.yml` (`init-cc`'s alternative choice), set it in `.cc-docker/.env`
instead:

```ini
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@example.com
```

Either way `.cc-docker/` is gitignored (see
[Tracking](#configuring-cc-docker-cc-dockeryml)), so this is per-developer and never committed.
The values are applied via `git config --global` at container startup
(`images/base/run-as-hostuser.sh`).
