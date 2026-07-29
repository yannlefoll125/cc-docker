# init-cc.sh — defines the cc-docker shell functions (init-cc, cc, migrate-cc).
#
# CONVENTION: EVERY function defined in this file MUST begin with the self-refresh
# block below (copy it verbatim, substituting the function's own name in the
# re-exec line). It re-sources this file and re-execs the function so an invocation
# always runs the latest on-disk version, without the user having to manually
# re-source after an edit/update. The _CC_REEXEC guard (set only for the re-exec)
# prevents infinite recursion. When adding a new function here, do the same.

init-cc() {
    # Self-refresh: pick up edits/updates to init-cc.sh without a manual re-source.
    # Re-source then re-exec so THIS invocation runs the latest on-disk version; the
    # guard var (set only for the re-exec) prevents infinite recursion.
    if [[ -z "${_CC_REEXEC:-}" && -n "${CC_DOCKER_DIR:-}" && -f "$CC_DOCKER_DIR/init-cc.sh" ]]; then
        source "$CC_DOCKER_DIR/init-cc.sh" || return 1
        _CC_REEXEC=1 init-cc "$@"
        return $?
    fi
    unset _CC_REEXEC

    if [[ -z "${CC_DOCKER_DIR:-}" ]]; then
        echo "Error: CC_DOCKER_DIR is not set." >&2
        echo "Add to your .bashrc:" >&2
        echo "  export CC_DOCKER_DIR=/path/to/cc-docker" >&2
        echo "  source \"\$CC_DOCKER_DIR/init-cc.sh\"" >&2
        return 1
    fi

    # Discover available stack modules (stack/<name>/module.yml). No error when empty:
    # `modules: []` (base only) is a valid config.
    local stacks=()
    for d in "$CC_DOCKER_DIR/stack/"*/; do
        [[ -f "$d/module.yml" ]] || continue
        stacks+=("$(basename "$d")")
    done

    local default_dir="$PWD"
    printf "Project root [%s]: " "$default_dir"
    read -r project_dir
    project_dir="${project_dir:-$default_dir}"
    project_dir="${project_dir%/}"

    if [[ ! -d "$project_dir" ]]; then
        echo "Error: directory does not exist: $project_dir" >&2
        return 1
    fi

    echo ""
    if [[ ${#stacks[@]} -gt 0 ]]; then
        echo "Available stack modules:"
        for s in "${stacks[@]}"; do printf "  - %s\n" "$s"; done
    else
        echo "(no stack modules found under $CC_DOCKER_DIR/stack/)"
    fi
    printf "Modules (space-separated; blank = base only): "
    read -r modules_input
    local modules=() m
    for m in $modules_input; do
        if [[ " ${stacks[*]} " != *" $m "* ]]; then
            echo "Error: unknown stack module '$m' (see the list above)" >&2
            return 1
        fi
        modules+=("$m")
    done

    echo ""
    local default_name
    default_name="$(git config --global user.name 2>/dev/null || true)"
    printf "Git user name [%s]: " "${default_name:-none}"
    read -r git_name
    git_name="${git_name:-$default_name}"

    local default_email
    default_email="$(git config --global user.email 2>/dev/null || true)"
    printf "Git email [%s]: " "${default_email:-none}"
    read -r git_email
    git_email="${git_email:-$default_email}"

    echo ""
    local target_dir="$project_dir/.cc-docker"
    if [[ -d "$target_dir" ]]; then
        printf ".cc-docker/ already exists. Overwrite? [y/N]: "
        read -r overwrite
        if [[ "${overwrite,,}" != "y" ]]; then
            echo "Aborted."
            return 0
        fi
    fi

    mkdir -p "$target_dir"

    local modules_csv="" m2
    for m2 in "${modules[@]}"; do modules_csv="${modules_csv:+$modules_csv, }$m2"; done
    cat > "$target_dir/cc-docker.yml" <<EOF
modules: [${modules_csv}]
git:
  name: ${git_name}
  email: ${git_email}
mounts:
  - path: .
EOF

    printf "Add .cc-docker/ to .gitignore? [Y/n]: "
    read -r add_gitignore
    if [[ "${add_gitignore,,}" != "n" ]]; then
        local gitignore_path="$project_dir/.gitignore"
        if grep -qxF '.cc-docker/' "$gitignore_path" 2>/dev/null; then
            echo ".cc-docker/ is already in .gitignore"
        else
            echo '.cc-docker/' >> "$gitignore_path"
            echo "Added .cc-docker/ to .gitignore"
        fi
    fi

    echo ""
    echo "Done! .cc-docker/ initialized in $project_dir"
    echo ""
    echo "Run Claude Code with:"
    echo "  cc"
}

# cc — launcher: regenerates docker-compose.yml from cc-docker.yml (if present)
# and runs it. Works from any subdirectory of the project by walking up to find
# .cc-docker/. Backward compatible: a project with only a hand-written
# docker-compose.yml (no cc-docker.yml) runs directly, no regeneration.
#
# By default cc does NOT (re)build the assembled image — it just runs whatever is
# already built (fast path). Pass `--build` (or set CC_BUILD=1) to assemble and
# build first; without it, a missing image fails fast with a build hint rather than
# a confusing registry-pull error.
cc() {
    # Self-refresh: pick up edits/updates to init-cc.sh without a manual re-source.
    # Re-source then re-exec so THIS invocation runs the latest on-disk version; the
    # guard var (set only for the re-exec) prevents infinite recursion.
    if [[ -z "${_CC_REEXEC:-}" && -n "${CC_DOCKER_DIR:-}" && -f "$CC_DOCKER_DIR/init-cc.sh" ]]; then
        source "$CC_DOCKER_DIR/init-cc.sh" || return 1
        _CC_REEXEC=1 cc "$@"
        return $?
    fi
    unset _CC_REEXEC

    # Build gating: default is run-only (no build). A leading `--build` or CC_BUILD=1
    # opts into the assemble+build path. Consume the flag so it never reaches claude.
    local do_build="${CC_BUILD:-}"
    if [[ "${1:-}" == "--build" ]]; then
        do_build=1
        shift
    fi

    local dir="$PWD"
    while [[ ! -d "$dir/.cc-docker" && "$dir" != "/" ]]; do
        dir="$(dirname "$dir")"
    done
    if [[ ! -d "$dir/.cc-docker" ]]; then
        echo "Error: no .cc-docker/ found in $PWD or any parent directory." >&2
        echo "Run init-cc to set one up." >&2
        return 1
    fi

    local target_dir="$dir/.cc-docker"
    local config_file="$target_dir/cc-docker.yml"
    local compose_file="$target_dir/docker-compose.yml"

    if [[ -f "$config_file" ]]; then
        # Project-local .claude execution context: redirected into the gitignored
        # .cc-docker/.claude/ (created by cc-config itself, alongside the bind
        # mount it adds) so nothing Claude writes at the project level
        # (settings.local.json, plans/, todos) ends up in the committed/shared
        # project tree.
        local gitignore_path="$dir/.gitignore"
        if ! grep -qxF '.claude/' "$gitignore_path" 2>/dev/null; then
            echo '.claude/' >> "$gitignore_path"
        fi

        # Best-effort sanity check: cc-config runs in its own container and can't
        # see the host filesystem outside $dir/$target_dir, so a typo'd
        # anthropic_api_key_file path would otherwise fail silently deep inside
        # `docker compose run` (a missing `secrets.*.file` source). Check it here,
        # in the host shell, where ~ and relative paths resolve normally.
        local key_file
        key_file="$(grep -E '^anthropic_api_key_file:' "$config_file" 2>/dev/null | sed -E "s/^anthropic_api_key_file:[[:space:]]*//; s/^['\"]//; s/['\"]\$//")"
        if [[ -n "$key_file" ]]; then
            local expanded_key_file="${key_file/#\~/$HOME}"
            if [[ ! -f "$expanded_key_file" ]]; then
                echo "warning: anthropic_api_key_file '$key_file' not found on host — API key auth will fail" >&2
            fi
        fi

        # Same best-effort check for the ssh: block's authorized_keys — a missing
        # file would otherwise surface as an opaque mount error at compose time.
        local ssh_keys_file
        ssh_keys_file="$(grep -E '^[[:space:]]+authorized_keys:' "$config_file" 2>/dev/null | head -1 \
            | sed -E "s/^[[:space:]]+authorized_keys:[[:space:]]*//; s/^['\"]//; s/['\"]\$//")"
        if [[ -n "$ssh_keys_file" ]]; then
            local expanded_ssh_keys="${ssh_keys_file/#\~/$HOME}"
            if [[ ! -f "$expanded_ssh_keys" ]]; then
                echo "warning: ssh.authorized_keys '$ssh_keys_file' not found on host — SSH login will fail" >&2
            fi
        fi

        # Ensure the config-generator image exists (normally pre-built by build.sh).
        docker image inspect cc-config >/dev/null 2>&1 \
            || docker build -t cc-config "$CC_DOCKER_DIR/toolchain/config" >/dev/null \
            || return 1

        docker run --rm \
            -e PROJECT_DIR="$dir" \
            -e HOST_UID="$(id -u)" \
            -e HOST_GID="$(id -g)" \
            -e CC_HOST_WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
            -e CC_HOST_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
            -e CC_HOST_DISPLAY="${DISPLAY:-}" \
            -e CC_HOST_XAUTHORITY="${XAUTHORITY:-}" \
            -e CC_HOST_HOME="$HOME" \
            -v "$dir":/project:ro \
            -v "$target_dir":/out \
            cc-config || return 1

        # Modular mode: cc-config wrote .cc-docker/assembled.tag (+ assembled.modules).
        # With --build, assemble the per-project Dockerfile, build its blocks, then the
        # final image; otherwise just verify the image is already built (run-only fast
        # path). Legacy `image:` configs leave no assembled.tag, so this is skipped.
        if [[ -f "$target_dir/assembled.tag" ]]; then
            local tag; tag="$(cat "$target_dir/assembled.tag")"

            if [[ -n "$do_build" ]]; then
                local modules=(); mapfile -t modules < "$target_dir/assembled.modules"

                # Ensure the assembler image exists (normally pre-built by build.sh).
                docker image inspect cc-assemble >/dev/null 2>&1 \
                    || docker build -t cc-assemble "$CC_DOCKER_DIR/toolchain/assemble" >/dev/null \
                    || return 1

                # Generate assembled.Dockerfile from modules: + each module.yml.
                docker run --rm \
                    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
                    -v "$target_dir":/out \
                    -v "$CC_DOCKER_DIR/stack":/stack:ro \
                    cc-assemble || return 1

                # Build base + this project's stacks (scoped; always build, cache decides).
                "$CC_DOCKER_DIR/build.sh" base "${modules[@]}" || return 1

                # Build the assembled final under a per-tag flock in a shared, user-writable
                # location (the final is global per module set → the lock is cross-project).
                local lock_dir="${XDG_RUNTIME_DIR:-/tmp}/cc-docker/locks"
                mkdir -p "$lock_dir"
                local lock_file="$lock_dir/$(printf '%s' "$tag" | tr '/:' '__').lock"
                ( flock 9 || exit 1
                  docker build -f "$target_dir/assembled.Dockerfile" -t "$tag" "$CC_DOCKER_DIR/bootstrap"
                ) 9>"$lock_file" || return 1
            elif ! docker image inspect "$tag" >/dev/null 2>&1; then
                # Run-only path, but the image was never built. The compose file pins
                # `image: <tag>` (no build:), so `compose run` would just fail on a
                # registry pull — bail here with an actionable hint instead.
                echo "Error: image '$tag' is not built yet." >&2
                echo "Run 'cc --build' (or set CC_BUILD=1) to assemble and build it." >&2
                return 1
            fi
        fi
    elif [[ ! -f "$compose_file" ]]; then
        echo "Error: no cc-docker.yml or docker-compose.yml found in $target_dir." >&2
        echo "Run init-cc to set one up." >&2
        return 1
    fi

    # --service-ports: `compose run` ignores the service's ports: mapping without
    # it. Only the ssh: feature declares ports today; a no-op for everyone else.
    docker compose -f "$compose_file" run --rm --service-ports cc "$@"
}

# migrate-cc — upgrade a pre-modular project to the modular `modules:` engine.
#
# Handles the two legacy shapes a project can be in:
#
#   1. A `cc-docker.yml` in legacy `image:` mode (e.g. `image: cc-node20`).
#      Rewrites the single `image:` line to an equivalent `modules:` line and
#      leaves every other field (git, mounts, env, …) untouched.
#
#   2. A hand-written `docker-compose.yml` with NO `cc-docker.yml` — the oldest
#      "raw" init-cc output. Reverse-engineers a `cc-docker.yml` from it (image →
#      modules, git identity from .env / the environment block, docker socket, API
#      key secret), then lets the `cc` launcher regenerate `docker-compose.yml` on
#      its next run.
#
# Known legacy image → module mapping:
#   cc-base → (none)   cc-node20 → node   cc-vue3 → node   cc-zulu21 → zulu
#   cc-pdf2md → pdf2md   cc-full → node python3 (Ruby + extra CLI tools have no
#   module — a note is printed). An unknown image (e.g. cc-dev or a custom one)
#   prompts for a module list, or is kept as-is in `image:` mode when left blank.
#
# Anything overwritten is backed up to <file>.bak first. migrate-cc never builds:
# afterwards run `cc --build` (modular) or `cc` (a kept `image:`).
migrate-cc() {
    # Self-refresh — see the convention note at the top of this file.
    if [[ -z "${_CC_REEXEC:-}" && -n "${CC_DOCKER_DIR:-}" && -f "$CC_DOCKER_DIR/init-cc.sh" ]]; then
        source "$CC_DOCKER_DIR/init-cc.sh" || return 1
        _CC_REEXEC=1 migrate-cc "$@"
        return $?
    fi
    unset _CC_REEXEC

    if [[ -z "${CC_DOCKER_DIR:-}" ]]; then
        echo "Error: CC_DOCKER_DIR is not set." >&2
        echo "Add to your .bashrc:" >&2
        echo "  export CC_DOCKER_DIR=/path/to/cc-docker" >&2
        echo "  source \"\$CC_DOCKER_DIR/init-cc.sh\"" >&2
        return 1
    fi

    # Locate the project's .cc-docker/: an explicit arg wins, else walk up from
    # $PWD like `cc` does, else fall back to prompting.
    local dir=""
    if [[ -n "${1:-}" ]]; then
        dir="${1%/}"
        if [[ ! -d "$dir/.cc-docker" ]]; then
            echo "Error: no .cc-docker/ in '$dir'." >&2
            return 1
        fi
    else
        dir="$PWD"
        while [[ ! -d "$dir/.cc-docker" && "$dir" != "/" ]]; do
            dir="$(dirname "$dir")"
        done
        if [[ ! -d "$dir/.cc-docker" ]]; then
            printf "Project root [%s]: " "$PWD"
            read -r dir
            dir="${dir:-$PWD}"
            dir="${dir%/}"
            if [[ ! -d "$dir/.cc-docker" ]]; then
                echo "Error: no .cc-docker/ in '$dir'." >&2
                return 1
            fi
        fi
    fi

    local target_dir="$dir/.cc-docker"
    local config_file="$target_dir/cc-docker.yml"
    local compose_file="$target_dir/docker-compose.yml"

    # Discover valid stack modules (to validate the mapping output / any user input).
    local stacks=()
    for d in "$CC_DOCKER_DIR/stack/"*/; do
        [[ -f "$d/module.yml" ]] && stacks+=("$(basename "$d")")
    done

    # Detect what we're migrating FROM.
    local mode=""   # image | compose
    if [[ -f "$config_file" ]]; then
        if grep -qE '^modules:' "$config_file"; then
            echo "Already modular: $config_file has a modules: line — nothing to migrate."
            return 0
        elif grep -qE '^image:' "$config_file"; then
            mode="image"
        else
            echo "Error: $config_file has neither an image: nor a modules: key." >&2
            return 1
        fi
    elif [[ -f "$compose_file" ]]; then
        mode="compose"
    else
        echo "Error: $target_dir has no cc-docker.yml or docker-compose.yml to migrate." >&2
        return 1
    fi

    # Extract the legacy image name from whichever source we found.
    local legacy_image=""
    if [[ "$mode" == "image" ]]; then
        legacy_image="$(grep -E '^image:' "$config_file" | head -1 \
            | sed -E "s/^image:[[:space:]]*//; s/^['\"]//; s/['\"]\$//")"
    else
        legacy_image="$(grep -E '^[[:space:]]*image:' "$compose_file" | head -1 \
            | sed -E "s/^[[:space:]]*image:[[:space:]]*//; s/^['\"]//; s/['\"]\$//")"
    fi
    if [[ -z "$legacy_image" ]]; then
        local src; [[ "$mode" == "image" ]] && src="$config_file" || src="$compose_file"
        echo "Error: could not find an image: to migrate in $src." >&2
        return 1
    fi

    # Advisories to surface in the migration preview (populated as we go).
    local -a notes=()

    # Map the legacy image → a modules list. Strip the cc- prefix and any :tag.
    local short="${legacy_image#cc-}"; short="${short%%:*}"
    local modules_str="" known=1
    case "$short" in
        base)   modules_str="" ;;
        node20) modules_str="node" ;;
        vue3)   modules_str="node" ;;
        zulu21) modules_str="zulu" ;;
        pdf2md) modules_str="pdf2md" ;;
        full)
            modules_str="node python3"
            notes+=("legacy 'full' also bundled Ruby + extra CLI tooling (ripgrep, fd, jq, …) that have no stack module — add via per-project apt if needed")
            ;;
        *) known=0 ;;
    esac

    # Unknown image: let the user pick modules, or keep the image: as-is.
    local keep_image=0
    if [[ $known -eq 0 ]]; then
        echo "'$legacy_image' is not a known legacy cc-* image."
        if [[ ${#stacks[@]} -gt 0 ]]; then
            echo "Available stack modules:"
            for s in "${stacks[@]}"; do printf "  - %s\n" "$s"; done
        fi
        printf "Modules to use instead (space-separated; blank = keep 'image: %s' unchanged): " "$legacy_image"
        read -r modules_str
        [[ -z "$modules_str" ]] && keep_image=1
    fi

    # Validate every module we're about to write against the discovered stacks.
    if [[ $keep_image -eq 0 ]]; then
        local m
        for m in $modules_str; do
            if [[ " ${stacks[*]} " != *" $m "* ]]; then
                echo "Error: unknown stack module '$m' (see $CC_DOCKER_DIR/stack/)." >&2
                return 1
            fi
        done
    fi

    local modules_csv="" m2
    for m2 in $modules_str; do modules_csv="${modules_csv:+$modules_csv, }$m2"; done

    # ---- Build the proposed cc-docker.yml (in memory; not yet written) -----
    local new_content backup_src change_summary

    if [[ "$mode" == "image" ]]; then
        if [[ $keep_image -eq 1 ]]; then
            echo "Kept 'image: $legacy_image' unchanged — nothing to migrate."
            return 0
        fi
        # Swap only the image: line for a modules: line; the rest is preserved verbatim.
        new_content="$(sed -E "s|^image:[[:space:]]*.*|modules: [${modules_csv}]|" "$config_file")"
        backup_src="$config_file"
        change_summary="image: $legacy_image  →  modules: [${modules_csv}]"
    else
    # mode == compose: reverse-engineer a fresh cc-docker.yml.
    #
    # Git identity: prefer the sibling .env (how the raw compose sourced it), then
    # fall back to a hard-coded value in the compose environment: block, then prompt.
    local env_file="$target_dir/.env"
    local git_name="" git_email=""
    if [[ -f "$env_file" ]]; then
        git_name="$(grep -E '^GIT_USER_NAME=' "$env_file" | head -1 | sed 's/^GIT_USER_NAME=//')"
        git_email="$(grep -E '^GIT_USER_EMAIL=' "$env_file" | head -1 | sed 's/^GIT_USER_EMAIL=//')"
    fi
    # A literal (non-${...}) value baked into the compose environment: block.
    if [[ -z "$git_name" ]]; then
        git_name="$(grep -E '^[[:space:]]*GIT_USER_NAME:' "$compose_file" | head -1 \
            | sed -E "s/^[[:space:]]*GIT_USER_NAME:[[:space:]]*//; s/^['\"]//; s/['\"]\$//")"
        [[ "$git_name" == *'$'* ]] && git_name=""
    fi
    if [[ -z "$git_email" ]]; then
        git_email="$(grep -E '^[[:space:]]*GIT_USER_EMAIL:' "$compose_file" | head -1 \
            | sed -E "s/^[[:space:]]*GIT_USER_EMAIL:[[:space:]]*//; s/^['\"]//; s/['\"]\$//")"
        [[ "$git_email" == *'$'* ]] && git_email=""
    fi
    if [[ -z "$git_name" ]]; then
        local default_name; default_name="$(git config --global user.name 2>/dev/null || true)"
        printf "Git user name [%s]: " "${default_name:-none}"
        read -r git_name; git_name="${git_name:-$default_name}"
    fi
    if [[ -z "$git_email" ]]; then
        local default_email; default_email="$(git config --global user.email 2>/dev/null || true)"
        printf "Git email [%s]: " "${default_email:-none}"
        read -r git_email; git_email="${git_email:-$default_email}"
    fi

    # Anthropic API-key secret, if the compose declared one (a secrets: block with a
    # host file). Volumes (incl. the Docker socket) are handled by the parser below.
    local api_key_file=""
    if grep -qi 'anthropic' "$compose_file"; then
        api_key_file="$(grep -E '^[[:space:]]+file:' "$compose_file" | head -1 \
            | sed -E "s/^[[:space:]]+file:[[:space:]]*//; s/^['\"]//; s/['\"]\$//")"
    fi

    # ---- Volume reconstruction --------------------------------------------
    #
    # Parse the cc service's `volumes:` list and sort each entry into one of:
    #   - a PROJECT bind (source == target, under the project root) → `mounts:`,
    #     as `path: .` for the whole root or a relative path for a subdir;
    #   - the host Docker socket → `docker_socket: true`;
    #   - a mount cc-config re-adds itself (the ~/.claude* pair, the .cc-docker
    #     overlay + cc-docker.yml, the X11/Wayland display sockets) → dropped, so
    #     it isn't duplicated;
    #   - anything else (custom host paths, caches, named volumes) → `extra_mounts:`,
    #     preserved verbatim so its exact behavior carries over.
    #
    # The awk pass normalizes both short-form ("src:tgt[:mode]") and long-form
    # ("- type: bind / source: / target: / read_only:") entries of the *service*
    # volumes list (the first indented `volumes:`), emitting one tab-separated
    # record per volume for the bash classifier to bucket.
    local project_dir="$dir"
    # The project root *as the compose sees it* is its working_dir — this is what
    # bind sources are relative to, and it may differ from where .cc-docker/ sits if
    # the project was moved. Reconstruct paths against it (falling back to the
    # detected dir when it's absent or an unexpanded ${…}).
    local root_ref
    root_ref="$(grep -E '^[[:space:]]*working_dir:' "$compose_file" | head -1 \
        | sed -E "s/^[[:space:]]*working_dir:[[:space:]]*//; s/^['\"]//; s/['\"]\$//")"
    root_ref="${root_ref//\$\{PWD\}/$project_dir}"; root_ref="${root_ref//\$PWD/$project_dir}"
    [[ -z "$root_ref" || "$root_ref" == *'${'* ]] && root_ref="$project_dir"

    local -a mounts_paths=() extras=()
    local docker_socket=0 readonly_any=0 rw_any=0

    local kind f1 f2 f3
    while IFS=$'\t' read -r kind f1 f2 f3; do
        local original src tgt ro=0
        if [[ "$kind" == "SHORT" ]]; then
            original="$f1"
            local s="$f1"
            case "$s" in
                *:ro) ro=1; s="${s%:ro}" ;;
                *:rw) s="${s%:rw}" ;;
                *:z|*:Z) s="${s%:?}" ;;
            esac
            if [[ "$s" != *:* ]]; then          # named volume / no target → keep verbatim
                extras+=("$original"); continue
            fi
            src="${s%%:*}"; tgt="${s#*:}"
        else                                     # BIND (long-form)
            src="$f1"; tgt="$f2"; ro="${f3:-0}"
            original="$src:$tgt"; [[ "$ro" == 1 ]] && original="$original:ro"
        fi

        # Expand ${PWD}/$PWD (what the raw compose used for the project root).
        local es="${src//\$\{PWD\}/$project_dir}"; es="${es//\$PWD/$project_dir}"
        local et="${tgt//\$\{PWD\}/$project_dir}"; et="${et//\$PWD/$project_dir}"

        # Mounts cc-config re-adds on its own — drop so they're not duplicated.
        case "$et" in
            /home/hostuser/.claude|/home/hostuser/.claude.json) continue ;;
            "$root_ref/.claude"|*/.cc-docker/cc-docker.yml) continue ;;
        esac
        case "$es" in
            "~/.claude"|"~/.claude.json"|*/.cc-docker/.claude) continue ;;
        esac
        # Display sockets — reinstated by `display:` (auto). Drop.
        case "$es$et" in
            *.X11-unix*|*Xauthority*|*WAYLAND_DISPLAY*) continue ;;
        esac
        # Host Docker socket → the dedicated flag.
        case "$es$et" in
            */docker.sock*) docker_socket=1; continue ;;
        esac

        # Project bind: same host path in and out, at or under the project root.
        if [[ "$es" == "$et" && ( "$es" == "$root_ref" || "$es" == "$root_ref"/* ) ]]; then
            local rel
            if [[ "$es" == "$root_ref" ]]; then rel="."; else rel="${es#"$root_ref"/}"; fi
            mounts_paths+=("$rel")
            if [[ "$ro" == 1 ]]; then readonly_any=1; else rw_any=1; fi
            continue
        fi

        # Everything else: carry over untouched.
        extras+=("$original")
    done < <(awk '
        function flush(){
            if(kind=="bind" && (src!="" || tgt!=""))      printf "BIND\t%s\t%s\t%s\n", src, tgt, ro
            kind=""; src=""; tgt=""; ro=0
        }
        BEGIN{ inv=0; vind=-1 }
        {
            line=$0; match(line,/^ */); ind=RLENGTH
            c=line; sub(/^ +/,"",c); sub(/ +$/,"",c)
            if(c=="") next
            if(c ~ /^#/) next                            # comment (may sit at col 0) — never ends the block
            if(!inv){ if(ind>0 && c ~ /^volumes:/){ inv=1; vind=ind } next }
            if(ind<=vind){ flush(); inv=0; next }        # left the volumes block
            if(c ~ /^- /){
                flush()
                item=c; sub(/^- +/,"",item)
                if(item ~ /^type:[ \t]*bind/){  kind="bind"; next }
                if(item ~ /^type:[ \t]*tmpfs/){ kind="tmpfs"; next }
                if(item ~ /^source:/){ kind="bind"; v=item; sub(/^source:[ \t]*/,"",v); gsub(/^"|"$/,"",v); src=v; next }
                if(item ~ /^target:/){ kind="bind"; v=item; sub(/^target:[ \t]*/,"",v); gsub(/^"|"$/,"",v); tgt=v; next }
                gsub(/^"|"$/,"",item); printf "SHORT\t%s\n", item; next
            }
            if(c ~ /^type:[ \t]*bind/){  kind="bind"; next }
            if(c ~ /^type:[ \t]*tmpfs/){ kind="tmpfs"; next }
            if(c ~ /^source:/){ v=c; sub(/^source:[ \t]*/,"",v); gsub(/^"|"$/,"",v); src=v; next }
            if(c ~ /^target:/){ v=c; sub(/^target:[ \t]*/,"",v); gsub(/^"|"$/,"",v); tgt=v; next }
            if(c ~ /^read_only:[ \t]*true/){ ro=1; next }
        }
        END{ flush() }
    ' "$compose_file")

    # A raw compose always mounted the project root; if the parse found no project
    # bind at all, fall back to the whole root so the result is at least runnable.
    if [[ ${#mounts_paths[@]} -eq 0 ]]; then
        mounts_paths=(".")
        notes+=("no project mount found in the compose file — defaulted to 'path: .'")
    fi
    # `readonly:` is global. It's emitted only when *every* project mount was :ro
    # (a whole read-only project); a mix can't be expressed, so flag it instead.
    if [[ $readonly_any -eq 1 && $rw_any -eq 1 ]]; then
        notes+=("compose mixed read-only and read-write project mounts; 'readonly:' is all-or-nothing — left read-write, review before use")
    fi
    [[ -f "$env_file" ]] && notes+=("git identity now lives in cc-docker.yml; the old .env is no longer used")

    backup_src="$compose_file"
    change_summary="reconstructed cc-docker.yml from $compose_file"
    new_content="$(
        if [[ $keep_image -eq 1 ]]; then echo "image: $legacy_image"; else echo "modules: [${modules_csv}]"; fi
        if [[ -n "$git_name" || -n "$git_email" ]]; then
            echo "git:"
            [[ -n "$git_name" ]]  && echo "  name: $git_name"
            [[ -n "$git_email" ]] && echo "  email: $git_email"
        fi
        [[ $readonly_any -eq 1 && $rw_any -eq 0 ]] && echo "readonly: true"
        echo "mounts:"
        for p in "${mounts_paths[@]}"; do echo "  - path: $p"; done
        [[ $docker_socket -eq 1 ]] && echo "docker_socket: true"
        if [[ ${#extras[@]} -gt 0 ]]; then
            echo "extra_mounts:"
            for e in "${extras[@]}"; do echo "  - \"$e\""; done
        fi
        [[ -n "$api_key_file" ]] && echo "anthropic_api_key_file: $api_key_file"
    )"
    fi

    # ---- Preview + approve -------------------------------------------------
    # Nothing has touched disk yet: show the exact file to be written (and the
    # backup that will be taken) and require an explicit yes before applying.
    echo ""
    echo "Planned migration for $dir:"
    echo "  $change_summary"
    echo ""
    echo "  ── source $backup_src ─────────────────────────────────"
    sed 's/^/  │ /' "$backup_src"
    echo "  ───────────────────────────────────────────────────────"
    echo ""
    echo "  ── proposed $config_file ──────────────────────────────"
    printf '%s\n' "$new_content" | sed 's/^/  │ /'
    echo "  ───────────────────────────────────────────────────────"
    if [[ -e "$backup_src.bak" ]]; then
        echo "  backup: $backup_src → $backup_src.bak (overwrites an existing .bak)"
    else
        echo "  backup: $backup_src → $backup_src.bak"
    fi
    local n
    for n in "${notes[@]}"; do echo "  ! $n"; done
    echo ""
    local ans
    printf "Apply this migration? [y/N]: "
    read -r ans
    if [[ "${ans,,}" != "y" ]]; then
        echo "Aborted — nothing written."
        return 0
    fi

    # ---- Apply -------------------------------------------------------------
    cp "$backup_src" "$backup_src.bak"
    printf '%s\n' "$new_content" > "$config_file"
    echo "Wrote $config_file (backup: $backup_src.bak)"
    echo ""
    if [[ $keep_image -eq 1 ]]; then
        echo "Next: run 'cc' from $dir (the image '$legacy_image' must already exist)."
    else
        echo "Next: run 'cc --build' from $dir to assemble and build the modular image."
    fi
}
