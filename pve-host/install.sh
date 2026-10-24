#!/bin/bash
# Run once on each PVE node, as root: ./install.sh
# Safe to re-run; it upgrades the scripts and keeps registered containers.
set -euo pipefail
cd "$(dirname "$0")"

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

install -o root -g root -m 0755 lxc-netcut /usr/local/sbin/lxc-netcut
install -o root -g root -m 0755 netcut-admin /usr/local/sbin/netcut-admin

# dash reads no rc files for non-interactive shells, so the forced command runs as written
id netcut >/dev/null 2>&1 || useradd -m -s /bin/sh netcut
usermod -s /bin/sh netcut
passwd -l netcut >/dev/null

echo 'netcut ALL=(root) NOPASSWD: /usr/local/sbin/lxc-netcut' > /etc/sudoers.d/netcut
chmod 0440 /etc/sudoers.d/netcut
visudo -c -q

# Root owns ~ and ~/.ssh so netcut can't edit, rename or replace its own restrictions
install -d -o root -g root -m 0755 /home/netcut /home/netcut/.ssh
[[ -f /home/netcut/.ssh/authorized_keys ]] || install -o root -g root -m 0644 /dev/null /home/netcut/.ssh/authorized_keys

echo "installed. Register a container with:"
echo "  netcut-admin add <ctid> '<ssh public key>'"
