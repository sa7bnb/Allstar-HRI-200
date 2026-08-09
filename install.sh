#!/bin/bash
#
# install.sh - AllStarLink node with a Yaesu HRI-200 and FTM-400D.
#
# Raspberry Pi OS Lite ships without git, so install it first:
#
#     sudo apt update && sudo apt install -y git
#     git clone https://github.com/sa7bnb/Allstar-HRI-200.git
#     cd Allstar-HRI-200
#     sudo ./install.sh
#
# Or skip git entirely - wget and tar are always present:
#
#     wget https://github.com/sa7bnb/Allstar-HRI-200/archive/refs/heads/main.tar.gz
#     tar xzf main.tar.gz
#     cd Allstar-HRI-200-main
#     sudo ./install.sh
#
# Installs, in order:
#
#   1. AllStarLink 3 from AllStarLink's own apt repository (skipped if
#      already present)
#   2. allstar.py, its config, service, udev rule and sudoers entry
#   3. The hooks into ASL3: one #includeifexists line in rpt.conf, and
#      two lines in modules.conf for chan_usrp
#
# Everything else is configured from the web panel afterwards - node
# number, callsign, node password, frequency, power and audio levels.
#
# Tested on Raspberry Pi OS Lite 64-bit (Debian 13 trixie) on a Pi 4.
#
# The node keys a real transmitter as soon as it starts. USE A DUMMY LOAD
# until you have a frequency you are licensed and permitted to use.

set -euo pipefail

SCRIPT_VERSION="Allstar-HRI-200-v1.0"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Settings - override on the command line if you like
# ---------------------------------------------------------------------------

NODE="${NODE:-1999}"                    # 1000-1999 is private, no registration
CALLSIGN="${CALLSIGN:-}"
FREQ="${FREQ:-434.5000}"

WEB_PORT="${WEB_PORT:-8080}"
WEB_BIND="${WEB_BIND:-0.0.0.0}"         # 127.0.0.1 = SSH tunnel only

INSTALL_ASL="${INSTALL_ASL:-yes}"
FULL_UPGRADE="${FULL_UPGRADE:-yes}"
RESTART_ASTERISK="${RESTART_ASTERISK:-yes}"

SVC_USER="allstar"
BACKUP_DIR="/var/backups/allstar"
STAMP="$(date +%Y%m%d-%H%M%S)"
SERIAL_PORT="/dev/hri200"

# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; C=$'\e[36m'; N=$'\e[0m'
else
    R=""; G=""; Y=""; B=""; C=""; N=""
fi

WARNINGS=()
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "    ${G}ok${N}   $*"; }
warn() { echo "    ${Y}note${N} $*"; WARNINGS+=("$*"); }
die()  { echo; echo "    ${R}fail${N} $*" >&2; exit 1; }
run()  { echo "    ${C}\$ $*${N}"; "$@"; }

backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").$STAMP"
    echo "    ${G}ok${N}   backup: $BACKUP_DIR/$(basename "$f").$STAMP"
}

# ---------------------------------------------------------------------------
step "Checks"
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "run with sudo"

for f in allstar.py; do
    [[ -f "$SRC_DIR/$f" ]] || die "$f not found in $SRC_DIR

    Run this from inside the repository directory:
        cd Allstar-HRI-200 && sudo ./install.sh"
done
ok "allstar.py found"

command -v python3 >/dev/null || die "python3 is missing"
python3 "$SRC_DIR/allstar.py" --selftest >/dev/null 2>&1 \
    && ok "allstar.py self-test passes" \
    || die "allstar.py failed its own self-test - is the file complete?"

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "arm64" || "$ARCH" == "amd64" ]] || die "ASL3 needs arm64 or amd64, not $ARCH.
    Running 32-bit Raspberry Pi OS? Reflash with the 64-bit image."
ok "architecture $ARCH"

OS_CODENAME="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")"
OS_PRETTY="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
case "$OS_CODENAME" in
    trixie)   REPO_DEB="asl-apt-repos.deb13_all.deb" ;;
    bookworm) REPO_DEB="asl-apt-repos.deb12_all.deb" ;;
    *) REPO_DEB=""
       warn "untested distribution: $OS_PRETTY - skipping the ASL3 repository"
       INSTALL_ASL="no" ;;
esac
ok "$OS_PRETTY"

PI_MODEL=""
if [[ -r /proc/device-tree/model ]]; then
    PI_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
    [[ -n "$PI_MODEL" ]] && ok "$PI_MODEL"
fi
case "$PI_MODEL" in
    *"Pi 3"*|*"Zero 2"*)
        warn "this model uses dwc_otg for USB, which is fussier about"
        echo "         isochronous audio. Raise jitter_frames in"
        echo "         /etc/allstar.conf if the audio breaks up." ;;
esac

python3 - "$FREQ" "$NODE" <<'PYEOF' || die "invalid parameter"
import sys
freq, node = sys.argv[1:3]
assert len("%09.5f" % float(freq)) == 9, "frequency will not fit the radio's field"
assert node.isdigit(), "NODE must be a number"
PYEOF
ok "node $NODE, ${FREQ} MHz"

# ---------------------------------------------------------------------------
step "System packages"
# ---------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive

if dpkg -s asl3 >/dev/null 2>&1; then
    ok "asl3 already installed - leaving it alone"
    ASL_PRESENT=yes
    FULL_UPGRADE=no
else
    ASL_PRESENT=no
fi

if [[ "$FULL_UPGRADE" == "yes" && "$INSTALL_ASL" == "yes" ]]; then
    run apt-get update -qq
    echo "    upgrading the system, this takes 20-40 minutes on a Pi..."
    apt-get -y -qq full-upgrade
    ok "system upgraded"

    # An upgrade can install a new kernel without it running yet. Nothing
    # here builds kernel modules, but ASL3 pulls in dahdi-dkms, which does.
    RUNNING="$(uname -r)"
    NEWEST="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1)"
    if [[ -n "$NEWEST" && "$NEWEST" != "$RUNNING" ]]; then
        echo
        echo "  ${Y}${B}Reboot before continuing.${N}"
        echo
        echo "    Running kernel:   $RUNNING"
        echo "    Installed kernel: $NEWEST"
        echo
        echo "      sudo reboot"
        echo
        echo "    Then run this script again. It picks up where it left off."
        echo
        exit 0
    fi
    ok "running the newest installed kernel ($RUNNING)"
else
    run apt-get update -qq
fi

MISSING=()
for p in python3-serial python3-alsaaudio python3-flask alsa-utils usbutils \
         wget ca-certificates sudo; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "    installing: ${MISSING[*]}"
    apt-get install -y -qq --no-install-recommends "${MISSING[@]}" >/dev/null \
        || die "could not install ${MISSING[*]}"
fi
ok "dependencies present"

# ---------------------------------------------------------------------------
step "AllStarLink 3"
# ---------------------------------------------------------------------------

if [[ "$ASL_PRESENT" == "yes" ]]; then
    ok "already installed"
elif [[ "$INSTALL_ASL" != "yes" ]]; then
    warn "INSTALL_ASL=no - install ASL3 yourself before this will work"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    echo "    ${C}\$ wget https://repo.allstarlink.org/public/$REPO_DEB${N}"
    wget -q -O "$TMP/$REPO_DEB" \
        "https://repo.allstarlink.org/public/$REPO_DEB" \
        || die "could not fetch the ASL3 repository package - check networking"
    run dpkg -i "$TMP/$REPO_DEB"
    run apt-get update -qq
    ok "repository added"

    echo "    Installing ASL3 takes quite a while—expect it to take anywhere from 40 to 60 minutes....."
    # DAHDI does not build against kernel 6.18 (del_timer_sync was renamed
    # to timer_delete_sync), and on ASL3 3.9.x app_rpt does not need it -
    # Asterisk gets its timing from res_timing_timerfd. Let the install
    # continue if only dahdi-dkms fails.
    if ! apt-get install -y -qq asl3 >/dev/null 2>&1; then
        warn "the asl3 install reported errors - checking whether it matters"
        apt-get install -y -qq --fix-broken >/dev/null 2>&1 || true
        if dpkg -s asterisk >/dev/null 2>&1 || command -v asterisk >/dev/null; then
            ok "Asterisk is installed; the failure was most likely dahdi-dkms"
            warn "dahdi-dkms did not build. app_rpt works without it on"
            echo "         ASL3 3.9.x - timing comes from res_timing_timerfd."
        else
            die "asl3 could not be installed - see the output above"
        fi
    else
        ok "asl3 installed"
    fi
fi

[[ -f /etc/asterisk/rpt.conf ]] \
    || die "/etc/asterisk/rpt.conf is missing - ASL3 is not properly installed"
ok "rpt.conf present"

USRP_MOD=""
for d in /usr/lib /usr/lib64 /usr/local/lib; do
    [[ -d "$d" ]] || continue
    found="$(find "$d" -name chan_usrp.so -print -quit 2>/dev/null || true)"
    [[ -n "$found" ]] && { USRP_MOD="$found"; break; }
done
[[ -n "$USRP_MOD" ]] && ok "chan_usrp.so found" \
    || warn "chan_usrp.so not found - the bridge will have nothing to talk to"

# Asterisk 22 gets its timing from timerfd, so a missing DAHDI is fine.
if lsmod 2>/dev/null | grep -q "^dahdi" || [[ -e /dev/dahdi/pseudo ]]; then
    ok "dahdi loaded"
else
    warn "dahdi is not loaded - normal on kernel 6.18 and not a problem here"
fi

# ---------------------------------------------------------------------------
step "User and devices"
# ---------------------------------------------------------------------------

if id -u "$SVC_USER" >/dev/null 2>&1; then
    ok "user $SVC_USER exists"
else
    useradd -r -s /usr/sbin/nologin -M -d /nonexistent "$SVC_USER"
    ok "user $SVC_USER created"
fi
# dialout: HRI-200 serial port. audio: the ALSA device.
# asterisk: read-only access to the Asterisk CLI for node status.
usermod -aG dialout,audio "$SVC_USER"
if getent group asterisk >/dev/null; then
    usermod -aG asterisk "$SVC_USER"
    ok "$SVC_USER in dialout, audio, asterisk"
else
    warn "no asterisk group - link status may not show in the panel"
fi

# A stable name for the serial port. /dev/ttyACM0 moves if another
# CDC-ACM device is plugged in.
backup /etc/udev/rules.d/99-hri200.rules
cat > /etc/udev/rules.d/99-hri200.rules <<'EOF'
# Yaesu HRI-200 control port
SUBSYSTEM=="tty", ATTRS{idVendor}=="26aa", ATTRS{idProduct}=="0002", \
    SYMLINK+="hri200", GROUP="dialout", MODE="0660"
EOF
udevadm control --reload-rules >/dev/null 2>&1 || true
udevadm trigger --subsystem-match=tty >/dev/null 2>&1 || true
sleep 1
[[ -e /dev/hri200 ]] && ok "/dev/hri200 -> $(readlink -f /dev/hri200)" \
                     || warn "/dev/hri200 not there yet - appears when the box is plugged in"

# Connecting to a unix socket needs write permission, and Asterisk creates
# the control socket 0644 by default. Without this the panel can create
# links but never see them.
if grep -q "^\s*astctlpermissions" /etc/asterisk/asterisk.conf 2>/dev/null; then
    ok "asterisk.conf already sets astctlpermissions"
else
    backup /etc/asterisk/asterisk.conf
    if grep -q "^\s*\[files\]" /etc/asterisk/asterisk.conf 2>/dev/null; then
        python3 - <<'PYEOF'
import re
p = "/etc/asterisk/asterisk.conf"
lines = open(p).read().split("\n")
want = {"astctlpermissions": "0660", "astctlowner": "asterisk",
        "astctlgroup": "asterisk"}

start = None
for i, ln in enumerate(lines):
    if re.match(r"^\s*\[files\]", ln):
        start = i
        break
end = len(lines)
for j in range(start + 1, len(lines)):
    if re.match(r"^\s*\[", lines[j]):
        end = j
        break

# Replace keys that are already there rather than adding a second copy.
for key, value in list(want.items()):
    pat = re.compile(r"^\s*%s\s*=" % key)
    for j in range(start + 1, end):
        if pat.match(lines[j]):
            lines[j] = "%s = %s" % (key, value)
            del want[key]
            break
if want:
    lines[start + 1:start + 1] = ["%s = %s" % kv for kv in want.items()]
open(p, "w").write("\n".join(lines))
PYEOF
    else
        cat >> /etc/asterisk/asterisk.conf <<'EOF'

[files]
; Group write so the allstar panel can read node status through the CLI.
astctlpermissions = 0660
astctlowner = asterisk
astctlgroup = asterisk
EOF
    fi
    ok "asterisk.conf: control socket made group-writable"
fi

# ---------------------------------------------------------------------------
step "allstar.py"
# ---------------------------------------------------------------------------

install -m755 -o root -g root "$SRC_DIR/allstar.py" /usr/local/bin/allstar.py
ok "/usr/local/bin/allstar.py"

if [[ -f /etc/allstar.conf ]]; then
    ok "/etc/allstar.conf exists - left alone"
else
    SECRET="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
    cat > /etc/allstar.conf <<EOF
# /etc/allstar.conf
#
# Most of this is set from the web panel. Edit by hand if you prefer, then:
#     sudo systemctl restart allstar

[serial]
port = $SERIAL_PORT
baudrate = 38400
# WIRES-X polls at 1 Hz. 0.2 gives better squelch latency and costs nothing.
poll_interval = 0.2

[radio]
# ftm400d | ft7800r | custom
#
# Only decides how long the node waits for the radio to identify itself and
# which mixer levels are suggested. What the radio actually replies always
# wins, so swapping radios corrects itself. An FT-7800R never answers, which
# is not a fault: PTT, squelch and audio work regardless - only frequency,
# power and tone have to be set on the radio.
model = ftm400d

# A placeholder, not a recommendation. You are responsible for operating on
# a frequency you are licensed and permitted to use in your own country.
frequency = $FREQ
mode = fm            ; fm | digital
narrow = no
power = low          ; high | mid | low
tone_mode = off      ; off | ctcss | dcs
ctcss = 88.5         ; the integer part is what gets sent
dcs = 23             ; three octal digits, verbatim

[audio]
device = plughw:CARD=codec,DEV=0
card = codec
set_mixer = yes
# The control names do not match their functions: 'Speaker' is the level
# OUT to the radio, 'PCM' the level IN from it.
tx_level = 47
rx_level = 45
# The radio's AF stage unmuting is a DC step that clips regardless of gain.
# The first few milliseconds after squelch opens are sent as silence.
rx_open_mute_ms = 40

[usrp]
# Must match rxchannel in rpt.conf:
#   rxchannel = USRP/127.0.0.1:34001:32001
local_port = 34001
remote_host = 127.0.0.1
remote_port = 32001
tx_tail_ms = 60
jitter_frames = 3

[web]
enabled = yes
# 0.0.0.0 reaches your whole network. Use 127.0.0.1 to require an SSH
# tunnel:  ssh -L $WEB_PORT:localhost:$WEB_PORT user@node
host = $WEB_BIND
port = $WEB_PORT
username = asl3
# Empty means the default password "password". Change it on the
# Panel access card in the web interface.
password_hash =
secret_key = $SECRET

[daemon]
loglevel = info      ; debug | info | warning | error
EOF
    chown root:"$SVC_USER" /etc/allstar.conf
    chmod 640 /etc/allstar.conf
    ok "/etc/allstar.conf created"
fi

# ---------------------------------------------------------------------------
step "sudo rule"
# ---------------------------------------------------------------------------

# One program, one fixed argument, no wildcards. The request travels as JSON
# on stdin and is re-validated inside --apply.
cat > /etc/sudoers.d/allstar <<EOF
# Generated by install.sh. The service runs unprivileged; this is the only
# thing it may run as root.
$SVC_USER ALL=(root) NOPASSWD: /usr/local/bin/allstar.py --apply
Defaults!/usr/local/bin/allstar.py !requiretty
EOF
chmod 440 /etc/sudoers.d/allstar
if visudo -cf /etc/sudoers.d/allstar >/dev/null 2>&1; then
    ok "/etc/sudoers.d/allstar"
else
    rm -f /etc/sudoers.d/allstar
    die "visudo rejected the sudoers rule - nothing changed"
fi

# ---------------------------------------------------------------------------
step "Service"
# ---------------------------------------------------------------------------

cat > /etc/systemd/system/allstar.service <<EOF
[Unit]
Description=AllStarLink node - HRI-200 bridge and web panel
Documentation=https://github.com/sa7bnb/Allstar-HRI-200
After=sound.target network.target
Wants=asterisk.service

# Never give up. The default limit (5 starts in 10 s) leaves the service
# dead if USB has not enumerated yet, or if the radio is not in HRI-200
# mode at boot. An unattended node should keep trying.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
SupplementaryGroups=dialout audio asterisk

ExecStart=/usr/local/bin/allstar.py -c /etc/allstar.conf
ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGTERM
TimeoutStopSec=10
Restart=always
RestartSec=15

# The audio threads must not be starved, or you get underruns under load.
# IOSchedulingClass is deliberately absent: it needs CAP_SYS_ADMIN and buys
# nothing, since this barely touches the disk.
Nice=-10

# NOT ProtectSystem: the --apply helper runs as a child of this service and
# inherits its mounts. With ProtectSystem=full, /etc is read-only even for
# root and every save fails. The protection is the sudoers rule instead.
NoNewPrivileges=no
PrivateTmp=yes
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
ok "allstar.service installed"

# ---------------------------------------------------------------------------
step "Hooks into ASL3"
# ---------------------------------------------------------------------------

backup /etc/asterisk/modules.conf
backup /etc/asterisk/rpt.conf

python3 - "$NODE" "$CALLSIGN" <<'PYEOF' || die "could not write the Asterisk configuration"
import os, re, sys

NODE, CALLSIGN = sys.argv[1], sys.argv[2]
TAG = "; allstar"
RX = "USRP/127.0.0.1:34001:32001"
RXLINE = "rxchannel = %s\t%s" % (RX, TAG)
INCFILE = "custom/allstar.conf"
HEADER = re.compile(r"^\[([^\]]+)\]\s*(\([^)]*\))?\s*(;.*)?$")


def read(p):
    with open(p) as fh:
        return fh.read().split("\n")


def write(p, lines):
    with open(p, "w") as fh:
        fh.write("\n".join(lines))


def find(lines, name):
    for i, ln in enumerate(lines):
        m = HEADER.match(ln)
        if m and m.group(1).strip() == name:
            return i
    return None


# --- modules.conf ------------------------------------------------------
# ASL3 ships autoload=no plus an explicit noload for chan_usrp. A noload
# beats a load wherever it appears, so the line has to be commented out
# where it is - no include can work around it.
mp = "/etc/asterisk/modules.conf"
if os.path.exists(mp):
    lines = read(mp)
    changed = False
    for i, ln in enumerate(lines):
        if re.match(r"^\s*noload\s*=>?\s*chan_usrp\.so\b", ln):
            lines[i] = ";" + ln.rstrip() + "  " + TAG
            changed = True
    if not any(re.match(r"^\s*load\s*=>?\s*chan_usrp\.so\b", l) for l in lines):
        for i, ln in enumerate(lines):
            if re.match(r"^\s*\[modules\]\s*$", ln):
                lines.insert(i + 1, "load => chan_usrp.so\t" + TAG)
                break
        else:
            lines += ["", "[modules]", "load => chan_usrp.so\t" + TAG]
        changed = True
    if changed:
        write(mp, lines)
        print("    modules.conf: chan_usrp enabled")
    else:
        print("    modules.conf: chan_usrp already enabled")

# --- rpt.conf ----------------------------------------------------------
rp = "/etc/asterisk/rpt.conf"
lines = read(rp)
existing = find(lines, NODE)

if existing is not None:
    # A stanza for this node already exists - swap its rxchannel and leave
    # everything else the user or asl-menu put there.
    end = len(lines)
    for j in range(existing + 1, len(lines)):
        if HEADER.match(lines[j]):
            end = j
            break
    changed = []
    for j in range(existing + 1, end):
        if re.match(r"^\s*rxchannel\s*=", lines[j]):
            if lines[j] != RXLINE:
                was = lines[j].split("=", 1)[1].split(";")[0].strip()
                lines[j] = RXLINE
                changed.append("rxchannel was '%s', now USRP" % was)
            break
    else:
        lines.insert(existing + 1, RXLINE)
        end += 1
        changed.append("rxchannel added")

    # Same reason as above: the inherited duplex = 2 repeats audio and makes
    # a simplex node transmit while you are talking to it.
    for j in range(existing + 1, end):
        m = re.match(r"^\s*duplex\s*=\s*(\d)", lines[j])
        if m:
            if m.group(1) != "1":
                lines[j] = "duplex = 1\t\t\t%s (was %s)" % (TAG, m.group(1))
                changed.append("duplex was %s, now 1" % m.group(1))
            break
    else:
        lines.insert(existing + 1, "duplex = 1\t\t\t" + TAG)
        changed.append("duplex set to 1")

    if changed:
        write(rp, lines)
        print("    rpt.conf: node %s - %s" % (NODE, "; ".join(changed)))
    else:
        print("    rpt.conf: node %s already configured" % NODE)
else:
    # New node: keep it in our own file and touch rpt.conf once.
    if not any(INCFILE in l for l in lines):
        while lines and lines[-1].strip() == "":
            lines.pop()
        lines += ["", "#includeifexists %s\t%s" % (INCFILE, TAG), ""]
        write(rp, lines)
        print("    rpt.conf: one include line added")

    has_tmpl = any(
        HEADER.match(l) and HEADER.match(l).group(1).strip() == "node-main"
        and (HEADER.match(l).group(2) or "") == "(!)" for l in lines)
    tmpl = "(node-main)" if has_tmpl else ""

    os.makedirs("/etc/asterisk/custom", exist_ok=True)
    body = [
        ";",
        "; Generated by install.sh. This file belongs to allstar; ASL3's own",
        "; files are untouched apart from the include line in rpt.conf.",
        ";",
    ]
    if tmpl:
        body += ["; Included last, so the template is already defined and",
                 "; inheritance works.", ";"]
    body += ["[%s]%s" % (NODE, tmpl), RXLINE]
    # duplex ALWAYS goes in our own stanza, even when inheriting.
    # ASL3's [node-main] ships duplex = 2 - full duplex, repeats received
    # audio - because the template is written for a hub with no radio. On a
    # simplex node with one transceiver that makes the node transmit the
    # moment it hears you, so you never hear yourself. 1 is the value ASL3's
    # own comment recommends "when interfacing a simplex node".
    body += ["duplex = 1"]
    if not tmpl:
        body += ["hangtime = 1000"]
    if CALLSIGN:
        body += ["idrecording = |i%s" % CALLSIGN]
    body += [""]
    with open("/etc/asterisk/custom/allstar.conf", "w") as fh:
        fh.write("\n".join(body))
    print("    custom/allstar.conf: node %s%s"
          % (NODE, " (inherits node-main)" if tmpl else ""))
PYEOF
ok "ASL3 hooked up"

# ---------------------------------------------------------------------------
step "Starting"
# ---------------------------------------------------------------------------

systemctl enable allstar >/dev/null 2>&1
ok "allstar enabled at boot"

if [[ "$RESTART_ASTERISK" == "yes" ]] \
   && systemctl cat asterisk.service >/dev/null 2>&1; then
    echo "    restarting asterisk..."
    systemctl restart asterisk 2>/dev/null || warn "asterisk did not restart"
    sleep 3
    systemctl is-active --quiet asterisk && ok "asterisk running" \
        || warn "asterisk is not running - journalctl -u asterisk -n 40"
fi

systemctl restart allstar 2>/dev/null || true
sleep 4
if systemctl is-active --quiet allstar; then
    ok "allstar running"
else
    warn "allstar did not start - journalctl -u allstar -n 40"
fi

# ---------------------------------------------------------------------------
step "Health check"
# ---------------------------------------------------------------------------

if systemctl is-active --quiet asterisk; then
    asterisk -rx "module show like chan_usrp" 2>/dev/null | grep -q "chan_usrp.so" \
        && ok "chan_usrp loaded" \
        || warn "chan_usrp is not loaded - check modules.conf"

    # The command differs between versions: 'rpt show nodes' does not exist
    # in 3.9.x, where it is 'rpt localnodes'.
    NODELIST=""
    for cmd in "rpt localnodes" "rpt show nodes"; do
        out="$(asterisk -rx "$cmd" 2>/dev/null || true)"
        if [[ -n "$out" && "$out" != *"No such command"* ]]; then
            NODELIST="$out"; break
        fi
    done
    if [[ -z "$NODELIST" ]]; then
        warn "could not ask app_rpt about its nodes"
    elif grep -qw "$NODE" <<<"$NODELIST"; then
        ok "app_rpt knows node $NODE"
    else
        warn "app_rpt does not see node $NODE"
    fi
fi

if command -v curl >/dev/null; then
    curl -fsS -o /dev/null -m 5 "http://127.0.0.1:$WEB_PORT/login" 2>/dev/null \
        && ok "web panel answering on port $WEB_PORT" \
        || warn "web panel did not answer - journalctl -u allstar -n 30"
fi

if ! systemctl is-active --quiet allstar; then
    echo
    echo "    Full chain check:"
    sudo -u "$SVC_USER" /usr/local/bin/allstar.py --check || true
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

# ---------------------------------------------------------------------------

echo
echo "${B}Done.${N} $SCRIPT_VERSION"
echo

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo "${Y}${#WARNINGS[@]} thing(s) to look at:${N}"
    for w in "${WARNINGS[@]}"; do echo "  - $w"; done
    echo
fi

cat <<EOF
${B}Open  http://${IP:-<node-address>}:$WEB_PORT${N}
      user ${B}asl3${N}, password ${B}password${N}

${Y}Change that password first${N} - on the Panel access card. Anyone who can
reach this address can retune your transmitter and change your node number.

Then, from the panel:

  ${B}Node identity${N}   node number, callsign, and the node password from
                  https://www.allstarlink.org/ (nodes 1000-1999 are private
                  and need no registration)
  ${B}Radio${N}           frequency, power, mode and tone
  ${B}Audio levels${N}    transmit and receive
  ${B}Links${N}           connect to other nodes and disconnect again

Two things the panel cannot do for you:

  1. ${B}Put the radio in HRI-200 mode.${N} Start the FTM-400D with [D/X]+[GM]
     until the display reads HRI-200. [D/X] alone gives PDN mode, which
     looks the same and does not work. This does not survive a power cut.

  2. ${B}Forward UDP 4569${N} to this machine in your router, or nobody can
     reach your node from outside. Never forward port $WEB_PORT.

Test against a ${B}dummy load${N} until you have a frequency you are licensed
and permitted to use for an unattended station in your country.

  Logs:      journalctl -u allstar -f
  Chain:     sudo systemctl stop allstar
             sudo -u $SVC_USER allstar.py --check
             sudo systemctl start allstar
  Backups:   $BACKUP_DIR
EOF
