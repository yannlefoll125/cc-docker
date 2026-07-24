#!/bin/bash
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: PROJECT_DIR is not set or is not a directory ('$PROJECT_DIR')." >&2
  echo "       Set PROJECT_DIR to the project path (see README)." >&2
  exit 1
fi

echo "PROJECT_DIR=$PROJECT_DIR"

HOST_UID=$(stat -c "%u" "$PROJECT_DIR")
HOST_GID=$(stat -c "%g" "$PROJECT_DIR")

# PROJECT_DIR may not be bind-mounted itself (e.g. only subdirectories are, to
# avoid exposing the whole project). In that case Docker auto-creates it inside
# the container owned by root, so stat reports UID 0. Fall back to the
# always-mounted, host-owned .claude config mounts to recover the real host
# UID/GID.
if [ -z "$HOST_UID" ] || [ "$HOST_UID" = 0 ]; then
  for ref in /home/hostuser/.claude /home/hostuser/.claude.json; do
    [ -e "$ref" ] || continue
    ref_uid=$(stat -c "%u" "$ref")
    ref_gid=$(stat -c "%g" "$ref")
    if [ -n "$ref_uid" ] && [ "$ref_uid" != 0 ]; then
      HOST_UID=$ref_uid
      HOST_GID=$ref_gid
      echo "PROJECT_DIR is root-owned (not bind-mounted); using host UID/GID $HOST_UID:$HOST_GID from $ref"
      break
    fi
  done
fi

if [ -z "$HOST_UID" ] || [ "$HOST_UID" = 0 ]; then
  echo "ERROR: could not determine a non-root host UID from PROJECT_DIR or the .claude mounts." >&2
  echo "       Ensure ~/.claude is bind-mounted, or bind-mount the project directory itself." >&2
  exit 1
fi

getent group "$HOST_GID" >/dev/null || groupadd -g "$HOST_GID" hostgroup
id -u hostuser >/dev/null 2>&1 || useradd -u "$HOST_UID" -g "$HOST_GID" -m hostuser
chown "$HOST_UID:$HOST_GID" /home/hostuser

# Give hostuser ownership of its cwd. Deliberately NON-recursive: a recursive
# chown would descend into bind-mounted subdirectories and rewrite ownership
# of real host files (bind mounts write through to the host). When PROJECT_DIR
# itself isn't mounted, this just lets hostuser create files at the project
# root (container-only, not host-visible). When it is mounted, it's a no-op
# since PROJECT_DIR already has this UID.
chown "$HOST_UID:$HOST_GID" "$PROJECT_DIR"

[ -n "$GIT_USER_NAME" ]  && export GIT_USER_NAME
[ -n "$GIT_USER_EMAIL" ] && export GIT_USER_EMAIL

exec gosu hostuser /run-as-hostuser.sh "$@"