# lxc-netcut

**Simulated network outages for Proxmox LXC containers.**

Lets an agent inside an LXC container ask the Proxmox host to take that container's
network down for a set number of seconds. The host brings the network back up
automatically afterwards. The agent can't run any other command on the host, and it
can't affect any container except its own. The host accepts each container's key
only from that container's own IP addresses.

You install it once per PVE node. After that, each container that should have this
ability gets its own SSH key, registered with `netcut-admin`.

```console
$ ssh pve-netcut 30
CT 1013 network (veth1013i0) going down in 2s for 30s
```

## Contents

- [Requirements](#requirements)
- [How it works](#how-it-works)
- [Logging and auditing](#logging-and-auditing)
- [Files](#files)
- [Setup](#setup)
- [Managing containers](#managing-containers)
- [Usage](#usage)
- [Testing](#testing)
- [Recovery](#recovery)
- [Clusters and migration](#clusters-and-migration)
- [Uninstall](#uninstall)
- [Known limits](#known-limits)

## Requirements

- A Proxmox VE node (uses `pct`, `systemd-run` and `/etc/pve/lxc/`), with root access
- Each registered container has a **static** `ip=` and/or `ip6=` address in its config
- The container can reach the PVE host over SSH without NAT in between

## How it works

```text
agent (in CT <ctid>) ──ssh pve-netcut 30──▶ PVE host (sshd, key locked to one command)
                                              └─ sudo lxc-netcut <ctid> <nets> 30
                                                   └─ systemd-run unit lxc-netcut-<ctid>:
                                                        sleep 2 → ip link set veth<ctid>iN down
                                                        sleep 30
                                                        ExecStopPost → ip link set veth<ctid>iN up
```

- **One key per container.** Each container's public key is a separate line in
  `/home/netcut/.ssh/authorized_keys`. That line includes a `command=` option, which
  fixes the **container ID** and **network interfaces** for that key. The agent only
  sends a number of seconds, so it can't target another container.
- **Key works only from the container's own IPs.** `netcut-admin add` reads the
  container's static `ip=`/`ip6=` addresses from `pct config --current` (the config in
  use, not pending changes) and adds a `from=` option
  to its key line. sshd rejects the key from any other address, so a key copied into
  another container is useless. Containers without a static address are refused.
- **Locked SSH key.** Whatever the client asks to run is ignored. The client's text is
  passed as one argument to `lxc-netcut`, which accepts only an integer from 1 to 600.
  The `restrict` option turns off port forwarding, agent forwarding, X11 and the PTY.
- **Limited user.** `netcut` is a separate account with its password locked. It may run
  only `/usr/local/sbin/lxc-netcut` through sudo. That script checks every argument
  again, including the ones taken from the key line. Root owns both `/home/netcut` and
  `~netcut/.ssh`, so `netcut` can't edit, rename or replace its own restrictions. Its
  shell is `/bin/sh` (dash), which reads no startup files when sshd runs the forced
  command.
- **The network always comes back.** The outage runs in a background systemd unit, so
  it doesn't depend on the agent's SSH session, which the outage itself cuts. The
  command returns at once and the network drops 2 seconds later. `ExecStopPost` brings
  each interface up however the unit ends. `RuntimeMaxSec` stops the unit 30 seconds
  after the requested outage should have ended.
- **One outage per container at a time.** The unit is named `lxc-netcut-<ctid>`, so a
  second request for the same container is rejected. Different containers can be down
  at the same time.
- **Only the host-side veth goes down.** The host side of `netN` is
  `veth<ctid>i<N>`. Taking it down drops the container's link. Nothing in the container
  config changes, so a failure can't leave the network permanently down. This works
  with or without `firewall=1`.

## Logging and auditing

Every step of a request leaves a record in the PVE host's journal: the SSH login, the
exact text the agent sent, the decision, and the outage itself. Changes to which
containers are registered are logged too.

| Event | Logged by | Example entry |
|-------|-----------|---------------|
| Container registered | `netcut-admin` | `CT 1013 registered: nets=all from=192.168.50.13 key=SHA256:Iax6… (by root)` |
| Container removed | `netcut-admin` | `CT 1013 removed (by root)` |
| Key used from an address it isn't allowed from | `sshd` | `Authentication tried for netcut with correct key but not from a permitted host (host=…, ip=…, required=192.168.50.13).` |
| Successful login | `sshd` | `Accepted publickey for netcut from 192.168.50.13 port 34148 ssh2: ED25519 SHA256:Iax6…` |
| Raw request text from the agent | `sudo` | `netcut : … COMMAND=/usr/local/sbin/lxc-netcut 1013 all '30; id'` |
| Request refused | `lxc-netcut` | `CT 1013: refused: usage: <seconds 1-600>` |
| Outage accepted | `lxc-netcut` | `CT 1013: veth1013i0 down for 30s (requested via ssh)` |
| Outage start and end | systemd | `Started lxc-netcut-1013.service …` / `lxc-netcut-1013.service: Deactivated successfully.` |

The `sudo` entry records what the agent actually typed, before any validation, so an
attempt to inject a command shows up word for word even though it was refused.

To review:

```bash
journalctl -t lxc-netcut -t netcut-admin    # requests, refusals and registration changes
journalctl _COMM=sudo | grep lxc-netcut     # raw request text, as the agent sent it
journalctl -u ssh | grep netcut             # logins, and keys used from the wrong address
journalctl -u 'lxc-netcut-*'                # outage units starting and stopping
```

Signs worth checking:

- **`not from a permitted host`**: a registered key is being used from somewhere other
  than its container. The key has probably been copied.
- **A `sudo` command containing anything other than a number** at the end: someone is
  probing the forced command.
- **An `Accepted publickey` for `netcut` with no matching `sudo` entry**: the client
  connected without sending a request. This is what a port-forwarding attempt (`ssh -N
  -L …`) looks like. `restrict` refuses the forward, but sshd doesn't log the refusal at
  its default `LogLevel INFO`.
- **Registrations you didn't make**: `netcut-admin` entries name the admin from
  `SUDO_USER`, or `root`.

> [!NOTE]
> These entries go to the systemd journal. Proxmox VE stores it on disk
> (`/var/log/journal`), so it survives reboots, subject to journald's size limits. To keep
> it longer or off the host, forward it to a central log server.

## Files

| File | Where it runs | Purpose |
|------|---------------|---------|
| [`pve-host/install.sh`](pve-host/install.sh) | Once on each PVE node | Installs both scripts, the `netcut` user, the sudo rule and an empty `authorized_keys` |
| [`pve-host/lxc-netcut`](pve-host/lxc-netcut) | `/usr/local/sbin/` on the node | Root script: checks the input, finds the interfaces and starts the outage unit |
| [`pve-host/netcut-admin`](pve-host/netcut-admin) | `/usr/local/sbin/` on the node | Adds, removes and lists containers in `authorized_keys`, and logs each change |
| [`container/setup-client.sh`](container/setup-client.sh) | Inside each container | Creates the agent's key and the `pve-netcut` SSH alias |

> [!NOTE]
> The longest allowed outage is `MAX=600` seconds, set at the top of `lxc-netcut`.

## Setup

### 1. Install on the PVE host

Once per node, as root. Copy the `pve-host/` directory to the node, then:

```bash
./install.sh
```

Re-running it updates the scripts and keeps the containers already registered.

### 2. Set up the client

In each container, as the agent's user. Copy `container/setup-client.sh` into the
container, then:

```bash
./setup-client.sh <pve-host-ip>            # optional 2nd arg: SSH alias (default pve-netcut)
```

This creates `~/.ssh/pve_netcut` and adds a `pve-netcut` entry at the **top** of
`~/.ssh/config`. ssh uses the first value it finds for each setting, so this keeps an
existing `Host *` block from overriding the alias's `User` or `HostName`. It then prints
the `netcut-admin add` command for step 3.

<details>
<summary>To do this by hand instead</summary>

Create the key:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/pve_netcut -C agent-netcut
```

Then add this block to `~/.ssh/config`, **above** any `Host *` section:

```text
Host pve-netcut
    HostName <pve-host-ip>
    User netcut
    IdentityFile ~/.ssh/pve_netcut
    IdentitiesOnly yes
```

</details>

### 3. Register the container

On the PVE host, as root:

```bash
netcut-admin add <ctid> '<public key from step 2>'          # cut all of the CT's interfaces
netcut-admin add <ctid> '<public key>' 0                    # cut only net0
netcut-admin add <ctid> '<public key>' 0,2                  # cut net0 and net2
netcut-admin add <ctid> /path/to/key.pub                    # read the key from a file
```

`add` reads the container's static addresses from `pct config --current` (all `netN`
interfaces, snapshots and pending changes ignored) and allows the key only from those. The resulting line
looks like this:

```text
from="192.168.50.13",command="sudo -n /usr/local/sbin/lxc-netcut 1013 all \"$SSH_ORIGINAL_COMMAND\"",restrict ssh-ed25519 AAAA... netcut-ct1013
```

`add` refuses if:

- the container doesn't exist on this node
- it has no static `ip=`/`ip6=` (DHCP, SLAAC or `manual`)
- the key isn't a valid public key
- the key is already registered for another container

Running `add` again for the same container replaces its key, interface list and
allowed addresses.

> [!IMPORTANT]
> **If you change a container's IP**, run `netcut-admin add` for it again. Until then,
> its requests are refused (`Permission denied (publickey)`).

### 4. Accept the host key

In the container:

```bash
ssh pve-netcut 1
```

Later calls then won't stop at a host-key prompt.

## Managing containers

```bash
netcut-admin list              # registered containers: interfaces, key fingerprint, allowed IPs
netcut-admin remove <ctid>     # revoke a container's access
```

Example:

```console
$ netcut-admin list
CTID       NETS     KEY                                                  FROM
1013       all      SHA256:sW9Orjmu7yOq382mCoitdlnj8AJsphiZnBDl6SNAr+k   192.168.50.13
205        0        SHA256:nuMyBYwa2IDWABYMV6zv+pLzYVTXfwtszuIfZwdY9ug   192.168.50.205
```

## Usage

From the container:

```bash
ssh pve-netcut <seconds>       # 1-600; the outage starts ~2s after the command returns
```

```console
$ ssh pve-netcut 30
CT 1013 network (veth1013i0) going down in 2s for 30s
```

| Exit code | Meaning |
|-----------|---------|
| `0` | Outage scheduled |
| `1` | An outage is already running for this container, the container isn't running, or it isn't on this node |
| `2` | Invalid duration |

## Testing

From a registered container:

```bash
ssh pve-netcut 20 && ping <gateway-ip>     # replies stop for ~20s, then resume

# all of these should be refused
ssh pve-netcut 'id'
ssh pve-netcut '30; id'
ssh pve-netcut '1013 all 30'               # can't choose another container
ssh pve-netcut 99999
ssh -N -L 8006:localhost:8006 pve-netcut
```

On the PVE host:

```bash
journalctl -t lxc-netcut                   # every request is logged, accepted or refused
systemctl list-units 'lxc-netcut-*'        # outages in progress
```

See [Logging and auditing](#logging-and-auditing) for the full set of log sources.

## Recovery

To end an outage early, on the PVE host:

```bash
systemctl stop lxc-netcut-<ctid>           # ExecStopPost brings the network back up
# or manually:
ip link set veth<ctid>i0 up
```

## Clusters and migration

`lxc-netcut` acts only on containers running on the node it's installed on. In a
cluster, run `install.sh` on every node where a registered container might run. Each
node has its own `authorized_keys`, so register the container on the node it runs
on.

> [!TIP]
> If you migrate a container, run `netcut-admin add` on the new node (and `remove`
> on the old one), and point the container's `HostName` at the new node.

## Uninstall

On each node:

```bash
rm /usr/local/sbin/lxc-netcut /usr/local/sbin/netcut-admin /etc/sudoers.d/netcut
userdel netcut && rm -rf /home/netcut
```

## Known limits

- The `from=` check needs the PVE host to see the container's real address. That's the
  case when the container reaches the host on the same bridge or through plain routing.
  It isn't the case if there's NAT in between.
- Root in another container could take over this container's IP to get past `from=`,
  but it would also need this container's private key. To stop containers from using
  addresses other than their own, enable the Proxmox firewall's **IP filter** option
  for each container (**Container → Firewall → Options → IP filter**).
- An agent can start outages back to back, each up to `MAX` seconds. To limit this,
  add a cooldown to `lxc-netcut`, for example by refusing requests while a
  `/run/lxc-netcut-<ctid>` timestamp is newer than N minutes.
- Anyone with root in a container can read that container's private key. They still
  can only cut and restore that container's network, and only from that container's
  addresses.
- If a container restarts during an outage, Proxmox creates new veth interfaces that
  are up. The scheduled "up" then does nothing.
- With `all`, the interfaces are the ones present when the request arrives. An
  interface hot-added during an outage isn't affected.
