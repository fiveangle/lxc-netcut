#!/bin/bash
# Run inside the container, as the agent's user: ./setup-client.sh <pve-host> [ssh-alias]
# Creates the agent's key and an ssh alias, then prints the command to run on the host.
set -euo pipefail

HOST=${1:?usage: $0 <pve-host> [ssh-alias]}
ALIAS=${2:-pve-netcut}
KEY=$HOME/.ssh/pve_netcut

install -d -m 0700 "$HOME/.ssh"
[[ -f $KEY ]] || ssh-keygen -q -t ed25519 -N '' -f "$KEY" -C "agent-netcut@$(hostname)"

# ssh uses the first value it finds, so the alias goes at the top, ahead of any "Host *"
if ! grep -qE "^Host $ALIAS\$" "$HOME/.ssh/config" 2>/dev/null; then
  tmp=$(mktemp "$HOME/.ssh/config.XXXXXX")
  {
    printf 'Host %s\n    HostName %s\n    User netcut\n    IdentityFile %s\n    IdentitiesOnly yes\n\n' \
      "$ALIAS" "$HOST" "$KEY"
    cat "$HOME/.ssh/config" 2>/dev/null || true
  } > "$tmp"
  # Write in place rather than mv, so a symlinked config stays a symlink
  cat "$tmp" > "$HOME/.ssh/config"
  rm -f "$tmp"
  chmod 0600 "$HOME/.ssh/config"
fi

echo "On the PVE host, as root, run (replace <ctid> with this container's ID):"
echo "  netcut-admin add <ctid> '$(cat "$KEY.pub")'"
echo
echo "Then accept the host key from here once:  ssh $ALIAS 1"
