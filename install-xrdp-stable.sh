#!/usr/bin/env bash
#==============================================================================
# xrdp Stable Reinstall & Configuration Script
# Target: Ubuntu 24.04 LTS
# Desktop: XFCE4 (most stable with xrdp)
# Security: Localhost-only (SSH tunnel required)
#==============================================================================

set -euo pipefail

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

# Detect the non-root user who will use xrdp
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
fi
[[ -n "$TARGET_USER" ]] || die "Could not detect a non-root user. Create one first."
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
ok "Target user for xrdp: $TARGET_USER ($TARGET_HOME)"

#------------------------------------------------------------------------------
# 1. Stop any running xrdp and purge old install
#------------------------------------------------------------------------------
log "Stopping and purging existing xrdp..."
systemctl stop xrdp xrdp-sesman 2>/dev/null || true
systemctl disable xrdp xrdp-sesman 2>/dev/null || true

# Kill any zombie sessions
pkill -9 -f xrdp 2>/dev/null || true
loginctl terminate-user "$TARGET_USER" 2>/dev/null || true

apt-get remove --purge -y xrdp xorgxrdp 2>/dev/null || true
rm -rf /etc/xrdp /var/log/xrdp* "$TARGET_HOME"/.xorgxrdp.*.log 2>/dev/null || true
ok "Old xrdp removed"

#------------------------------------------------------------------------------
# 2. Update system and install packages
#------------------------------------------------------------------------------
log "Updating package lists..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

log "Installing xrdp, XFCE, and dependencies..."
apt-get install -y \
    xrdp \
    xorgxrdp \
    xfce4 \
    xfce4-goodies \
    xfce4-terminal \
    dbus-x11 \
    policykit-1 \
    x11-xserver-utils \
    pulseaudio \
    tmux \
    ufw
ok "Packages installed"

#------------------------------------------------------------------------------
# 3. Give xrdp user access to SSL cert (fixes black screen on some installs)
#------------------------------------------------------------------------------
log "Adding xrdp user to ssl-cert group..."
adduser xrdp ssl-cert >/dev/null 2>&1 || true
ok "xrdp added to ssl-cert"

#------------------------------------------------------------------------------
# 4. Disable Wayland (xrdp requires Xorg)
#------------------------------------------------------------------------------
if [[ -f /etc/gdm3/custom.conf ]]; then
    log "Disabling Wayland in GDM..."
    sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=false/' /etc/gdm3/custom.conf
    grep -q "WaylandEnable=false" /etc/gdm3/custom.conf || \
        sed -i '/\[daemon\]/a WaylandEnable=false' /etc/gdm3/custom.conf
    ok "Wayland disabled"
fi

#------------------------------------------------------------------------------
# 5. Configure .xsession for the target user (XFCE)
#------------------------------------------------------------------------------
log "Configuring XFCE session for $TARGET_USER..."
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

# Also create .xsessionrc for safety
cat > "$TARGET_HOME/.xsessionrc" <<'EOF'
export XDG_SESSION_DESKTOP=xfce
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_TYPE=x11
EOF
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.xsessionrc"
ok ".xsession and .xsessionrc created"

#------------------------------------------------------------------------------
# 6. Write /etc/xrdp/xrdp.ini (localhost-only, stable settings)
#------------------------------------------------------------------------------
log "Writing /etc/xrdp/xrdp.ini..."
cat > /etc/xrdp/xrdp.ini <<'EOF'
[Globals]
ini_version=1
fork=true
port=tcp://127.0.0.1:3389
use_vsock=false
tcp_nodelay=true
tcp_keepalive=true
security_layer=negotiate
crypt_level=high
certificate=
key_file=
ssl_protocols=TLSv1.2, TLSv1.3
autorun=
allow_channels=true
allow_multimon=true
bitmap_cache=true
bitmap_compression=true
bulk_compression=true
max_bpp=32
new_cursors=true
use_fastpath=both
require_credentials=false
enable_token_login=false
ls_top_window_bg_color=009cb5
ls_width=350
ls_height=430
ls_bg_color=dedede
ls_title=Remote Desktop
ls_logo_filename=
ls_logo_x_pos=55
ls_logo_y_pos=50
ls_label_x_pos=30
ls_label_width=65
ls_input_x_pos=110
ls_input_width=210
ls_input_y_pos=220
ls_btn_ok_x_pos=142
ls_btn_ok_y_pos=370
ls_btn_ok_width=85
ls_btn_ok_height=30
ls_btn_cancel_x_pos=233
ls_btn_cancel_y_pos=370
ls_btn_cancel_width=85
ls_btn_cancel_height=30

[Logging]
LogFile=xrdp.log
LogLevel=INFO
EnableSyslog=true
SyslogLevel=INFO

[Channels]
rdpdr=true
rdpsnd=true
drdynvc=true
cliprdr=true
rail=true
xrdpvr=true
tcutils=true

[Xorg]
name=Xorg
lib=libxup.so
username=ask
password=ask
ip=127.0.0.1
port=-1
code=20
EOF
ok "xrdp.ini written (binding to 127.0.0.1:3389)"

#------------------------------------------------------------------------------
# 7. Write /etc/xrdp/sesman.ini (session persistence settings)
#------------------------------------------------------------------------------
log "Writing /etc/xrdp/sesman.ini..."
cat > /etc/xrdp/sesman.ini <<'EOF'
[Globals]
ListenAddress=127.0.0.1
ListenPort=3350
EnableUserWindowManager=true
UserWindowManager=startwm.sh
DefaultWindowManager=startwm.sh
ReconnectScript=reconnectwm.sh

[Security]
AllowRootLogin=false
MaxLoginRetry=4
TerminalServerUsers=tsusers
TerminalServerAdmins=tsadmins
AlwaysGroupCheck=false
RestrictOutboundClipboard=false
RestrictInboundClipboard=false

[Sessions]
X11DisplayOffset=10
MaxSessions=50
KillDisconnected=false
DisconnectedTimeLimit=0
IdleTimeLimit=0
Policy=UBDI

[Logging]
LogFile=xrdp-sesman.log
LogLevel=INFO
EnableSyslog=true
SyslogLevel=INFO

[Xorg]
param=Xorg
param=-config
param=xrdp/xorg.conf
param=-noreset
param=-nolisten
param=tcp
param=-logfile
param=.xorgxrdp.%s.log

[Chansrv]
FuseMountName=thinclient_drives
FileUmask=077
EnableFuseMount=true

[SessionVariables]
PULSE_SCRIPT=/etc/xrdp/pulse/default.pa
EOF
ok "sesman.ini written (Policy=UBDI, sessions never killed)"

#------------------------------------------------------------------------------
# 8. Patch /etc/xrdp/startwm.sh to honor .xsession
#------------------------------------------------------------------------------
log "Patching /etc/xrdp/startwm.sh..."
cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
# xrdp X session start script

if [ -r /etc/profile ]; then
    . /etc/profile
fi

if [ -r /etc/default/locale ]; then
    . /etc/default/locale
    export LANG LANGUAGE
fi

# Clean stale variables
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

# Honor user's ~/.xsession if present
if [ -r "$HOME/.xsession" ]; then
    . "$HOME/.xsession"
    exit 0
fi

# Fallback to system default
test -x /etc/X11/Xsession && exec /etc/X11/Xsession
exec /bin/sh /etc/X11/Xsession
EOF
chmod +x /etc/xrdp/startwm.sh
ok "startwm.sh patched"

#------------------------------------------------------------------------------
# 9. Fix polkit popups (color manager auth dialog inside RDP)
#------------------------------------------------------------------------------
log "Adding polkit rules to suppress auth popups..."
mkdir -p /etc/polkit-1/localauthority/50-local.d
cat > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla <<'EOF'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF

cat > /etc/polkit-1/localauthority/50-local.d/46-allow-update-repo.pkla <<'EOF'
[Allow Package Management all Users]
Identity=unix-user:*
Action=org.freedesktop.packagekit.system-sources-refresh
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF
ok "Polkit rules installed"

#------------------------------------------------------------------------------
# 10. Firewall: allow 3389 only from localhost
#------------------------------------------------------------------------------
log "Configuring UFW (3389 localhost-only)..."
if command -v ufw >/dev/null 2>&1; then
    ufw --force enable >/dev/null 2>&1 || true
    ufw allow from 127.0.0.1 to any port 3389 proto tcp >/dev/null 2>&1 || true
    ufw deny 3389/tcp >/dev/null 2>&1 || true
    ok "Firewall: 3389 allowed from 127.0.0.1 only"
else
    warn "ufw not available, skipping firewall rules"
fi

#------------------------------------------------------------------------------
# 11. Enable and start xrdp
#------------------------------------------------------------------------------
log "Enabling and starting xrdp services..."
systemctl daemon-reload
systemctl enable xrdp xrdp-sesman
systemctl restart xrdp-sesman
sleep 2
systemctl restart xrdp
sleep 2

#------------------------------------------------------------------------------
# 12. Verify
#------------------------------------------------------------------------------
echo
log "=== Verification ==="
if systemctl is-active --quiet xrdp; then
    ok "xrdp service: active"
else
    err "xrdp service: NOT active"
    systemctl status xrdp --no-pager | tail -20
fi

if systemctl is-active --quiet xrdp-sesman; then
    ok "xrdp-sesman service: active"
else
    err "xrdp-sesman service: NOT active"
    systemctl status xrdp-sesman --no-pager | tail -20
fi

if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:3389"; then
    ok "xrdp listening on 127.0.0.1:3389"
else
    warn "xrdp not yet listening on 3389 (may need a moment)"
    ss -tlnp 2>/dev/null | grep 3389 || true
fi

#------------------------------------------------------------------------------
# 13. Done — print connection instructions
#------------------------------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')
echo
echo "=============================================================="
echo -e "${GREEN}  xrdp installation complete!${NC}"
echo "=============================================================="
echo
echo "  Server:        $SERVER_IP"
echo "  xrdp bind:     127.0.0.1:3389 (localhost only)"
echo "  Desktop:       XFCE4"
echo "  User:          $TARGET_USER"
echo
echo "  Connect from your local machine:"
echo
echo "    1) Open SSH tunnel:"
echo "       ssh -L 3389:127.0.0.1:3389 -N -f \\"
echo "           -o ServerAliveInterval=30 \\"
echo "           -o ServerAliveCountMax=6 \\"
echo "           $TARGET_USER@$SERVER_IP"
echo
echo "    2) Point your RDP client to: 127.0.0.1:3389"
echo
echo "  Pro tip: wrap your SSH terminal sessions in tmux so they"
echo "  survive RDP disconnects:"
echo "       ssh $TARGET_USER@$SERVER_IP -t tmux new -A -s main"
echo
echo "  Logs to check if anything misbehaves:"
echo "       sudo tail -f /var/log/xrdp.log"
echo "       sudo tail -f /var/log/xrdp-sesman.log"
echo "       tail -f $TARGET_HOME/.xsession-errors"
echo "=============================================================="
