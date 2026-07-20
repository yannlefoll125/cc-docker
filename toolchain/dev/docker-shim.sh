#!/bin/bash
# docker-shim.sh — installed as /usr/local/bin/docker inside cc-dev, shadowing
# the real docker-ce-cli binary (/usr/bin/docker) via PATH order.
#
# cc-dev talks to the HOST docker daemon over the mounted socket. Containers
# and images it creates would otherwise be indistinguishable, on that host
# daemon, from ones the user starts natively. This shim tags every
# container/image cc-dev creates with a name prefix + label so they can be
# told apart with e.g.:
#   docker ps -a --filter name=^cc-dev
#   docker ps -a --filter label=cc-dev
#   docker images --filter label=cc-dev
#
# `docker compose` isn't handled here — COMPOSE_PROJECT_NAME=cc-dev (set as an
# image ENV) makes compose itself name containers cc-dev-<service>-<n> and
# apply the standard com.docker.compose.project=cc-dev label.
#
# Everything other than `run`/`create`/`build` (ps, images, inspect, compose,
# ...) passes through to real docker completely unchanged.
set -eu

PREFIX="${CC_DEV_ORIGIN:-cc-dev}"

# Resolve the real docker binary, skipping ourselves so we don't recurse.
REAL_DOCKER=""
if [ -x /usr/bin/docker ] && [ "$(readlink -f /usr/bin/docker)" != "$(readlink -f "$0")" ]; then
    REAL_DOCKER=/usr/bin/docker
else
    old_ifs=$IFS
    IFS=:
    for dir in $PATH; do
        candidate="$dir/docker"
        if [ -x "$candidate" ] && [ "$(readlink -f "$candidate")" != "$(readlink -f "$0")" ]; then
            REAL_DOCKER="$candidate"
            break
        fi
    done
    IFS=$old_ifs
fi
if [ -z "$REAL_DOCKER" ]; then
    echo "docker-shim: could not locate the real docker binary" >&2
    exit 1
fi

# Global flags that appear BEFORE the subcommand and take a separate value
# argument (must be skipped as a pair when scanning for the subcommand).
is_global_value_flag() {
    case "$1" in
        -H|--host|--config|-c|--context|-l|--log-level| \
        --tlscacert|--tlscert|--tlskey) return 0 ;;
        *) return 1 ;;
    esac
}

subcmd=""
subcmd_index=0
args=("$@")
n=${#args[@]}
i=0
while [ "$i" -lt "$n" ]; do
    arg="${args[$i]}"
    case "$arg" in
        -*)
            if is_global_value_flag "$arg"; then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
            ;;
        *)
            subcmd="$arg"
            subcmd_index=$i
            break
            ;;
    esac
done

case "$subcmd" in
    run|create)
        has_name=0
        for arg in "$@"; do
            case "$arg" in
                --name|--name=*) has_name=1 ;;
            esac
        done
        id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-8)"
        [ -n "$id" ] || id="$$-$RANDOM"
        extra=(--label "${PREFIX}=1")
        [ "$has_name" -eq 1 ] || extra=(--name "${PREFIX}-${subcmd}-${id}" "${extra[@]}")
        set -- "${args[@]:0:$subcmd_index+1}" "${extra[@]}" "${args[@]:$subcmd_index+1}"
        ;;
    build)
        set -- "${args[@]:0:$subcmd_index+1}" --label "${PREFIX}=1" "${args[@]:$subcmd_index+1}"
        ;;
    *)
        : # pass through unchanged (includes `compose`, ps, images, ...)
        ;;
esac

exec "$REAL_DOCKER" "$@"
