#!/bin/bash
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: PROJECT_DIR is not set or is not a directory ('$PROJECT_DIR')." >&2
  echo "       Set PROJECT_DIR to the project path (see README)." >&2
  exit 1
fi

echo "PROJECT_DIR=$PROJECT_DIR"

# Determine the host user's UID/GID so we can run as them (files created in bind
# mounts must be host-owned). The `cc` launcher forwards these as CC_HOST_UID/GID
# (generate-compose.py); prefer them — they're independent of any mount. This
# matters now that ~/.claude is a Docker volume (root-owned on first mount), so
# the old "stat the .claude bind to recover the host UID" trick no longer works.
# Fall back to stat-ing PROJECT_DIR for the case where it's bind-mounted and
# someone runs `docker compose` by hand without CC_HOST_UID.
if [ -n "$CC_HOST_UID" ] && [ "$CC_HOST_UID" != 0 ]; then
  HOST_UID=$CC_HOST_UID
  HOST_GID=$CC_HOST_GID
else
  HOST_UID=$(stat -c "%u" "$PROJECT_DIR")
  HOST_GID=$(stat -c "%g" "$PROJECT_DIR")
fi

if [ -z "$HOST_UID" ] || [ "$HOST_UID" = 0 ]; then
  echo "ERROR: could not determine a non-root host UID." >&2
  echo "       Run via the 'cc' launcher (it forwards CC_HOST_UID/CC_HOST_GID)," >&2
  echo "       or bind-mount the project directory itself." >&2
  exit 1
fi

getent group "$HOST_GID" >/dev/null || groupadd -g "$HOST_GID" hostgroup
id -u hostuser >/dev/null 2>&1 || useradd -u "$HOST_UID" -g "$HOST_GID" -m hostuser
chown "$HOST_UID:$HOST_GID" /home/hostuser

# ~/.claude is a per-project Docker volume, root-owned root:root on first mount.
# Hand its mountpoint to hostuser so claude can write its config/transcripts.
# Non-recursive: on later runs the contents are already hostuser-owned (the volume
# persists), and hostuser creates everything beneath the mountpoint itself.
chown "$HOST_UID:$HOST_GID" /home/hostuser/.claude

# Give hostuser ownership of its cwd. Deliberately NON-recursive: a recursive
# chown would descend into bind-mounted subdirectories and rewrite ownership
# of real host files (bind mounts write through to the host). When PROJECT_DIR
# itself isn't mounted, this just lets hostuser create files at the project
# root (container-only, not host-visible). When it is mounted, it's a no-op
# since PROJECT_DIR already has this UID.
chown "$HOST_UID:$HOST_GID" "$PROJECT_DIR"


# Docker socket (docker_socket: true in cc-docker.yml mounts it in, root-owned
# on the host). Add hostuser to the group that owns it so it can actually use
# the mount — gosu resolves supplementary groups by name at drop time below,
# so adding hostuser to the group here (it already exists, unlike dev-wrapper.sh's
# equivalent step) takes effect.
if [ -S /var/run/docker.sock ]; then
  sock_gid=$(stat -c "%g" /var/run/docker.sock)
  if [ "$sock_gid" != 0 ]; then
    grp=$(getent group "$sock_gid" | cut -d: -f1)
    if [ -z "$grp" ]; then
      groupadd -g "$sock_gid" dockerhost
      grp=dockerhost
    fi
    usermod -aG "$grp" hostuser
  fi
fi

[ -n "$GIT_USER_NAME" ]  && export GIT_USER_NAME
[ -n "$GIT_USER_EMAIL" ] && export GIT_USER_EMAIL

exec gosu hostuser /run-as-hostuser.sh "$@"