#!/bin/bash
# cc-dev root phase: (1) refuse to run outside the cc-docker repo, (2) grant the
# (soon-to-be-created) hostuser access to the mounted docker socket, (3) hand
# off to the base entrypoint with a cleanup hook, then run it.

# (1) Sentinel guard — cc-dev is restricted to the cc-docker repo. It grants
# host-daemon (root-equivalent) access via the docker socket, so it must not be
# usable against arbitrary projects even if someone points a compose file at
# this image manually.
if [ -z "$PROJECT_DIR" ] || [ ! -f "$PROJECT_DIR/.cc-docker-dev" ]; then
  echo "ERROR: cc-dev is restricted to the cc-docker repo (missing $PROJECT_DIR/.cc-docker-dev)." >&2
  echo "       cc-dev grants host-daemon (root-equivalent) access and must not run elsewhere." >&2
  exit 1
fi

# (2) Docker socket group. hostuser doesn't exist yet — cc-wrapper.sh (below)
# creates it and immediately drops to it via gosu, so there is no post-useradd
# hook to add hostuser to a supplementary group. Instead, pre-seed the group's
# member list in /etc/group by username before hostuser exists: gosu resolves
# supplementary groups by name at drop time, so this still takes effect.
if [ -S /var/run/docker.sock ]; then
  sock_gid=$(stat -c %g /var/run/docker.sock)
  if [ "$sock_gid" != 0 ]; then
    grp=$(getent group "$sock_gid" | cut -d: -f1)
    if [ -z "$grp" ]; then
      groupadd -g "$sock_gid" dockerhost
      grp=dockerhost
    fi
    if ! getent group "$grp" | grep -qw hostuser; then
      members=$(getent group "$grp" | cut -d: -f4)
      if [ -n "$members" ]; then
        sed -i -E "s/^($grp:[^:]*:[0-9]+:)(.*)$/\1\2,hostuser/" /etc/group
      else
        sed -i -E "s/^($grp:[^:]*:[0-9]+:)(.*)$/\1hostuser/" /etc/group
      fi
    fi
  fi
fi

# (3) Shutdown hook — stop any leftover cc-dev=1 containers (created via the
# docker-shim on the mounted host socket) when this session ends. This must
# run here rather than further down the chain: every step below this one uses
# `exec`, so this is the last process instance that's actually still *this*
# script by the time the session ends — traps set before an exec are
# discarded along with the replaced process image. Not `exec`ing here also
# keeps this the container's real PID 1.
#
# The child runs in the background, with an explicit `wait`, rather than as a
# plain foreground command: bash defers a pending trap until a foreground
# command completes, so `docker stop`'s SIGTERM would otherwise sit unhandled
# until cc-wrapper.sh's whole chain (claude included) exits on its own. `wait`
# is interruptible, so forwarding the signal to the child from the trap and
# waiting on it gets cleanup to run promptly instead.
cleanup() {
  ids=$(docker ps -q --filter label=cc-dev 2>/dev/null)
  [ -n "$ids" ] && docker stop $ids >/dev/null 2>&1
}
trap cleanup EXIT

child=""
forward_signal() {
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
}
trap forward_signal INT TERM

/cc-wrapper.sh "$@" &
child=$!
wait "$child"
exit $?
