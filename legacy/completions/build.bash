# Bash tab-completion for build.sh
#
# Loaded automatically when direnv is active (via .envrc).
# Can also be sourced manually:
#   source ./completions/build.bash
#
# Works regardless of CWD; image list is derived live from images/*/Dockerfile.

_build_sh_complete() {
  [[ $COMP_CWORD -ne 1 ]] && return

  local cur="${COMP_WORDS[COMP_CWORD]}"
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local names=""
  for df in "$dir"/images/*/Dockerfile; do
    [[ -f "$df" ]] || continue
    names="$names $(basename "$(dirname "$df")")"
  done

  # shellcheck disable=SC2207
  COMPREPLY=($(compgen -W "$names" -- "$cur"))
}

complete -F _build_sh_complete build.sh ./build.sh
