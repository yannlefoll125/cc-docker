# Security audit — sandbox escape review

**Date:** 2026-07-26
**Scope:** ways the in-container `claude` can reach host code execution, or read data
outside its project, given the threat model stated in `README.md:5-24`
(protection against *cross-project* leakage and agent-mediated accidents; the adversary
is a prompt-injected or confused agent inside the container).
**Method:** code review of the launcher/generator/entrypoint chain, plus empirical
verification from inside a live `cc-dev` container (which has the docker socket mounted).
Claims marked *verified* were tested; no escape was actually carried out and no
third-party data was read or exfiltrated.

Nothing here is a container-runtime breakout — no privileged flags, no root inside the
container, the `gosu` drop is clean. Every escape found is a **data-flow escape**: the
agent writes something the host later executes, or reads something the design assumed
wasn't reachable.

Findings #1–#4 are each independently sufficient for full host compromise from a single
prompt injection.

---

## Critical

### 1. `~/.claude` is mounted read-write → persistent host code execution

`toolchain/config/generate-compose.py:236-243` mounts the host's `~/.claude` and
`~/.claude.json` with no `read_only` flag, unconditionally, and — see #6 — unaffected by
`readonly: true`.

*Verified:* writable from inside the container. That directory is Claude Code's
**user-scope execution context on the host**:

| Path | Executed by |
|---|---|
| `~/.claude/settings.json` → `hooks` (`SessionStart`, `PreToolUse`, …) | host `claude`, arbitrary shell, no prompt |
| `~/.claude/commands/*`, `~/.claude/plugins/*`, agents/skills | host `claude` |
| `~/.claude/shell-snapshots/*.sh` | sourced by the host Bash tool |

The container writes a hook; the next time the user runs `claude` natively *anywhere* on
the machine, it executes as them, outside any container. A full, durable escape requiring
no misconfiguration.

**Fix:** ro-bind the execution-relevant entries over the rw mount (the same
`/dev/null`-bind / tmpfs technique `exclude` already uses): `settings.json`, `commands/`,
`plugins/`, `hooks/`, `shell-snapshots/`. Only `projects/<this-project>`, `todos/`,
`statsig/`, `.credentials.json` genuinely need write access.

### 2. Every other project's transcripts are readable

`README.md:17` states: *"A prompt injection inside project A cannot exfiltrate code from
project B, because project B isn't mounted."* That does not hold.
`~/.claude/projects/` is mounted and contains full session transcripts — file contents,
diffs, pasted secrets — for **every** project.

*Verified:* four unrelated projects' transcript directories are visible from inside this
container. Also exposed: `~/.claude/history.jsonl` (all prompts, all projects) and
`~/.claude.json` (full project list, MCP server configs, which commonly hold tokens).
Network egress is unrestricted by design (`README.md:21`), so exfiltration is one `curl`.

**Fix:** mask `projects/`, `history.jsonl`, and `.claude.json`'s cross-project fields;
bind only `projects/<current-slug>` through. This is the highest-value fix relative to
the project's stated purpose.

### 3. The agent can rewrite the config that defines the *next* session's sandbox

With the default `mounts: - path: .` (what `init-cc` writes, `init-cc.sh:90-92`) the
project root is rw, so `.cc-docker/cc-docker.yml` is writable — *verified*.
`generate-compose.py:261-270` ro-binds that file **only when the root is not covered**,
i.e. only in the case where it wouldn't have been writable anyway. There is effectively
no protection.

The `cc` launcher regenerates compose from that file on every launch
(`init-cc.sh:142-183`), so the agent can pre-authorize its own escape for the next run:

```yaml
extra_mounts: ["/:/hostroot"]        # verbatim, unvalidated — schema:76-82
docker_socket: true                  # root-equivalent on the host daemon
permission_mode: bypassPermissions
env: {NODE_OPTIONS: "--require /tmp/p.js"}
```

In legacy mode (a project with only a hand-written `docker-compose.yml`,
`init-cc.sh:216-222`) it is more direct still: that file is used verbatim and is equally
writable → `privileged: true`, `user: root`, `pid: host`.

**Fix:** always ro-bind `cc-docker.yml` and `docker-compose.yml` over the project mount
(a ro bind on top of an rw parent works), or auto-exclude `.cc-docker/` from the project
mount.

### 4. `mounts[].path` is not constrained to the project

`generate-compose.py:92-100` builds the host path with
`os.path.join(project_dir, rel_path)` and the container-side existence check with
`(Path("/project") / rel_path).resolve()`. Both escape on absolute or `..` paths —
*verified*:

```
'/etc'      -> container /etc   | host /etc
'../../..'  -> container /      | host /
```

`/etc` "exists" inside the cc-config container, so the guard passes, and the host root
gets bind-mounted rw at its own path. The schema constrains `path` only as
`"type": "string"` (`toolchain/config/cc-docker.schema.json:62-65`). A malicious repo
shipping a committed `.cc-docker/cc-docker.yml`, or #3, turns this into a
whole-filesystem mount with no visible warning.

**Fix:** reject absolute paths; require the normalized host path to stay under
`project_dir` and the resolved container path under `/project`.

---

## High

### 5. `display: auto` (the default) hands the container the host X11 socket and cookie

`generate-compose.py:183-187` mounts `/tmp/.X11-unix` and `$XAUTHORITY`. X11 has no
inter-client isolation — with a trusted cookie a client can read the clipboard, capture
any window, keylog the entire session, and **inject synthetic keystrokes via XTEST into a
host terminal**, which is arbitrary host command execution as the user. `xclip` and
`wl-clipboard` ship in `base/Dockerfile:6-14`.

*Verified:* `xclip -o -selection clipboard` succeeds from inside the container (exit
status only was checked; contents were not read). This is on by default for every X11
host, in exchange for image paste.

**Fix:** default `display: disabled`; when X11 is requested, generate an *untrusted*
cookie (`xauth generate … untrusted`) rather than forwarding the trusted one. Wayland is
materially safer (no global input capture) and can stay on `auto`.

### 6. `readonly: true` gives a false sense of a read-only sandbox

It applies only to the `mounts` list (`generate-compose.py:110`). The `~/.claude` mounts
(`:236-243`), the `.claude` overlay (`read_only: False`, `:253-260`) and `extra_mounts`
(`:272-273`) all remain writable — so #1 works unchanged in a "read-only" sandbox.

### 7. Host execution via write-back into the project tree

Inherent to mounting the project rw, but worth naming because several targets are
executed by the *host* with no prompt. *Verified writable:* `.git/hooks/` (pre-commit,
post-checkout, …) and `.git/config` (`core.fsmonitor` runs on nearly every git command;
`core.sshCommand`). Same class: `.envrc`, `.vscode/tasks.json` with
`runOptions.runOn: folderOpen`, `Makefile`, npm lifecycle scripts.

**Fix:** cheap partial mitigation — tmpfs-mask `.git/hooks` and ro-bind `.git/config` by
default. The container almost never needs either.

### 8. Self-hosting is unbounded

When the project *is* cc-docker, the container has rw on `init-cc.sh`, `build.sh` and
`bootstrap/*.sh` — *verified*. `init-cc.sh` is sourced from the host `.bashrc` and
re-sourced on every `cc` / `init-cc` call (`init-cc.sh:5-9`, `:121-125`), so writing it is
immediate host shell RCE. `bootstrap/cc-wrapper.sh` is baked into *every* project's image,
so it is a cross-project compromise too. Warrants an explicit warning in the "Developing
cc-docker itself" section.

---

## Medium / Low

- **The `.cc-docker-dev` marker guard is a speed bump, not a lockdown.**
  `README.md:470-478` claims "even a compose file that explicitly references `cc-dev`
  won't start it elsewhere." The check lives in the entrypoint
  (`toolchain/dev/dev-wrapper.sh:11-15`) — `entrypoint: /cc-wrapper.sh` in compose, or
  `docker run --entrypoint`, skips it entirely. It stops accidents, not intent. Soften
  the wording; the real gate is `docker_socket`.
- **`modules[]` names are unvalidated** (`cc-docker.schema.json:16-20`). They flow into
  image tags (`generate-compose.py:220`) and, via the sidecar, into `stack/$name` paths in
  `build.sh:29-34`. Traversal names are stopped only incidentally, by cc-assemble running
  before `build.sh` and dying on the missing `module.yml`. Add
  `"pattern": "^[a-z0-9][a-z0-9._-]*$"`.
- **No container hardening in the generated compose**: no
  `security_opt: [no-new-privileges:true]`, no `cap_drop: [ALL]`, no pid/memory limits.
  Free defense-in-depth given the agent already runs unprivileged.
- **`exclude` globs are non-recursive** — `exclude: [.env]` masks `./.env` but not
  `sub/.env` (*verified*). Users masking secrets get less than they expect; document
  `**/` and consider defaulting to recursive matching.
- **`bootstrap/run-as-hostuser.sh:3` dumps the full environment** at startup — including
  any `env:` secrets — into the terminal and thus into the transcript, which per #2 is
  cross-project readable. (The API key itself is correctly exported *after* the dump.)
- **Host-side lock path** (`init-cc.sh:209-214`) falls back to `/tmp/cc-docker/locks`; on
  a multi-user host another local user can pre-create `/tmp/cc-docker` as a symlink and
  get the victim's shell to create/truncate an arbitrary file via `9>"$lock_file"`. Not
  container-reachable; use a `$HOME`-based dir.
- **Unpinned supply chain**: `base/Dockerfile:18` is `curl -fsSL … | bash`, and
  `debian:bookworm-slim` / the Docker apt repo are not digest-pinned. Every rebuild
  silently pulls a new `claude`.
- **Robustness (not security):** `apply_display` with x11 and `XAUTHORITY` unset emits the
  malformed volume `:/home/hostuser/.Xauthority:ro` (`generate-compose.py:187`).
- **`ssh:` widens the sandbox's attack surface from stdin to a network port** (added after
  this audit; `bootstrap/cc-wrapper.sh`, `apply_ssh` in `generate-compose.py`). Mitigations
  in place: opt-in, loopback-bound by default, pubkey-only against an explicit
  `authorized_keys`, `AllowUsers hostuser`, root login refused, sshd lives only as long as
  the `cc` session. Residual risks: `bind: 0.0.0.0` exposes the sandbox to the LAN with no
  further gate than the key; any local process that can read the named private key gets a
  shell in the sandbox (same blast radius as the `cc` terminal session itself); and when
  `anthropic_api_key_file` is set the key is copied into the container's `/etc/environment`
  for SSH sessions — no wider than the 0444 secret mount Docker already does, but a second
  in-container copy to remember.

---

## Suggested order of work

1. Ro-bind the executable parts of `~/.claude` (#1) and mask cross-project `projects/` /
   `history.jsonl` (#2) — these two are the difference between the README's promise and
   reality.
2. Ro-bind `.cc-docker/cc-docker.yml` + `docker-compose.yml` always (#3), and constrain
   `mounts[].path` to the project (#4).
3. Flip `display` to `disabled` by default, or switch to untrusted X cookies (#5).
4. Mask `.git/hooks` + `.git/config` (#7), fix the `readonly` gaps (#6), add
   `no-new-privileges` / `cap_drop`.

#1–#4 are all localized to `toolchain/config/generate-compose.py` plus
`toolchain/config/cc-docker.schema.json`.
