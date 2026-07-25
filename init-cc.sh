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
        # Assemble the per-project Dockerfile, build its blocks, then the final image.
        # Legacy `image:` configs leave no assembled.tag, so this whole block is skipped.
        if [[ -f "$target_dir/assembled.tag" ]]; then
            local tag; tag="$(cat "$target_dir/assembled.tag")"
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
        fi
    elif [[ ! -f "$compose_file" ]]; then
        echo "Error: no cc-docker.yml or docker-compose.yml found in $target_dir." >&2
        echo "Run init-cc to set one up." >&2
        return 1
    fi

    docker compose -f "$compose_file" run --rm cc "$@"
}
