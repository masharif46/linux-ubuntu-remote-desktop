# Linux Remote Desktop Installers for Ubuntu 24.04

One-command, idempotent bash scripts for setting up a secure, persistent remote desktop on Ubuntu 24.04 LTS. Two installers (pick one, or install both) plus an optional hardening helper:

- **`install-xrdp-stable.sh`** — installs **xrdp** (Microsoft RDP protocol). Open source, works with any standard RDP client (`mstsc`, Remmina, FreeRDP, Microsoft Remote Desktop for macOS).
- **`install-nomachine-stable.sh`** — installs **NoMachine** (NX protocol). Best-in-class compression and session-resume reliability over slow or flaky links. Free for personal/non-commercial use.
- **`configure-fail2ban.sh`** — brute-force protection for the SSH side of the stack. Run after either installer. Auto-detects custom SSH ports; whitelist your home IP via env var to be ban-proof.

Both installers share the same hardening posture: **XFCE4** desktop, **localhost-only binding** (SSH tunnel required), **persistent sessions** that survive disconnects, **UFW** locked down, **polkit popups suppressed**. They coexist cleanly on the same host (different ports), so you can A/B them.

If you've ever stared at a blank teal screen, lost all your open terminals after reconnecting, or fought "Authentication required" popups every minute — these scripts fix all of that in one shot.

---

## Which installer should I use?

|  | xrdp | NoMachine |
|---|---|---|
| **Protocol** | Microsoft RDP | NX (NoMachine's own) |
| **License** | Open source (GPL) | Proprietary, free for personal use only |
| **Best for** | Standard RDP clients, mixed-OS teams, open-source-only environments | Slow / flaky / high-latency links |
| **Compression** | Decent | Excellent |
| **Session persistence** | Reattach by policy match — needs tuning to survive resolution changes | Suspend-and-resume always, zero tuning |
| **Resilience to flaky internet** | Good (with `Policy=UB`) | Excellent (built-in) |
| **Windows client** | Built-in `mstsc` | Separate NoMachine client install |
| **Port** | `3389/tcp` | `4000/tcp` |

**TL;DR:**
- Want a standard, open-source RDP setup? → **xrdp**
- Internet drops a lot and you want sessions to *just resume*? → **NoMachine**
- Can't decide? Install both — they coexist on different ports.

---

## Quick Start

### Option A: xrdp

```bash
git clone https://github.com/masharif46/linux-ubuntu-remote-desktop.git
cd linux-ubuntu-remote-desktop
chmod +x install-xrdp-stable.sh
sudo ./install-xrdp-stable.sh
```

### Option B: NoMachine

```bash
git clone https://github.com/masharif46/linux-ubuntu-remote-desktop.git
cd linux-ubuntu-remote-desktop
chmod +x install-nomachine-stable.sh
sudo ./install-nomachine-stable.sh

# If the pinned NoMachine version is stale, override:
sudo NM_VERSION=9.5.7 NM_BUILD=2 ./install-nomachine-stable.sh
# Or pre-download the .deb and pass:
sudo NM_DEB_PATH=/path/to/nomachine_X.Y.Z_N_amd64.deb ./install-nomachine-stable.sh
```

Either script auto-detects your non-root user, installs everything, configures for stability, and prints the exact connection command at the end.

### After install: harden SSH with fail2ban (recommended)

The xrdp/NoMachine servers themselves are localhost-only, so all external attack surface funnels through SSH. Lock it down with the fail2ban helper:

```bash
sudo ./configure-fail2ban.sh

# Optional: whitelist a static home IP so you can't ban yourself by fat-fingering a password.
sudo WHITELIST_IP="YOUR.HOME.IP" ./configure-fail2ban.sh
```

Auto-detects your SSH port (handles non-22 setups), enables the `sshd` and `recidive` jails, and prints lockout-recovery instructions at the end. Idempotent — re-run anytime to rewrite the config.

---

## Requirements

- **OS:** Ubuntu 24.04 LTS (also tested on 22.04)
- **Privileges:** root / sudo
- **At least one non-root user** with UID ≥ 1000 (the script picks the first one it finds, or honors `$SUDO_USER`)
- **SSH access** to the server from your client machine
- **NoMachine only:** outbound internet to `download.nomachine.com` (or use `NM_DEB_PATH=` for offline installs)

---

## Connecting

Both setups follow the same pattern: open an SSH tunnel from your local machine, then point a client at `127.0.0.1`.

### 1. Open an SSH tunnel from your local machine

**For xrdp (port 3389):**
```bash
ssh -L 3389:127.0.0.1:3389 -N -f \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=6 \
    -o TCPKeepAlive=yes \
    -o ExitOnForwardFailure=yes \
    user@your.server.ip
```

**For NoMachine (port 4000):**
```bash
ssh -L 4000:127.0.0.1:4000 -N -f \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=6 \
    -o TCPKeepAlive=yes \
    -o ExitOnForwardFailure=yes \
    user@your.server.ip
```

Or add a unified entry to `~/.ssh/config` once:

```
Host myserver-remote
    HostName your.server.ip
    User youruser
    LocalForward 3389 127.0.0.1:3389
    LocalForward 4000 127.0.0.1:4000
    ServerAliveInterval 30
    ServerAliveCountMax 6
    TCPKeepAlive yes
    ExitOnForwardFailure yes
    Compression yes
```

Then just: `ssh -N -f myserver-remote`

#### Or, with Bitvise SSH Client (Windows GUI)

Bitvise has built-in RDP integration — easier than manual `ssh -L`.

**Easiest path — one-click RDP (xrdp only):**

1. Connect to the server in Bitvise as usual.
2. In the main window, click **"New Remote Desktop"** (right-hand side panel).
3. Bitvise sets up the tunnel and launches `mstsc` automatically.

**Manual path — explicit C2S port forwarding (works for either protocol):**

In the profile, **before** connecting, open the **C2S** tab (Bitvise's term for OpenSSH `-L` local forwarding) and add a row for each port you want to forward:

| Field | xrdp | NoMachine |
|---|---|---|
| Listen Interface | `127.0.0.1` | `127.0.0.1` |
| List. Port | `3389` | `4000` |
| Destination Host | `127.0.0.1` | `127.0.0.1` |
| Dest. Port | `3389` | `4000` |

Connect, then point your client (`mstsc` for RDP, NoMachine client for NX) at `127.0.0.1` on the matching port.

**Keep-alive (recommended either path):**

Under the **Options** tab:
- Keepalive interval: `30` seconds
- Max idle time: `0` (never disconnect)

This is the Bitvise equivalent of `ServerAliveInterval=30 ServerAliveCountMax=6`.

### 2. Point your client at `127.0.0.1`

**For xrdp** — any RDP client at `127.0.0.1:3389`:
- **Linux:** Remmina, FreeRDP (`xfreerdp /v:127.0.0.1`)
- **Windows:** Remote Desktop Connection (`mstsc`)
- **macOS:** Microsoft Remote Desktop

**For NoMachine** — install the NoMachine client from https://www.nomachine.com/download, then create a connection:
- Host: `127.0.0.1`, Port: `4000`, Protocol: NX
- Username: your Linux account, Password: your Linux account password

### 3. (Recommended) Wrap SSH terminals in tmux

To keep your terminal sessions alive even if the desktop dies entirely:

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

## What the Scripts Configure

### Common to both

- **XFCE4** desktop via `~/.xsession` and `~/.xsessionrc`
- **UFW** firewall: SSH allowed from anywhere (auto-detects non-22 ports); remote-desktop port allowed only from `127.0.0.1`
- **dbus-x11**, **policykit**, and other plumbing required for a working session

### xrdp specifics

#### `/etc/xrdp/xrdp.ini`
- Binds to `127.0.0.1:3389` only — no internet exposure
- `crypt_level=high`, TLSv1.2/1.3 only
- All RDP channels enabled (clipboard, sound, drives, RAIL)

#### `/etc/xrdp/sesman.ini` — session persistence
| Setting | Value | Why |
|---|---|---|
| `Policy` | `UB` | Reattach by User + BitsPerPixel only — robust across resolution changes |
| `KillDisconnected` | `false` | Don't kill sessions on disconnect |
| `DisconnectedTimeLimit` | `0` | Never time out disconnected sessions |
| `IdleTimeLimit` | `0` | Never time out idle sessions |
| `MaxSessions` | `50` | Plenty of headroom |

> **Note:** earlier versions used `Policy=UBDI` (the xrdp default). That requires the client's display size to match exactly when reconnecting — but `mstsc` often renegotiates a different resolution after a network drop, so xrdp would spawn a fresh session and leave the old one orphaned. You'd see a clean desktop and assume your session was killed. `Policy=UB` drops the display-size requirement and lets the same user reattach to their existing session. See [commit history](https://github.com/masharif46/linux-ubuntu-remote-desktop/commits/main) for the full rationale.

#### `~/.xsession` and `~/.xsessionrc`
Launch XFCE4 in X11 mode with clean environment variables to avoid the dbus/runtime-dir collisions that cause blank screens.

#### `/etc/xrdp/startwm.sh`
Patched to honor the user's `~/.xsession` instead of falling back to system defaults.

#### `/etc/polkit-1/localauthority/50-local.d/`
Two `.pkla` files that suppress the colord and packagekit authentication popups that appear repeatedly inside RDP sessions.

#### `/etc/gdm3/custom.conf`
`WaylandEnable=false` — required because xrdp needs an Xorg session.

#### UFW (xrdp)
- `3389/tcp` allowed from `127.0.0.1` only
- `3389/tcp` denied from everywhere else

### NoMachine specifics

#### `/usr/NX/etc/server.cfg`
| Setting | Value | Why |
|---|---|---|
| `NXPort` | `4000` | Listen port |
| `EnableNetworkBroadcast` | `0` | Don't advertise the server on the LAN |
| `EnableUDPCommunication` | `0` | TCP-only — NoMachine's UDP transport doesn't survive an SSH tunnel cleanly |

No session-policy tuning needed — NoMachine sessions are **persistent by design**, with suspend-on-disconnect / resume-on-reconnect handled automatically regardless of client IP or resolution. The class of bugs that motivates the xrdp `Policy=UB` fix simply doesn't exist here.

#### `~/.xsession`
Reused from the xrdp script if present, or created fresh. Same XFCE launch script — both servers share one desktop config.

#### UFW (NoMachine)
- `4000/tcp` allowed from `127.0.0.1` only
- `4000/tcp` denied from everywhere else

### fail2ban specifics (optional hardening)

#### `/etc/fail2ban/jail.local`
| Setting | Value | Why |
|---|---|---|
| `bantime` | `1h` | How long a banned IP stays banned |
| `findtime` | `10m` | Window over which failed attempts are counted |
| `maxretry` | `5` | Fails inside `findtime` before triggering a ban |
| `ignoreip` | `127.0.0.1/8 ::1` (+ optional `WHITELIST_IP`) | Never ban localhost; optionally never ban your home IP |
| `backend` | `systemd` | Read auth events from the journal (modern Ubuntu doesn't write `/var/log/auth.log` by default) |

Two jails enabled:

- **`sshd`** — standard SSH brute-force protection on the auto-detected port.
- **`recidive`** — meta-jail that re-bans hosts coming back AFTER an initial ban expires (catches slow-burn campaigns pacing themselves under the per-jail thresholds). 3 re-offenses in 1 day → 1-week ban.

> Why a separate `jail.local` and not `jail.conf`? The package-shipped `/etc/fail2ban/jail.conf` is owned by `apt` and gets overwritten on upgrade. `jail.local` takes precedence and persists. This script always writes `.local`.

NoMachine doesn't get a jail by default — it's localhost-only, so there's nothing to ban. If you ever expose it on a public IP (not recommended), add a custom filter against `/usr/NX/var/log/nxserver.log`.

---

## Troubleshooting

### Blank teal/cyan screen after login (both)
The session connected but XFCE failed to start. Check:
```bash
tail -n 50 ~/.xsession-errors
tail -n 50 ~/.xorgxrdp.*.log              # xrdp only
sudo tail -n 50 /usr/NX/var/log/nxd.log   # NoMachine only
```
Most common cause is a leftover session — terminate and retry:
```bash
loginctl terminate-user $USER
```

### "Authentication required" popups inside the desktop (both)
The polkit rules should prevent this. Verify:
```bash
ls /etc/polkit-1/localauthority/50-local.d/
```
Both `45-allow-colord.pkla` and `46-allow-update-repo.pkla` should be present.

### xrdp: lost terminals / fresh desktop after reconnecting
Two causes:
1. **xrdp made a new session instead of reattaching.** Check that `Policy=UB` is in `/etc/xrdp/sesman.ini`. The current script sets this; older installs used the default `UBDI`, which is fragile. Patch directly:
   ```bash
   sudo sed -i 's/^Policy=.*/Policy=UB/' /etc/xrdp/sesman.ini
   sudo systemctl restart xrdp-sesman xrdp
   ```
   Existing orphaned sessions from before the change won't suddenly become reattachable — reboot, or clean them up with `loginctl list-sessions` + `loginctl terminate-session <id>` before testing.
2. **The terminal emulator died.** Always run remote work inside `tmux` (see Connecting → step 3).

To diagnose whether a "fresh desktop" is really a fresh session or just a missed reattach, SSH in and check for orphans:
```bash
ps -ef | grep -E 'Xorg|xfce4-session' | grep -v grep
ls /tmp/.X11-unix/
```
Two `Xorg` processes / two `X1*` sockets = your old session is alive and orphaned, you're in the Policy case.

### NoMachine: download failed during install
The pinned version may be stale. Find the current release at https://www.nomachine.com/download/linux and re-run:
```bash
sudo NM_VERSION=X.Y.Z NM_BUILD=N ./install-nomachine-stable.sh
```
Or download the `.deb` manually and pass:
```bash
sudo NM_DEB_PATH=/path/to/file.deb ./install-nomachine-stable.sh
```

### xrdp: can't connect — "connection refused"
Verify xrdp is running and listening:
```bash
sudo systemctl status xrdp
ss -tlnp | grep 3389
```
Should show `127.0.0.1:3389`. If listening on `0.0.0.0:3389`, edit `/etc/xrdp/xrdp.ini` and ensure `port=tcp://127.0.0.1:3389`.

### NoMachine: can't connect / nothing listening on 4000
```bash
sudo /etc/NX/nxserver --status
ss -tlnp | grep 4000
```
Restart if needed:
```bash
sudo /etc/NX/nxserver --restart
```

### xrdp: service won't start
```bash
sudo journalctl -u xrdp --no-pager -n 50
sudo journalctl -u xrdp-sesman --no-pager -n 50
```

### fail2ban: I locked myself out
You're whitelisted from `127.0.0.1` (so SSH-tunnel clients are safe), but fresh SSH logins from your public IP still go through the jail. If you ban yourself, use your hosting provider's web/serial console:
```bash
sudo fail2ban-client set sshd unbanip <your-public-ip>
```
To prevent this happening again, re-run the script whitelisting your home IP:
```bash
sudo WHITELIST_IP="YOUR.HOME.IP" ./configure-fail2ban.sh
```

### fail2ban: check current state
```bash
sudo fail2ban-client status               # list active jails
sudo fail2ban-client status sshd          # bans + stats for the sshd jail
sudo fail2ban-client banned               # all currently-banned IPs
sudo tail -f /var/log/fail2ban.log        # live activity
```

### Re-run any of the scripts
All three are idempotent — running again rewrites the relevant config cleanly without breaking adjacent state:
```bash
sudo ./install-xrdp-stable.sh
sudo ./install-nomachine-stable.sh
sudo ./configure-fail2ban.sh
```

---

## Useful Log Locations

### xrdp
| Log | Path |
|---|---|
| xrdp main | `/var/log/xrdp.log` |
| xrdp session manager | `/var/log/xrdp-sesman.log` |
| Xorg session (per session) | `~/.xorgxrdp.*.log` |
| XFCE / user session errors | `~/.xsession-errors` |
| systemd unit | `sudo journalctl -u xrdp` |

### NoMachine
| Log | Path |
|---|---|
| nxserver | `/usr/NX/var/log/nxserver.log` |
| nxd (daemon) | `/usr/NX/var/log/nxd.log` |
| Per-session | `/usr/NX/var/log/nxnode.log` |
| XFCE / user session errors | `~/.xsession-errors` |

### fail2ban
| Log | Path |
|---|---|
| fail2ban activity | `/var/log/fail2ban.log` |
| sshd auth events | `sudo journalctl -u ssh -t sshd` |

---

## Security Notes

- **Both servers bind to localhost only.** They are not exposed to the network. The only path in is via SSH tunnel — RDP/NX get the benefit of SSH's strong authentication and encryption on top of their own crypto.
- **Never expose port 3389 or 4000 to the internet directly.** Both protocols have a history of CVEs and credential-stuffing attacks are constant. Always tunnel.
- **Run `configure-fail2ban.sh`.** Since all external attack surface funnels through SSH, brute-force protection on the SSH side defends every desktop you've installed. SSH is constantly probed on any public IP — fail2ban silently bans the noise.
- **Root login is disabled** for xrdp (`AllowRootLogin=false` in `sesman.ini`). NoMachine uses PAM and inherits whatever your `/etc/pam.d` policy allows — review it.
- **NoMachine is closed-source software.** Free for personal/non-commercial use per [their EULA](https://www.nomachine.com/eula) — verify the license fits your use case before deploying it at work. Use xrdp if you need a pure open-source stack.
- The scripts **do not modify your SSH config** — manage that separately (use SSH keys, disable password auth, change the SSH port, etc.).

---

## What Gets Removed on Reinstall

Each script only touches its own software — running one will NOT remove the other.

### `install-xrdp-stable.sh` purges:
- `xrdp` and `xorgxrdp` packages
- `/etc/xrdp/` directory (all configs)
- `/var/log/xrdp*` logs
- `~/.xorgxrdp.*.log` files for the target user
- Any running xrdp processes and user sessions

### `install-nomachine-stable.sh` purges:
- `nomachine` package
- `/usr/NX/` (binaries) and `/etc/NX/` (config + session database)

### `configure-fail2ban.sh` purges:
- Nothing — it never removes fail2ban. Each run rewrites `/etc/fail2ban/jail.local` with the current settings and restarts the service. Safe to re-run as often as you like (e.g. to update the whitelist).

**Your user data, home directory files, and other installed software are untouched in all cases.**

If you've customized config files, back them up first:
```bash
sudo cp -r /etc/xrdp /etc/xrdp.bak
sudo cp -r /usr/NX/etc /usr/NX/etc.bak
sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak
```

---

## File Structure

```
.
├── install-xrdp-stable.sh        # xrdp installer
├── install-nomachine-stable.sh   # NoMachine installer
├── configure-fail2ban.sh         # SSH brute-force protection (optional but recommended)
├── README.md                     # This file
└── LICENSE                       # MIT
```

---

## Compatibility

| Ubuntu Version | xrdp | NoMachine | fail2ban |
|---|---|---|---|
| 24.04 LTS | ✅ Primary target — fully tested | ✅ Primary target | ✅ Primary target |
| 22.04 LTS | ✅ Works | ✅ Works | ✅ Works |
| 20.04 LTS | ⚠️  Should work but not actively tested | ⚠️  Should work | ⚠️  Should work |
| Debian 12 | ⚠️  Likely works (same package names) | ⚠️  Likely works | ⚠️  Likely works |

For non-Debian distros, the package manager calls (`apt-get`) and config paths will need adjustment. NoMachine also provides RPMs for RHEL/Fedora — different install path entirely. The fail2ban script's `systemd` backend assumes a modern systemd-journal setup; on older non-systemd distros, switch `backend = systemd` to `backend = auto` in `jail.local`.

---

## Contributing

Issues and PRs welcome. Particularly interested in:
- Tested compatibility reports for other Ubuntu / Debian versions
- Polkit rules for other common popup sources
- Multi-user setup improvements
- Sound / clipboard / drive-redirection edge cases
- NoMachine version-bump testing on fresh installs

---

## License

The installer scripts and this documentation are MIT — see [LICENSE](LICENSE) for details.

**Note:** the *software* the scripts install has its own license. xrdp is GPL; NoMachine is proprietary (free for personal/non-commercial use); fail2ban is GPLv2+. The MIT license covers only the bash glue, not the upstream software it installs.

---

## Acknowledgments

This config crystallizes the collective folk wisdom from years of xrdp issue threads on Ask Ubuntu, GitHub, and the xrdp/xrdp mailing list. Particular nods to the maintainers of the [`neutrinolabs/xrdp`](https://github.com/neutrinolabs/xrdp) project, to [NoMachine](https://www.nomachine.com/) for the NX protocol and a generous free personal-use tier, and to the [fail2ban](https://github.com/fail2ban/fail2ban) project for being the quiet workhorse that keeps every public-internet SSH service breathing.
