# Open idea: rich sandbox clients via ACP (instead of a custom web client)

Status: **open idea, not started** (July 2026). Companion to the parked
`feature/enable_ssh` branch, which this would build on. Nothing here is
committed work — it's the record of a design conversation, kept so the idea
can be picked up cold.

## Motivation

The terminal `cc` session is the only first-class way to work in a cc-docker
sandbox. What we actually want is a *rich* client (desktop or web UI) that is
a thin frontend over a Claude Code engine running **inside** the sandbox —
same mounts, same `hostuser`, same isolation.

Two approaches were explored and found wanting:

1. **SSH access for the Claude Code desktop app** (`feature/enable_ssh`,
   parked). Works, but with compromises: the desktop app auto-installs and
   launches its *own* engine on the remote, so cc-docker loses control of
   session creation. `--append-system-prompt` (how the terminal session gets
   `/sandbox.md`) has no settings/env equivalent, forcing a workaround: a
   `SessionStart` hook in the overlay `.claude/settings.json` that injects
   `sandbox.md` as *context* (not a true system prompt), gated by a
   `CC_SANDBOX_PROMPTED` env var against double injection. Functional, but a
   contraption.
2. **A custom web client + WebSocket daemon** over the Agent SDK. The daemon
   half is small (see below), but the client half — streaming markdown, diff
   rendering, permission dialogs, reconnect UX — is a real product to build
   and maintain. Community projects exist (claudecodeui/CloudCLI, claude-web,
   dzhng/claude-agent-server) but then we own an integration anyway.

## Use case beyond parity: a multi-sandbox client

cc-docker users accumulate many sandboxes — one per project, each with its
own `.cc-docker/` config. The terminal workflow forces one shell per sandbox.
With an ACP bridge, a single client can be *sandbox-aware*: it knows the
defined sandboxes and switches between them like tabs, each tab a live agent
session inside a different container.

ACP's model fits this directly: the client launches one agent subprocess per
session, so "a tab per sandbox" is just one agent entry per project. And
because the transport is stdio, the host-side agent command can simply be a
`cc` launcher variant — something like `cc acp -C ~/git/project-x` — that
regenerates the compose file, brings the container up, and `docker compose
run`s the in-container `cc-acp`. stdio passes straight through docker, so
**for local use no SSH is needed at all**; the SSH transport (below) matters
only for reaching a sandbox host remotely. Sandbox discovery could be as
simple as generating the editor's agent-registry entries from the list of
known projects (or a `cc acp --list` that scans for `.cc-docker/` dirs).

Two flavors, in increasing ambition:

1. **Existing editors as the client** — Zed/JetBrains with one registered
   agent per sandbox. No client code at all; "tabs" are the editor's own
   session/agent switcher. This is the version the spike below tests.
2. **A dedicated sandbox-manager client** — a purpose-built ACP client whose
   UI is organized around sandboxes (tab bar of containers, status, mounts
   shown per tab). Real client work again, but against a stable open
   protocol rather than Anthropic's private one — and it would work with any
   ACP agent, not just Claude Code.

## The enabling fact: the engine/UI boundary is already a wire protocol

The Claude Code TUI is one frontend over an engine whose interface is a
newline-delimited JSON protocol, observable directly:

```bash
claude -p --input-format stream-json --output-format stream-json --verbose "..."
```

Per turn the engine emits typed events — `system/init` (session id, tools,
model, permission mode), progress ticks, `assistant` messages with typed
content blocks (`thinking`, `text`, `tool_use`), tool results, and a final
`result` with stop reason / usage / cost. Input is the same NDJSON shape:
user messages plus a small control channel (interrupt, permission
allow/deny). The Agent SDK (`@anthropic-ai/claude-agent-sdk`) is itself a
client of this protocol — it spawns the `claude` binary in stream-json mode.
The desktop app, IDE extensions, and web app are all frontends over this same
engine. Anthropic ships no *interoperable* client for it (protocol is
unstable by design, permission UI is a security boundary, and their clients
are their funnel) — but the ecosystem standardized the gap instead.

## ACP: the standard for exactly this layer

The [Agent Client Protocol](https://zed.dev/acp) (ACP, created by Zed) is an
open JSON-RPC standard between agent engines and UIs — the analog of what MCP
did for agent↔tools, applied to agent↔UI. Session lifecycle: `initialize`
(capability negotiation) → new session (cwd, MCP servers, …) → prompt turns
with streaming updates, tool-call visibility, and structured permission
requests.

- 25+ agents speak it (many natively; Gemini CLI was the launch partner).
- Claude Code is bridged by Zed's Apache-licensed adapter,
  [`@zed-industries/claude-code-acp`](https://www.npmjs.com/package/@zed-industries/claude-code-acp)
  — a thin translator over the Agent SDK.
- Clients: Zed natively; JetBrains adopted ACP across its IDE suite (late
  2025); shared agent registry since Jan 2026.
- Transport is JSON-RPC over **stdio** — the client launches the agent as a
  subprocess. No networked transport in the core standard.

So a rich client does not need to be built: ACP-capable editors *are* the
thin client. What cc-docker needs to provide is the agent end of the pipe,
inside the container.

## Proposed shape

```
Zed / JetBrains (ACP client, rich UI)          ← exists, not our code
  → stdio pipe                                 ← local: `cc acp` (docker compose run);
    |                                            remote: SSH (feature/enable_ssh)
    → cc-acp wrapper                           ← NEW: cc-docker's launcher, ~30 lines
      → claude-code-acp adapter (Agent SDK)    ← exists, npm package
        → engine                               ← exists
```

The `cc-acp` wrapper is the same pattern as `bootstrap/run-as-hostuser.sh`: a
launcher that owns session creation. That dissolves the compromise that
parked the SSH branch — the entry point is ours again, so `sandbox.md` goes
in as a **true system-prompt append** via SDK options (plus permission mode,
settings), no hook, no `CC_SANDBOX_PROMPTED` gating. Permission prompts get
*better* than the terminal: they flow through ACP as structured requests and
render as real allow/deny UI in the editor.

The SSH transport composes rather than competes:
`ssh hostuser@127.0.0.1 cc-acp` is a remote stdio pipe; editors' own SSH
remoting (e.g. Zed remote development) is the alternative carrier.

## Generalization: a sandbox-agnostic bridge (analysis only — NOT a goal)

> **Scope decision (July 2026):** recorded as analysis, explicitly *not*
> something this repo's author intends to build or maintain — a generic tool
> with a wide audience means becoming a maintainer of a niche OSS project,
> which is not on the table. Everything cc-docker actually needs is covered
> by the local path above (`cc acp` + in-container wrapper) and works
> without this. If someone else ships the bridge, cc-docker's move is to
> write a *provider* for it — consumer work, not maintainer work. The
> section stays because the analysis explains the landscape and would make a
> provider integration quick.
>
> **Context:** the original motivation for generalizing was a concrete second
> consumer — a colleague's (in-company) sandbox toolbox that is more advanced
> than cc-docker: cleaner sandboxing, multi-agent (Claude + Codex), and
> docker/podman/VM backends. That backend axis is exactly the "provider"
> axis below, and multi-agent is what ACP's agent-agnosticism buys — so that
> toolbox is the natural home for a bridge/client layer, and this section
> doubles as a design memo that could be handed over. cc-docker stays a
> deliberately small, personal, fun-to-develop provider either way.

The multi-sandbox client points past cc-docker: the middle of the stack is
generic. A standalone tool — working name `sandbox-bridge` — could own it,
with cc-docker as its first provider rather than its owner:

- **Generic core** (agent- and sandbox-tool-agnostic): sandbox
  registry/discovery via pluggable providers, lifecycle (up on demand, down
  on session end), and transport — produce a stdio pipe into the sandbox
  (`docker compose run` / `docker exec` / `ssh` / `kubectl exec`, provider's
  choice) and present it to any ACP client as a local agent command:
  `sandbox-bridge acp <sandbox-id>`.
- **Deliberately excluded from the core**: session negotiation (system-prompt
  injection, permission modes) — agent- and provider-specific, lives in the
  provider's *in-sandbox* launcher (cc-docker: the `cc-acp` wrapper). The
  bridge only promises to run whatever command the provider names inside the
  sandbox. Also excluded: UI (editors and future clients sit upstream).
- **Provider contract** (sketch): `list()` → sandbox ids + metadata,
  `up(id)`, `pipe(id, cmd)` → stdio, plus the name of the in-sandbox agent
  command. cc-docker implements this almost for free (`cc` already locates
  projects, regenerates compose, runs the container); `feature/enable_ssh`
  becomes one provider's remote-transport option.
- **Two tiers**: tier 1 is a pure CLI (ACP clients spawn subprocesses — no
  daemon needed for the editor use case). Tier 2, optional, is a service for
  what a subprocess can't do: web client hosting, remote access, persistent
  tab-manager state.

Risks / preconditions: treat provider definitions as code, not config (the
bridge executes provider-defined commands — trust model needed); extract the
provider contract *from* the working cc-docker case rather than designing it
for hypothetical consumers.

### Prior-art survey (July 2026)

The exact shape — an agent-agnostic ACP bridge with a sandbox-provider
contract (discovery + lifecycle + stdio transport) — **looks unclaimed**.
The neighbors, by category:

- **Raw demand, no tool.** Zed users ask for exactly this:
  ["ACPs hosted as Docker containers"](https://github.com/zed-industries/zed/discussions/54913)
  — today's answer is a hand-written `agent_servers` entry running
  `docker exec -i <container> <agent>`, with known rough edges (Zed
  resolving binaries locally instead of in-container; external agents
  [broken over Zed's SSH remoting](https://github.com/zed-industries/zed/issues/47910);
  [remote-ACP/remote-MCP incompatibility](https://github.com/zed-industries/zed/issues/52254)).
  The bridge's tier-1 job is precisely to make this robust — the friction is
  documented, which is both validation and a bug surface to design around.
- **Vertically integrated container-agent apps.** The big one is
  [Sculptor (Imbue)](https://github.com/imbue-ai/sculptor) — open source,
  runs each agent in its own Docker container
  [built from your repo or devcontainer](https://docs.imbue.com/features/containers),
  parallel agents, own desktop UI. Closest existing product to the
  *use case* (comfortable multi-sandbox agent work), but it owns the whole
  stack — its UI, its container scheme, not ACP-based. **Evaluate before
  building anything**: if Sculptor's sandbox definition is pluggable enough
  to honor a cc-docker-style config, it may simply be the answer; if not,
  it's the strongest argument that the *decoupled* (bridge) version is worth
  having. Also in this camp: Conductor (macOS, git worktrees not
  containers), Crystal (deprecated Feb 2026 → paid Nimbalyst), vibe-kanban
  (company shut down Apr 2026, now community-maintained), Superset, Claude
  Squad. Notable churn — two died in 2026 — which signals both real demand
  and the cost of owning a client. A bridge deliberately avoids owning one.
- **Sandbox runtimes (provider-side, no client).**
  [Dagger's container-use](https://github.com/dagger/container-use) (MCP
  server giving agents per-branch containers), devcontainer CLI,
  trailofbits' claude-code-devcontainer, Anthropic's sandbox runtime, cloud
  sandboxes (E2B, Daytona), and cc-docker itself. These are all potential
  *providers* under the bridge, not competitors. A useful landscape list:
  [coding-agent sandboxes gist (2026-05)](https://gist.github.com/wincent/2752d8d97727577050c043e4ff9e386e).
- **Pre-ACP programmatic control.** [coder/agentapi](https://github.com/coder/agentapi)
  — HTTP API over Claude Code/Aider/etc. via *terminal emulation*; Coder is
  folding this era into its own "Coder Agents" product (Tasks moved to ESR,
  June 2026). Historically interesting: it proves the demand for
  programmatic agent control, and ACP obsoletes its technique.
- **ACP protocol plumbing.** [MCP-over-ACP RFD](https://agentclientprotocol.com/rfds/mcp-over-acp)
  and [Symposium's SACP extensions](https://agentclientprotocol.github.io/symposium-acp/mcp-bridge.html)
  (proxy/tunnel patterns within ACP) — relevant machinery for the remote
  case, not products in this space.

Net: the use case is validated from multiple directions, the provider side
is crowded, the client side is churning, and the *decoupling layer between
them* is missing. That's the bridge. The one genuine pre-build check left:
try Sculptor against a cc-docker-shaped workflow first.

## What would need to be built

- `cc-acp` launcher in `bootstrap/` (or an image layer): exec the adapter
  with SDK options for system-prompt append, permission mode, settings
  sources. Check first whether `claude-code-acp` already exposes these via
  env/config; if not, a small patch/fork (Apache-licensed, thin).
- Image dependency: the adapter is an npm package → the image needs Node.
  Already available as the `node` stack module; would become a prerequisite
  for this feature (or the adapter gets bundled).
- Host-side launcher entry point: a `cc acp` mode in `init-cc.sh` that brings
  the container up and runs the in-container `cc-acp` with stdio passed
  through (`docker compose run` already does this); optionally `cc acp
  --list` for sandbox discovery / editor agent-registry generation.
- Config surface: reuse/extend the `ssh:` block from `feature/enable_ssh`
  (remote case only), or a sibling `acp:` key.
- Client-side setup docs: registering the agent in Zed / JetBrains with the
  SSH command as the agent executable.

## Open questions

- Does `claude-code-acp` expose SDK session options (system prompt append,
  permission mode) without patching? (Unverified as of July 2026.)
- Editor remoting specifics: exact mechanics of running an ACP agent over
  SSH per editor (Zed remote dev vs. plain `ssh` as the agent command) —
  needs a spike.
- Feature coverage: ACP carries the common surface (prompt, streaming, tool
  visibility, permissions, file context); agent-specific extras degrade or
  need ACP extension points (`_meta`). Acceptable? Probably, but verify the
  daily-driver workflows (plan mode, slash commands, images).
- Protocol drift: the adapter tracks the Agent SDK, which tracks the CLI.
  Version-pinning strategy for the image.
- Fallback parity: the overlay `SessionStart` hook from `feature/enable_ssh`
  works unmodified for ACP sessions (they load the same project settings) —
  keep it as belt-and-braces or drop it?

## Cheap first spike

Before building anything: in a cc container with `node`, `npm i -g
@zed-industries/claude-code-acp`, then register an agent in Zed on the host
whose command pipes stdio into the container — locally no SSH needed, e.g.
`docker compose -f <project>/.cc-docker/docker-compose.yml run --rm cc
claude-code-acp` (or via the SSH branch for a remote host) — and see whether
the UX clears the bar. Repeat with a second project to taste the
tab-per-sandbox flow. Only then decide whether cc-docker should grow native
support.
