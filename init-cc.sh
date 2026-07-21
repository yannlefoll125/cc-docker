init-cc() {
    if [[ -z "${CC_DOCKER_DIR:-}" ]]; then
        echo "Error: CC_DOCKER_DIR is not set." >&2
        echo "Add to your .bashrc:" >&2
        echo "  export CC_DOCKER_DIR=/path/to/cc-docker" >&2
        echo "  source \"\$CC_DOCKER_DIR/init-cc.sh\"" >&2
        return 1
    fi

    local images=()
    for d in "$CC_DOCKER_DIR/images/"/*/; do
        [[ -f "$d/Dockerfile" ]] || continue
        images+=("$(basename "$d")")
    done
    if [[ ${#images[@]} -eq 0 ]]; then
        echo "Error: no images found in $CC_DOCKER_DIR/images/" >&2
        return 1
    fi

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
    echo "Available images:"
    local i=1
    for img in "${images[@]}"; do
        printf "  %d) cc-%s\n" "$i" "$img"
        ((i++))
    done
    local default_choice=1
    printf "Choose image [%d]: " "$default_choice"
    read -r choice
    choice="${choice:-$default_choice}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#images[@]} )); then
        echo "Error: invalid choice" >&2
        return 1
    fi
    local chosen_image="cc-${images[$((choice-1))]}"

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
    echo "Configuration type:"
    echo "  1) cc-docker native config (cc-docker.yml) — recommended"
    echo "  2) raw docker-compose.yml (hand-written)"
    local default_config_choice=1
    printf "Choose configuration type [%d]: " "$default_config_choice"
    read -r config_choice
    config_choice="${config_choice:-$default_config_choice}"
    local config_type
    case "$config_choice" in
        1) config_type="native" ;;
        2) config_type="raw" ;;
        *) echo "Error: invalid choice" >&2; return 1 ;;
    esac

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

    if [[ "$config_type" == "native" ]]; then
        cat > "$target_dir/cc-docker.yml" <<EOF
image: ${chosen_image}
git:
  name: ${git_name}
  email: ${git_email}
mounts:
  - path: .
EOF
    else
        cat > "$target_dir/docker-compose.yml" <<EOF
services:
  cc:
    hostname: cc
    image: ${chosen_image}
    stdin_open: true
    tty: true
    environment:
      GIT_USER_NAME: \${GIT_USER_NAME:-}
      GIT_USER_EMAIL: \${GIT_USER_EMAIL:-}
      PROJECT_DIR: \${PWD}
    working_dir: \${PWD}
    volumes:
      - \${PWD}:\${PWD}
      - ~/.claude:/home/hostuser/.claude
      - ~/.claude.json:/home/hostuser/.claude.json
EOF

        cat > "$target_dir/.env" <<EOF
GIT_USER_NAME=${git_name}
GIT_USER_EMAIL=${git_email}
EOF
    fi

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
        if [[ ! -f "$compose_file" || "$config_file" -nt "$compose_file" ]]; then
            docker run --rm \
                -e PROJECT_DIR="$dir" \
                -v "$dir":/project:ro \
                -v "$target_dir":/out \
                cc-config || return 1
        fi
    elif [[ ! -f "$compose_file" ]]; then
        echo "Error: no cc-docker.yml or docker-compose.yml found in $target_dir." >&2
        echo "Run init-cc to set one up." >&2
        return 1
    fi

    docker compose -f "$compose_file" run --rm cc "$@"
}
