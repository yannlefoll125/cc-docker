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
    printf "  docker compose -f %s/docker-compose.yml run --rm cc\n" "$target_dir"
}
