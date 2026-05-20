#!/usr/bin/env bash
#==============================================================================
# NoMachine (NX) Server Install & Configuration Script
# Target: Ubuntu 24.04 LTS
# Desktop: XFCE4 (same DE as install-xrdp-stable.sh)
# Security: Localhost-only (SSH tunnel required)
#
# Designed to COEXIST with install-xrdp-stable.sh on the same host:
#   - xrdp listens on tcp/3389, NoMachine on tcp/4000
#   - This script does NOT touch xrdp config, services, or firewall rules
#   - Both reuse the same XFCE session via ~/.xsession
#
# NoMachine sessions are persistent by design -- a disconnected session is
# suspended (not killed) and resumes automatically on reconnect, regardless of
# resolution or client IP. So this script is much smaller than the xrdp one:
# no Policy tuning, no KillDisconnected knobs, no reconnect-script wiring.
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Configuration -- override via env vars if the pinned version is stale
#------------------------------------------------------------------------------
# Find the current release at https://www.nomachine.com/download/linux
# Then re-run with:  sudo NM_VERSION=X.Y.Z NM_BUILD=N ./install-nomachine-stable.sh
# Or pre-download the .deb and pass:  sudo NM_DEB_PATH=/path/to/file.deb ...
NM_VERSION="${NM_VERSION:-9.5.7}"
NM_BUILD="${NM_BUILD:-2}"
NM_PORT="${NM_PORT:-4000}"

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*"; }
die()  { err "$*"; exit 1; }

#------------------------------------------------------------------------------
# Pre-flight checks
#------------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

if ! grep -qi "ubuntu" /etc/os-release; then
    warn "This script is designed for Ubuntu. Proceeding anyway..."
fi

# NoMachine ships native packages for x86_64 and arm64 only.
case "$(uname -m)" in
    x86_64)  NM_ARCH="amd64" ;;
    aarch64) NM_ARCH="arm64" ;;
    *)       die "Unsupported architecture: $(uname -m). NoMachine supports amd64 and arm64." ;;
esac
ok "Architecture: $NM_ARCH"

# Detect the non-root user (same logic as install-xrdp-stable.sh)
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
fi
[[ -n "$TARGET_USER" ]] || die "Could not detect a non-root user. Create one first."
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
ok "Target user for NoMachine: $TARGET_USER ($TARGET_HOME)"

#------------------------------------------------------------------------------
# 1. Stop and remove any existing NoMachine
#------------------------------------------------------------------------------
log "Stopping any existing NoMachine..."
if [[ -x /etc/NX/nxserver ]]; then
    /etc/NX/nxserver --shutdown >/dev/null 2>&1 || true
fi
systemctl stop nxserver 2>/dev/null || true
apt-get remove --purge -y nomachine 2>/dev/null || true
# /usr/NX holds the binaries; /etc/NX is config + session DB. We wipe both for
# a clean reinstall -- if you have live NoMachine sessions you care about, do
# NOT re-run this script.
rm -rf /usr/NX /etc/NX 2>/dev/null || true
ok "Old NoMachine removed (if present)"

#------------------------------------------------------------------------------
# 2. Install dependencies
#------------------------------------------------------------------------------
log "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
    curl \
    cups \
    dbus-x11 \
    xfce4 \
    xfce4-goodies \
    xfce4-terminal \
    ufw
ok "Dependencies installed"

#------------------------------------------------------------------------------
# 3. Obtain the NoMachine .deb
#------------------------------------------------------------------------------
# NoMachine has no apt repo -- we fetch the .deb directly. URL pattern is
# stable; only the version/build numbers change between releases.
NM_MAJOR_MINOR="${NM_VERSION%.*}"
NM_DEB_NAME="nomachine_${NM_VERSION}_${NM_BUILD}_${NM_ARCH}.deb"
NM_URL="https://download.nomachine.com/download/${NM_MAJOR_MINOR}/Linux/${NM_DEB_NAME}"

if [[ -n "${NM_DEB_PATH:-}" ]]; then
    [[ -f "$NM_DEB_PATH" ]] || die "NM_DEB_PATH=$NM_DEB_PATH not found"
    TMP_DEB="$NM_DEB_PATH"
    ok "Using pre-downloaded .deb: $TMP_DEB"
else
    log "Downloading NoMachine ${NM_VERSION} (${NM_ARCH})..."
    log "  URL: $NM_URL"
    TMP_DEB="/tmp/$NM_DEB_NAME"
    if ! curl -fsSL -o "$TMP_DEB" "$NM_URL"; then
        err "Download failed. Possible reasons:"
        err "  - NM_VERSION=${NM_VERSION} NM_BUILD=${NM_BUILD} is wrong or no longer hosted"
        err "  - No outbound internet from this host"
        err ""
        err "Find the current version at https://www.nomachine.com/download/linux"
        err "Then re-run with:"
        err "    sudo NM_VERSION=X.Y.Z NM_BUILD=N $0"
        err "Or download the .deb manually and re-run with:"
        err "    sudo NM_DEB_PATH=/path/to/file.deb $0"
        die "Aborting."
    fi
    ok "Downloaded: $TMP_DEB ($(du -h "$TMP_DEB" | cut -f1))"
fi

# curl -f only catches HTTP errors. If NoMachine's CDN returns 200 with an
# HTML error page (e.g. the pinned version was retired), the file we just
# wrote is HTML -- apt-get would later fail with "Invalid archive signature"
# leaving the install half-done. Catch it here with a real Debian-package
# header check so the error message points at the actual cause.
log "Validating downloaded package..."
if ! dpkg-deb -I "$TMP_DEB" >/dev/null 2>&1; then
    err "Downloaded file is NOT a valid Debian package."
    err "  Size: $(du -h "$TMP_DEB" | cut -f1) (expected ~60-80 MB)"
    err ""
    err "Most likely NM_VERSION=${NM_VERSION} NM_BUILD=${NM_BUILD} is no longer"
    err "hosted by NoMachine and the URL returned an HTML error page."
    err ""
    err "Find the current version at https://www.nomachine.com/download/linux"
    err "Then re-run with:"
    err "    sudo NM_VERSION=X.Y.Z NM_BUILD=N $0"
    err "Or download the .deb manually and re-run with:"
    err "    sudo NM_DEB_PATH=/path/to/file.deb $0"
    [[ -z "${NM_DEB_PATH:-}" ]] && rm -f "$TMP_DEB"
    die "Aborting."
fi
ok "Package signature valid"

#------------------------------------------------------------------------------
# 4. Install NoMachine
#------------------------------------------------------------------------------
log "Installing NoMachine package..."
apt-get install -y "$TMP_DEB"
# Only clean up the .deb if WE downloaded it -- don't delete a user-provided file.
[[ -z "${NM_DEB_PATH:-}" ]] && rm -f "$TMP_DEB"
ok "NoMachine installed at /usr/NX"

#------------------------------------------------------------------------------
# 5. Configure NoMachine for localhost-only access
#------------------------------------------------------------------------------
# NoMachine listens on all interfaces by default and broadcasts itself on the
# LAN. We tighten both: bind nothing wider than loopback (enforced via UFW
# below) and disable LAN broadcast. Matches the xrdp script's threat model --
# the only path in is via SSH tunnel.
log "Configuring NoMachine for localhost-only access..."
SERVER_CFG="/usr/NX/etc/server.cfg"
[[ -f "$SERVER_CFG" ]] || die "Expected config not found: $SERVER_CFG -- install may have failed."

# Helper: set-or-append a key in NoMachine's "KEY VALUE" .cfg format.
# Handles three states: present-and-set, present-but-commented, missing.
nm_set_cfg() {
    local file="$1" key="$2" value="$3"
    if grep -qE "^\s*${key}\s+" "$file"; then
        sed -i "s|^\s*${key}\s\+.*|${key} ${value}|" "$file"
    elif grep -qE "^\s*#\s*${key}\s+" "$file"; then
        sed -i "s|^\s*#\s*${key}\s\+.*|${key} ${value}|" "$file"
    else
        echo "${key} ${value}" >> "$file"
    fi
}

nm_set_cfg "$SERVER_CFG" "NXPort"                 "$NM_PORT"
nm_set_cfg "$SERVER_CFG" "EnableNetworkBroadcast" "0"
# UDP transport is used for multimedia acceleration but doesn't survive a
# loopback SSH tunnel cleanly -- force TCP-only.
nm_set_cfg "$SERVER_CFG" "EnableUDPCommunication" "0"
ok "server.cfg patched (port $NM_PORT, no LAN broadcast, TCP-only)"

#------------------------------------------------------------------------------
# 6. Ensure the target user has a working XFCE session
#------------------------------------------------------------------------------
# If install-xrdp-stable.sh already set up ~/.xsession, leave it -- xrdp and
# NoMachine can share the same session script.
log "Configuring XFCE session for $TARGET_USER..."
if [[ -r "$TARGET_HOME/.xsession" ]]; then
    ok "~/.xsession already exists -- re-using it"
else
    cat > "$TARGET_HOME/.xsession" <<'EOF'
#!/bin/bash
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
export XDG_SESSION_DESKTOP=xfce
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_TYPE=x11
exec startxfce4
EOF
    chmod +x "$TARGET_HOME/.xsession"
    chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.xsession"
    ok "~/.xsession created"
fi

#------------------------------------------------------------------------------
# 7. Firewall: allow NM_PORT only from localhost
#------------------------------------------------------------------------------
log "Configuring UFW (port $NM_PORT localhost-only)..."
if command -v ufw >/dev/null 2>&1; then
    # SSH-port detection (same approach as install-xrdp-stable.sh -- works for
    # non-22 ports like the user's 33344). Order matters: allow SSH BEFORE any
    # UFW enable so a fresh activation doesn't lock the admin out.
    SSH_PORTS=$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -u)
    if [[ -z "$SSH_PORTS" ]] && command -v sshd >/dev/null 2>&1; then
        SSH_PORTS=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | sort -u)
    fi
    SSH_PORTS=${SSH_PORTS:-22}

    for port in $SSH_PORTS; do
        ufw allow "$port/tcp" >/dev/null 2>&1 || true
    done

    ufw --force enable >/dev/null 2>&1 || true
    ufw allow from 127.0.0.1 to any port "$NM_PORT" proto tcp >/dev/null 2>&1 || true
    ufw deny "$NM_PORT/tcp" >/dev/null 2>&1 || true
    ok "Firewall: SSH ($(echo $SSH_PORTS | tr '\n' ' ')) allowed; $NM_PORT allowed from 127.0.0.1 only"
else
    warn "ufw not available, skipping firewall rules"
fi

#------------------------------------------------------------------------------
# 8. Restart NoMachine to pick up the new config
#------------------------------------------------------------------------------
log "Restarting NoMachine..."
/etc/NX/nxserver --restart >/dev/null 2>&1 || /usr/NX/bin/nxserver --restart >/dev/null 2>&1 || true
sleep 2

#------------------------------------------------------------------------------
# 9. Verify
#------------------------------------------------------------------------------
echo
log "=== Verification ==="
if ss -tlnp 2>/dev/null | grep -qE ":$NM_PORT\b"; then
    ok "NoMachine listening on port $NM_PORT"
else
    err "NoMachine not listening on $NM_PORT"
    /etc/NX/nxserver --status 2>/dev/null || true
    ss -tlnp 2>/dev/null | grep -E ":$NM_PORT\b" || true
fi

#------------------------------------------------------------------------------
# 10. Done -- print connection instructions
#------------------------------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')
echo
echo "=============================================================="
echo -e "${GREEN}  NoMachine installation complete!${NC}"
echo "=============================================================="
echo
echo "  Server:        $SERVER_IP"
echo "  NoMachine:     127.0.0.1:$NM_PORT (localhost only)"
echo "  Desktop:       XFCE4"
echo "  User:          $TARGET_USER"
echo
echo "  Connect from your local machine:"
echo
echo "    1) Open SSH tunnel (replace 33344 with your SSH port):"
echo "       ssh -L $NM_PORT:127.0.0.1:$NM_PORT -N -f \\"
echo "           -o ServerAliveInterval=30 \\"
echo "           -o ServerAliveCountMax=6 \\"
echo "           -p 33344 \\"
echo "           $TARGET_USER@$SERVER_IP"
echo
echo "    2) Install the NoMachine client for Windows from:"
echo "         https://www.nomachine.com/download"
echo
echo "    3) In the client, create a new connection:"
echo "         Host:       127.0.0.1"
echo "         Port:       $NM_PORT"
echo "         Protocol:   NX"
echo "         Username:   $TARGET_USER  (your Linux account)"
echo "         Password:   your Linux account password"
echo
echo "  Sessions are persistent by default -- disconnect/reconnect"
echo "  resumes exactly where you left off, with no policy tuning."
echo
echo "  Logs to check if anything misbehaves:"
echo "       sudo tail -f /usr/NX/var/log/nxserver.log"
echo "       sudo tail -f /usr/NX/var/log/nxd.log"
echo "=============================================================="
