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

# In-sandbox SSH access (ssh: in cc-docker.yml). cc-config publishes the port and
# mounts /cc-ssh/authorized_keys (ro) + /cc-ssh/hostkeys (rw, the project's
# gitignored .cc-docker/ssh/); everything runtime happens here, as root, before
# the privilege drop. sshd lives only as long as this container does.
if [ -n "$CC_SSH" ]; then
  # Host keys persist in the mounted .cc-docker/ssh/ so the sandbox presents one
  # stable host identity across runs (no known_hosts churn on the client).
  # Chowned to the host user so they stay manageable without sudo on the host.
  for type in ed25519 rsa; do
    key="/cc-ssh/hostkeys/ssh_host_${type}_key"
    if [ ! -f "$key" ]; then
      ssh-keygen -q -t "$type" -N "" -f "$key"
      chown "$HOST_UID:$HOST_GID" "$key" "$key.pub"
    fi
  done

  # Debian's default sshd_config Includes this dir at the top, so these settings
  # win over the stock ones. Only hostuser, only pubkey, only the mounted keys.
  cat > /etc/ssh/sshd_config.d/cc-docker.conf <<EOF
AllowUsers hostuser
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile /cc-ssh/authorized_keys
HostKey /cc-ssh/hostkeys/ssh_host_ed25519_key
HostKey /cc-ssh/hostkeys/ssh_host_rsa_key
EOF

  # useradd left the account password-locked ('!'), which PAM rejects even for
  # pubkey logins. '*' means "no password" without the lock semantics.
  usermod -p '*' hostuser

  # SSH sessions don't inherit this entrypoint's environment (image ENV + the
  # compose environment: block), so mirror what they need into /etc/environment —
  # pam_env applies it to every session type, including non-interactive ones.
  # The API key secret is already world-readable inside the container (Docker
  # secrets default to 0444), so copying it here widens nothing.
  {
    printf 'PATH="/opt/cc/bin:%s"\n' "$PATH"
    printf 'PROJECT_DIR="%s"\n' "$PROJECT_DIR"
    [ -n "$GIT_USER_NAME" ]  && printf 'GIT_USER_NAME="%s"\n'  "$GIT_USER_NAME"
    [ -n "$GIT_USER_EMAIL" ] && printf 'GIT_USER_EMAIL="%s"\n' "$GIT_USER_EMAIL"
    [ -n "$CC_PERMISSION_MODE" ] && printf 'CC_PERMISSION_MODE="%s"\n' "$CC_PERMISSION_MODE"
    [ -r /run/secrets/anthropic_api_key ] && \
      printf 'ANTHROPIC_API_KEY="%s"\n' "$(cat /run/secrets/anthropic_api_key)"
  } >> /etc/environment

  # `claude` shim first on the SSH-session PATH: parity with run-as-hostuser.sh
  # (sandbox system prompt + permission mode) for sessions that launch claude.
  mkdir -p /opt/cc/bin
  cat > /opt/cc/bin/claude <<'EOF'
#!/bin/bash
args=()
[ -n "$CC_PERMISSION_MODE" ] && args=(--permission-mode "$CC_PERMISSION_MODE")
# The sandbox prompt is passed for real here — stop the SessionStart context
# hook from injecting it a second time (see run-as-hostuser.sh).
export CC_SANDBOX_PROMPTED=1
exec /usr/local/bin/claude --append-system-prompt "$(cat /sandbox.md)" "${args[@]}" "$@"
EOF
  chmod +x /opt/cc/bin/claude

  mkdir -p /run/sshd  # sshd's privilege-separation dir
  /usr/sbin/sshd -E /var/log/cc-sshd.log
  echo "sshd up — connect with: ssh -p ${CC_SSH_ADDR##*:} hostuser@${CC_SSH_ADDR%:*}"
fi

exec gosu hostuser /run-as-hostuser.sh "$@"