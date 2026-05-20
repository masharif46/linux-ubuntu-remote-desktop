#!/usr/bin/env bash
#==============================================================================
# fail2ban Configuration Script
# Target: Ubuntu 24.04 LTS
# Purpose: Harden SSH against brute-force / credential-stuffing attacks.
#
# Coexists with install-xrdp-stable.sh and install-nomachine-stable.sh --
# touches only fail2ban, never the remote-desktop services or UFW.
#
# Auto-detects the SSH port (handles non-22 setups). Writes jail.local so
# the config survives fail2ban package upgrades.
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Configuration -- override via env vars if needed
#------------------------------------------------------------------------------
BAN_TIME="${BAN_TIME:-1h}"        # how long an offender stays banned
FIND_TIME="${FIND_TIME:-10m}"     # window over which failed attempts are counted
MAX_RETRY="${MAX_RETRY:-5}"       # failed attempts before ban

# Extra IPs to whitelist beyond localhost. Useful if you have a static home IP
# you want to be ban-proof. Space-separated. Example:
#   sudo WHITELIST_IP="203.0.113.7 198.51.100.0/24" ./configure-fail2ban.sh
WHITELIST_IP="${WHITELIST_IP:-}"

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

# SSH-port detection (same logic as install-xrdp-stable.sh / install-nomachine-stable.sh).
# Banning the wrong port would either do nothing (sshd brute-force passes through)
# or, worse, ban us off a working port -- this needs to be correct.
SSH_PORTS=$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -u)
if [[ -z "$SSH_PORTS" ]] && command -v sshd >/dev/null 2>&1; then
    SSH_PORTS=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | sort -u)
fi
SSH_PORTS=${SSH_PORTS:-22}
SSH_PORTS_CSV=$(echo $SSH_PORTS | tr '\n' ',' | sed 's/,$//')
ok "Detected SSH port(s): $SSH_PORTS_CSV"

# Build the ignoreip list. Loopback is always whitelisted; WHITELIST_IP appends.
IGNORE_IP="127.0.0.1/8 ::1"
if [[ -n "$WHITELIST_IP" ]]; then
    IGNORE_IP="$IGNORE_IP $WHITELIST_IP"
    ok "Whitelisting in addition to localhost: $WHITELIST_IP"
fi

#------------------------------------------------------------------------------
# 1. Install fail2ban
#------------------------------------------------------------------------------
log "Installing fail2ban..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y fail2ban
ok "fail2ban installed"

#------------------------------------------------------------------------------
# 2. Write /etc/fail2ban/jail.local
#------------------------------------------------------------------------------
# fail2ban ships /etc/fail2ban/jail.conf -- that file is owned by the package
# and gets overwritten on apt upgrades. jail.local takes precedence and
# persists. Always edit .local, never .conf.
log "Writing /etc/fail2ban/jail.local..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Ban a host that fails maxretry times within findtime, for bantime.
bantime  = $BAN_TIME
findtime = $FIND_TIME
maxretry = $MAX_RETRY

# Whitelist -- never ban these. Localhost always; add static home IPs via
# WHITELIST_IP env var when re-running this script.
ignoreip = $IGNORE_IP

# Read auth events from the systemd journal -- modern Ubuntu logs sshd there
# instead of /var/log/auth.log, so the file backend would silently miss bans.
backend = systemd

# Default action -- iptables-multiport plays nicely with UFW.
banaction = iptables-multiport

[sshd]
enabled  = true
port     = $SSH_PORTS_CSV
filter   = sshd
maxretry = $MAX_RETRY
bantime  = $BAN_TIME

# Recidive: meta-jail that re-bans hosts which keep coming back AFTER their
# initial ban expires. Catches slow-burn credential-stuffing campaigns that
# pace themselves under the per-jail thresholds.
[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban.log
bantime  = 1w
findtime = 1d
maxretry = 3
EOF
ok "jail.local written (sshd + recidive enabled)"

#------------------------------------------------------------------------------
# 3. Enable and (re)start fail2ban
#------------------------------------------------------------------------------
log "Enabling and (re)starting fail2ban..."
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2

#------------------------------------------------------------------------------
# 4. Verify
#------------------------------------------------------------------------------
echo
log "=== Verification ==="
if systemctl is-active --quiet fail2ban; then
    ok "fail2ban service: active"
else
    err "fail2ban service: NOT active"
    systemctl status fail2ban --no-pager | tail -20
    exit 1
fi

log "Active jails:"
fail2ban-client status 2>/dev/null | sed 's/^/  /' || warn "fail2ban-client status failed -- check /var/log/fail2ban.log"

echo
log "sshd jail detail:"
fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || true

#------------------------------------------------------------------------------
# 5. Done -- print maintenance commands and lockout recovery
#------------------------------------------------------------------------------
echo
echo "=============================================================="
echo -e "${GREEN}  fail2ban configured!${NC}"
echo "=============================================================="
echo
echo "  Watching:    sshd on port(s) $SSH_PORTS_CSV"
echo "  Ban policy:  $MAX_RETRY fails in $FIND_TIME -> banned for $BAN_TIME"
echo "  Recidive:    3 re-offenses within 1d -> banned for 1w"
echo "  Whitelist:   $IGNORE_IP"
echo
echo "  Useful commands:"
echo "    fail2ban-client status                 # list active jails"
echo "    fail2ban-client status sshd            # current sshd bans + stats"
echo "    fail2ban-client banned                 # all currently-banned IPs"
echo "    fail2ban-client set sshd unbanip X.X.X.X   # manually unban"
echo "    sudo tail -f /var/log/fail2ban.log     # live activity"
echo
echo "  IF YOU LOCK YOURSELF OUT:"
echo "    You ARE whitelisted from 127.0.0.1 (so SSH-tunnel clients are safe),"
echo "    but a fresh SSH login from your public IP still goes through the jail."
echo "    If you ever ban yourself, use the hosting provider's web console"
echo "    (Proxmox / OVH / DigitalOcean / etc.) and run:"
echo "        sudo fail2ban-client set sshd unbanip <your-public-ip>"
echo "    To make this less likely, re-run this script with:"
echo "        sudo WHITELIST_IP='YOUR.HOME.IP' $0"
echo
echo "  NoMachine note: it currently binds to 127.0.0.1, so no fail2ban"
echo "  jail is needed for it. If you ever expose NoMachine on the public"
echo "  IP, add a custom filter against /usr/NX/var/log/nxserver.log."
echo "=============================================================="
