# xrdp Stable Installer for Ubuntu 24.04

A one-command, idempotent bash script that installs and configures **xrdp** with battle-tested settings on Ubuntu 24.04 LTS. Designed for use behind an **SSH tunnel** (localhost-only binding), with **XFCE4** as the desktop environment and **persistent sessions** that survive disconnects.

If you've ever stared at a blank teal screen, lost all your open terminals after reconnecting, or fought "Authentication required" popups every minute — this script fixes all of that in one shot.

---

## Features

- **Clean reinstall** — purges any existing xrdp config before installing
- **XFCE4 desktop** — lightweight, stable, and well-behaved over RDP (unlike GNOME)
- **Session persistence** — reconnect to your existing session instead of getting a fresh one
- **Localhost-only binding** — xrdp listens on `127.0.0.1:3389`; access only via SSH tunnel
- **Wayland disabled** — xrdp requires Xorg
- **Polkit popups suppressed** — no more colord auth dialogs inside RDP
- **UFW configured** — port 3389 firewalled to localhost
- **Idempotent** — safe to run multiple times; always converges to a clean config
- **tmux installed** — for keeping terminals alive across RDP disconnects

---

## Quick Start

```bash
# Clone or download
git clone https://github.com/masharif46/linux-ubuntu-remote-desktop.git
cd linux-ubuntu-remote-desktop

# Make executable and run
chmod +x install-xrdp-stable.sh
sudo ./install-xrdp-stable.sh
```

The script auto-detects your non-root user, installs everything, configures xrdp for stability, and prints the exact connection command at the end.

---

## Requirements

- **OS:** Ubuntu 24.04 LTS (also tested on 22.04)
- **Privileges:** root / sudo
- **At least one non-root user** with UID ≥ 1000 (the script picks the first one it finds, or honors `$SUDO_USER`)
- **SSH access** to the server from your client machine

---

## Connecting

After the script finishes, it prints connection instructions. The standard workflow:

### 1. Open an SSH tunnel from your local machine

```bash
ssh -L 3389:127.0.0.1:3389 -N -f \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=6 \
    -o TCPKeepAlive=yes \
    -o ExitOnForwardFailure=yes \
    user@your.server.ip
```

Or add it to `~/.ssh/config` once:

```
Host myserver-rdp
    HostName your.server.ip
    User youruser
    LocalForward 3389 127.0.0.1:3389
    ServerAliveInterval 30
    ServerAliveCountMax 6
    TCPKeepAlive yes
    ExitOnForwardFailure yes
    Compression yes
```

Then just: `ssh -N -f myserver-rdp`

#### Or, with Bitvise SSH Client (Windows GUI)

Bitvise has built-in RDP integration — easier than manual `ssh -L`.

**Easiest path — one-click RDP:**

1. Connect to the server in Bitvise as usual.
2. In the main window, click **"New Remote Desktop"** (right-hand side panel).
3. Bitvise sets up the tunnel and launches `mstsc` automatically.

**Manual path — explicit C2S port forwarding:**

In the profile, **before** connecting, open the **C2S** tab (Bitvise's term for OpenSSH `-L` local forwarding) and add:

| Field | Value |
|---|---|
| Listen Interface | `127.0.0.1` |
| List. Port | `3389` |
| Destination Host | `127.0.0.1` |
| Dest. Port | `3389` |

Connect, then point any RDP client (`mstsc`, Remmina, etc.) at `127.0.0.1:3389`.

**Keep-alive (recommended either path):**

Under the **Options** tab:
- Keepalive interval: `30` seconds
- Max idle time: `0` (never disconnect)

This is the Bitvise equivalent of `ServerAliveInterval=30 ServerAliveCountMax=6`.

### 2. Point your RDP client to `127.0.0.1:3389`

Works with:
- **Linux:** Remmina, FreeRDP (`xfreerdp /v:127.0.0.1`)
- **Windows:** Remote Desktop Connection (`mstsc`)
- **macOS:** Microsoft Remote Desktop

### 3. (Recommended) Wrap SSH terminals in tmux

To keep your terminal sessions alive even if the RDP desktop crashes:

```bash
ssh user@host -t tmux new -A -s main
```

Useful tmux keys:
- `Ctrl+b d` — detach (session keeps running on the server)
- `Ctrl+b c` — new window
- `Ctrl+b n` / `p` — next / previous window
- `Ctrl+b %` — split vertically
- `Ctrl+b "` — split horizontally

---

## What the Script Configures

### `/etc/xrdp/xrdp.ini`
- Binds to `127.0.0.1:3389` only — no internet exposure
- `crypt_level=high`, TLSv1.2/1.3 only
- All RDP channels enabled (clipboard, sound, drives, RAIL)

### `/etc/xrdp/sesman.ini` — session persistence
| Setting | Value | Why |
|---|---|---|
| `Policy` | `UBDI` | Reconnect by User+BPP+Display+IP — keeps your existing session |
| `KillDisconnected` | `false` | Don't kill sessions on disconnect |
| `DisconnectedTimeLimit` | `0` | Never time out disconnected sessions |
| `IdleTimeLimit` | `0` | Never time out idle sessions |
| `MaxSessions` | `50` | Plenty of headroom |

### `~/.xsession` and `~/.xsessionrc`
Set up to launch XFCE4 in X11 mode, with clean environment variables to avoid the dbus/runtime-dir collisions that cause blank screens.

### `/etc/xrdp/startwm.sh`
Patched to honor the user's `~/.xsession` instead of falling back to system defaults.

### `/etc/polkit-1/localauthority/50-local.d/`
Two `.pkla` files that suppress the colord and packagekit authentication popups that appear repeatedly inside RDP sessions.

### `/etc/gdm3/custom.conf`
`WaylandEnable=false` — required because xrdp needs an Xorg session.

### UFW
- `3389/tcp` allowed from `127.0.0.1` only
- `3389/tcp` denied from everywhere else

---

## Troubleshooting

### Blank teal/cyan screen after login
The session connected but XFCE failed to start. Check:
```bash
tail -n 50 ~/.xsession-errors
tail -n 50 ~/.xorgxrdp.*.log
```
Most common cause is leftover session — terminate and retry:
```bash
loginctl terminate-user $USER
```

### "Authentication required" popups inside RDP
The polkit rules should prevent this. If you still see them, verify:
```bash
ls /etc/polkit-1/localauthority/50-local.d/
```
Both `45-allow-colord.pkla` and `46-allow-update-repo.pkla` should be present.

### Lost terminals after reconnecting
Two causes:
1. xrdp made a new session instead of reconnecting — check that `Policy=UBDI` is in `/etc/xrdp/sesman.ini`. If your client IP changes between connections, switch to `Policy=UBD`.
2. The terminal emulator died — always run remote work inside `tmux`.

### Can't connect — "connection refused"
Verify xrdp is running and listening:
```bash
sudo systemctl status xrdp
ss -tlnp | grep 3389
```
Should show `127.0.0.1:3389`. If listening on `0.0.0.0:3389`, edit `/etc/xrdp/xrdp.ini` and ensure `port=tcp://127.0.0.1:3389`.

### Service won't start
```bash
sudo journalctl -u xrdp --no-pager -n 50
sudo journalctl -u xrdp-sesman --no-pager -n 50
```

### Re-run the installer
The script is idempotent — running it again purges and rebuilds the config cleanly:
```bash
sudo ./install-xrdp-stable.sh
```

---

## Useful Log Locations

| Log | Path |
|---|---|
| xrdp main | `/var/log/xrdp.log` |
| xrdp session manager | `/var/log/xrdp-sesman.log` |
| Xorg session (per session) | `~/.xorgxrdp.*.log` |
| XFCE / user session errors | `~/.xsession-errors` |
| systemd unit | `sudo journalctl -u xrdp` |

---

## Security Notes

- **xrdp is bound to localhost only.** It is not exposed to the network. The only way in is via SSH tunnel, which means RDP gets the benefit of SSH's strong authentication and encryption on top of its own TLS.
- **Never expose port 3389 to the internet directly.** xrdp has had its share of CVEs and credential-stuffing attacks are constant. Always tunnel.
- **Root login is disabled** in `sesman.ini` (`AllowRootLogin=false`).
- The script **does not modify your SSH config** — manage that separately (use SSH keys, disable password auth, change the SSH port, etc.).

---

## What Gets Removed on Reinstall

When re-running the script, the following are purged and recreated:
- `xrdp` and `xorgxrdp` packages
- `/etc/xrdp/` directory (all configs)
- `/var/log/xrdp*` logs
- `~/.xorgxrdp.*.log` files for the target user
- Any running xrdp processes and user sessions

**Your user data, home directory files, and other installed software are untouched.**

If you've customized `/etc/xrdp/*.ini`, back it up first:
```bash
sudo cp -r /etc/xrdp /etc/xrdp.bak
```

---

## File Structure

```
.
├── install-xrdp-stable.sh    # The main installer script
├── README.md                 # This file
└── LICENSE                   # MIT
```

---

## Compatibility

| Ubuntu Version | Status |
|---|---|
| 24.04 LTS | ✅ Primary target — fully tested |
| 22.04 LTS | ✅ Works |
| 20.04 LTS | ⚠️  Should work but not actively tested |
| Debian 12  | ⚠️  Likely works (same package names) |

For non-Debian distros, the package manager calls (`apt-get`) and config paths will need adjustment.

---

## Contributing

Issues and PRs welcome. Particularly interested in:
- Tested compatibility reports for other Ubuntu / Debian versions
- Polkit rules for other common popup sources
- Multi-user setup improvements
- Sound/clipboard/drive-redirection edge cases

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

## Acknowledgments

This config crystallizes the collective folk wisdom from years of xrdp issue threads on Ask Ubuntu, GitHub, and the xrdp/xrdp mailing list. Particular nods to the maintainers of the `neutrinolabs/xrdp` project.
