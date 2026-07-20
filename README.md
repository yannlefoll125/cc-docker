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

Interactive setup for a new project. Add two lines to your `~/.bashrc`:

```bash
export CC_DOCKER_DIR=/path/to/cc-docker
source "$CC_DOCKER_DIR/init-cc.sh"
```

Then, from any project directory, run:

```bash
init-cc
```

It will prompt for:

- **Project root** (defaults to the current directory)
- **Image** — numbered menu, auto-discovered from the `images/` directory
- **Git user name and email** (defaults to your global `git config` values)
- **Whether to add `.cc-docker/` to `.gitignore`**

When done, `.cc-docker/docker-compose.yml` and `.cc-docker/.env` are written to the chosen project root, ready to use.

### Shell completion

Add one line to your `~/.bashrc` (use the actual path where you cloned this repo):

```bash
source /path/to/cc-docker/completions/build.bash
```

This gives `./build.sh <TAB>` completion against the live list of images. The image list is read at completion time, so adding or removing an image directory is reflected immediately — no re-sourcing needed.

## Project Structure

```
.
├── .cc-docker/
│   ├── docker-compose.yml       # Compose service definition
│   └── .env.example             # Template for optional git identity config
└── images/
    ├── base/
    │   ├── cc-wrapper.sh        # Entrypoint (root phase): matches host UID/GID, re-execs via gosu
    │   ├── run-as-hostuser.sh   # User phase: applies git config, clears terminal, runs claude
    │   └── Dockerfile           # Debian Bookworm slim + Claude Code CLI (cc-base)
    ├── node20/
    │   └── Dockerfile           # cc-base + Node.js 20 (cc-node20)
    ├── vue3/
    │   └── Dockerfile           # cc-node20 + Yarn via corepack (cc-vue3)
    └── zulu21/
        └── Dockerfile           # cc-base + Azul Zulu JDK 21 (cc-zulu21)
```

## Usage

**1. Build the images:**

```bash
./build.sh
```

**2. Run Claude Code:**

```bash
docker-compose -f .cc-docker/docker-compose.yml run cc
```

Tip: set `alias cc=docker compose -f .cc-docker/docker-compose.yml run` in your shell (e.g. in `.bashrc`) to be able to run `cc` easily from the project root.

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

The quickest way is `init-cc` (see [Scripts](#scripts) above). If you prefer to do it manually, copy the whole `.cc-docker/` directory into your project root and adjust as needed:

```bash
cp -r /path/to/cc-docker/.cc-docker /your/project/
cp /your/project/.cc-docker/.env.example /your/project/.cc-docker/.env
# edit .cc-docker/.env with your git identity
```

The compose file:

```yaml
services:
  cc:
    image: cc-base  # or cc-vue3 for Vue 3 projects, or any other extension of cc-base
    stdin_open: true
    tty: true
    environment:
      GIT_USER_NAME: ${GIT_USER_NAME:-}
      GIT_USER_EMAIL: ${GIT_USER_EMAIL:-}
      PROJECT_DIR: ${PWD}
    working_dir: ${PWD}
    volumes:
      - ${PWD}:${PWD}
      - ~/.claude:/home/hostuser/.claude
      - ~/.claude.json:/home/hostuser/.claude.json
```

Then from your project root:

```bash
# Build cc-base first (only needed once), from the cc-docker checkout
/path/to/cc-docker/build.sh

# Start Claude Code in your project
docker-compose -f .cc-docker/docker-compose.yml run cc
```

The volume mounts are the key pieces:

| Mount / setting | Purpose |
|-----------------|---------|
| `${PWD}:${PWD}` + `working_dir` + `PROJECT_DIR` | Mounts your project at its host path inside the container. Using the same path on both sides means Claude Code's per-project state bucket (keyed by cwd) is unique per project on the host — sessions from different repos stay separate in `~/.claude/projects/`. Also the source of the host UID/GID used to create `hostuser`. |
| `~/.claude:/home/hostuser/.claude` | Persists Claude credentials and settings; mounted at the `hostuser` home path so ownership matches your host login |
| `~/.claude.json:/home/hostuser/.claude.json` | Persists Claude's top-level auth/config state; same ownership rationale |

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
isolated). It also includes `python3`/`python3-yaml` so you can run
`toolchain/config/generate-compose.py` directly, without rebuilding the
`cc-config` image on every edit.

Bootstrap:

```bash
./build.sh dev            # builds cc-base, then cc-dev, on the host
docker compose -f .cc-docker/docker-compose.yml run cc
```

This repo's own `.cc-docker/docker-compose.yml` is already wired for it
(`image: cc-dev` + a `/var/run/docker.sock:/var/run/docker.sock` mount).

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

## Configuration

Claude Code permissions are configured in `.claude/settings.local.json`. Edit this file to adjust which tools and operations Claude is allowed to perform inside the container.

### Git identity (optional)

By default, the container has no git user identity. To set one, copy `.cc-docker/.env.example` to `.cc-docker/.env` and fill in your details:

```bash
cp .cc-docker/.env.example .cc-docker/.env
```

```ini
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@example.com
```

`.cc-docker/.env` is gitignored, so each developer maintains their own without affecting the shared config. The values are picked up by `.cc-docker/docker-compose.yml` and applied via `git config --global` at container startup.
