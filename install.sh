#!/usr/bin/env python3
"""
allstar.py - Yaesu HRI-200 to AllStarLink bridge, with a web control panel.

One file, one service. It runs two things in the same process:

  * a bridge that presents the HRI-200 to Asterisk/app_rpt as a USRP channel
  * a web panel for changing frequency, power, node number and links

Because they share a process, retuning the radio does not need a service
restart: the web side writes the config and tells the bridge to re-run its
handshake directly.

Modes:
    allstar.py                 run the service (bridge + web panel)
    allstar.py --check         test the whole chain against the hardware
    allstar.py --selftest      test the protocol builders, no hardware needed
    allstar.py --hash          generate a web panel password hash
    allstar.py --apply         privileged helper, invoked through sudo

Serial protocol per https://github.com/sa7bnb/Svxlink-HRI-200

Requires: python3-serial, python3-alsaaudio, python3-flask, alsa-utils
"""

import argparse
import base64
import configparser
import getpass
import hashlib
import hmac
import json
import logging
import os
import queue
import re
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

try:
    import serial
except ImportError:
    serial = None

try:
    import alsaaudio
except ImportError:
    alsaaudio = None

try:
    from flask import (Flask, request, session, redirect, url_for,
                       render_template_string, jsonify)
except ImportError:
    Flask = None

PROJECT = "Allstar-HRI-200"
__version__ = "1.0"
RELEASE = "%s-v%s" % (PROJECT, __version__)

CONFIG_PATH = "/etc/allstar.conf"
RPT_CONF = "/etc/asterisk/rpt.conf"
MODULES_CONF = "/etc/asterisk/modules.conf"
REG_CANDIDATES = (
    "/etc/asterisk/rpt_http_registrations.conf",
    "/etc/asterisk/rpt_http_registration.conf",
)
BACKUP_DIR = "/var/backups/allstar"
SELF = "/usr/local/bin/allstar.py"

# Matches [name], [name](template) and [name](!) with an optional comment.
HEADER_RE = re.compile(r"^\[([^\]]+)\]\s*(\([^)]*\))?\s*(;.*)?$")


def require_deps(web=True):
    missing = []
    if serial is None:
        missing.append("python3-serial")
    if alsaaudio is None:
        missing.append("python3-alsaaudio")
    if web and Flask is None:
        missing.append("python3-flask")
    if missing:
        sys.exit("missing packages:  sudo apt install " + " ".join(missing))


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

DEFAULTS = {
    "serial": {
        "port": "/dev/hri200",
        "baudrate": "38400",
        "poll_interval": "0.2",          # 5 Hz; WIRES-X uses 1 Hz
    },
    "radio": {
        "model": "ftm400d",              # ftm400d | ft7800r | custom
        "frequency": "434.5000",
        "mode": "fm",                    # fm | digital
        "narrow": "no",
        "power": "low",                  # high | mid | low
        "tone_mode": "off",              # off | ctcss | dcs
        "ctcss": "88.5",
        "dcs": "23",
    },
    "audio": {
        "device": "plughw:CARD=codec,DEV=0",
        "card": "codec",
        "set_mixer": "yes",
        "tx_level": "47",                # amixer 'Speaker' - out to radio
        "rx_level": "45",                # amixer 'PCM'     - in from radio
        "rx_open_mute_ms": "40",         # suppress the squelch-opening transient
    },
    "usrp": {
        "local_port": "34001",           # we listen here, Asterisk sends here
        "remote_host": "127.0.0.1",
        "remote_port": "32001",          # Asterisk listens here
        "tx_tail_ms": "60",              # hold PTT after the last audio packet
        "jitter_frames": "3",            # buffer before playback starts
    },
    "web": {
        "enabled": "yes",
        "host": "0.0.0.0",
        "port": "8080",
        "username": "asl3",
        "password_hash": "",
        "secret_key": "",
    },
    "daemon": {
        "loglevel": "info",
    },
}


def load_config(path=None):
    # Resolved at call time, not at definition time. A default argument is
    # bound once when the module loads, so `--config` would have been read
    # into the signature before main() ever set it, and every later call
    # would have gone to /etc/allstar.conf regardless.
    if path is None:
        path = CONFIG_PATH
    cfg = configparser.ConfigParser(inline_comment_prefixes=(";",))
    cfg.read_dict(DEFAULTS)
    if path and os.path.exists(path):
        cfg.read(path)
    return cfg


def read_lines(path):
    with open(path) as fh:
        return fh.read().split("\n")


def write_lines(path, lines):
    """
    Write through a temporary file in the same directory and rename, so a
    full disk or a crash mid-write cannot leave a truncated config behind.
    """
    tmp = path + ".allstar.tmp"
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines))
    if os.path.exists(path):
        st = os.stat(path)
        os.chmod(tmp, st.st_mode)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError:
            pass
    os.replace(tmp, path)


def backup(path):
    if not os.path.exists(path):
        return
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(path, "%s/%s.%s" % (BACKUP_DIR, os.path.basename(path), stamp))


def find_stanza(lines, name):
    for i, ln in enumerate(lines):
        m = HEADER_RE.match(ln)
        if m and m.group(1).strip() == name:
            return i
    return None


def stanza_end(lines, start):
    for j in range(start + 1, len(lines)):
        if HEADER_RE.match(lines[j]):
            return j
    return len(lines)


def reg_conf():
    """
    The registration file is rpt_http_registrations.conf - with an s. Some
    documentation drops it, so try both and use whichever exists. Creating
    the wrong name looks like it worked while registering nothing.
    """
    for p in REG_CANDIDATES:
        if os.path.exists(p):
            return p
    return None


def current_node():
    """The node whose stanza carries our USRP rxchannel."""
    if not os.path.exists(RPT_CONF):
        return None
    lines = read_lines(RPT_CONF)
    for i, ln in enumerate(lines):
        m = HEADER_RE.match(ln)
        if not m or not m.group(1).strip().isdigit():
            continue
        for j in range(i + 1, stanza_end(lines, i)):
            if re.match(r"^\s*rxchannel\s*=\s*USRP/", lines[j]):
                return m.group(1).strip()
    return None


def read_node():
    """Node number and callsign for the node carrying our rxchannel."""
    out = {"node": "", "callsign": ""}
    node = current_node()
    if not node:
        return out
    out["node"] = node
    lines = read_lines(RPT_CONF)
    i = find_stanza(lines, node)
    if i is not None:
        for j in range(i + 1, stanza_end(lines, i)):
            m = re.match(r"^\s*idrecording\s*=\s*\|i(\S+)", lines[j])
            if m:
                out["callsign"] = m.group(1)
                break
    return out


# --------------------------------------------------------------------------
# HRI-200 serial protocol
# --------------------------------------------------------------------------

SOH = 0x01
EOT = 0x04

# D1M template. Payload is 67 characters, length field 0x43 = 67.
FREQ_TEMPLATE = ("D1M0043{M}000{F}-000.00000{N}{T}{C}{D}000{P}0"
                 "{F}+000.00000010887540002")

MODE_FM, MODE_DIGITAL = "4", "7"
TONE_OFF, TONE_CTCSS, TONE_DCS = "1", "2", "3"
POWER_HIGH, POWER_MID, POWER_LOW = "0", "1", "2"

MODES = {"fm": MODE_FM, "digital": MODE_DIGITAL}
TONE_MODES = {"off": TONE_OFF, "ctcss": TONE_CTCSS, "dcs": TONE_DCS}
POWERS = {"high": POWER_HIGH, "mid": POWER_MID, "low": POWER_LOW}

# Mixer levels, per radio. The control names do not describe their functions:
# "Speaker" is the transmit level OUT to the radio, "PCM" the receive level IN.
# The codec fixes the ranges: Speaker 0-47, PCM 0-55.
#
# Different radios present different levels on the data connector and want
# different drive, so a setting that works for one does not for another. These
# are starting points to measure from, not gospel.
#
# "controllable" says whether the radio answers D1V0000 and can therefore be
# tuned by the host. It only decides how long detection waits - what the radio
# actually replies always wins, so swapping radios corrects itself.
RADIO_PROFILES = {
    "ftm400d": {"label": "Yaesu FTM-400D", "tx": 47, "rx": 45,
                "controllable": True},
    # 26 is a long way below the FTM-400D's 47 - about -21 dB on this codec's
    # roughly 1 dB per step scale. Measured, not guessed: the FT-7800R's data
    # connector is far more sensitive on input.
    "ft7800r": {"label": "Yaesu FT-7800R", "tx": 26, "rx": 40,
                "controllable": False},
    "custom":  {"label": "Other radio", "controllable": None},
}

# D1P / D1C status byte
STATUS_RX = 0x10
STATUS_TX = 0x20


def frame(payload: str) -> bytes:
    """Wrap an ASCII payload in SOH ... EOT."""
    return bytes([SOH]) + payload.encode("ascii") + bytes([EOT])


def build_d1m(mhz, mode=MODE_FM, narrow=False, power=POWER_LOW,
              tone_mode=TONE_OFF, ctcss=88.5, dcs=23):
    """
    Build the channel configuration frame.

    Both tone fields are always populated - the box keeps CTCSS and DCS
    independently of which mode is selected, and never clears either.
    """
    f = "%09.5f" % mhz                       # 145.28750, exactly 9 characters
    if len(f) != 9:
        raise ValueError("frequency out of range: %r" % mhz)
    cmd = (FREQ_TEMPLATE
           .replace("{M}", mode)
           .replace("{F}", f)
           .replace("{N}", "1" if narrow else "0")
           .replace("{T}", tone_mode)
           .replace("{C}", "%03d" % int(ctcss))   # truncated, not rounded
           .replace("{D}", "%03d" % int(dcs))
           .replace("{P}", power))
    body = cmd[3:]
    assert int(body[:4], 16) == len(body) - 4, "D1M length field does not match"
    return cmd


# --------------------------------------------------------------------------
# USRP framing
# --------------------------------------------------------------------------

USRP_HDR = struct.Struct(">4sIIIIIII")   # 32 bytes, network byte order
USRP_HDR_LEN = USRP_HDR.size
USRP_SAMPLES = 160                       # 20 ms at 8 kHz
USRP_PAYLOAD = USRP_SAMPLES * 2

USRP_TYPE_VOICE = 0
USRP_TYPE_DTMF = 1
USRP_TYPE_TEXT = 2

SILENCE = b"\x00" * USRP_PAYLOAD


def usrp_pack(seq, keyup, payload=b"", ptype=USRP_TYPE_VOICE, talkgroup=0):
    return USRP_HDR.pack(b"USRP", seq & 0xFFFFFFFF, 0, 1 if keyup else 0,
                         talkgroup, ptype, 0, 0) + payload


def usrp_unpack(data):
    """Return (keyup, ptype, payload) or None if this is not a USRP frame."""
    if len(data) < USRP_HDR_LEN:
        return None
    eye, seq, memory, keyup, tg, ptype, mpxid, reserved = \
        USRP_HDR.unpack(data[:USRP_HDR_LEN])
    if eye != b"USRP":
        return None
    return bool(keyup), ptype, data[USRP_HDR_LEN:]


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# The bridge
# --------------------------------------------------------------------------

class Bridge:

    def __init__(self, cfg):
        self.cfg = cfg
        self.log = logging.getLogger("allstar")

        self.running = threading.Event()
        self.reload_requested = threading.Event()

        # --- shared state -------------------------------------------------
        self.ptt = False                 # what we are telling the radio
        self.ptt_dirty = threading.Event()   # poll immediately on change
        self.sql_open = False            # squelch, from the box
        self.last_d1p = 0.0
        self.radio_present = False
        self.tx_active = False           # confirmed by D1P bit 0x20
        self.usrp_keyed = False          # Asterisk has keyed us
        self.last_tx_audio = 0.0
        self.remote_addr = None          # learned from incoming packets

        self.tx_queue = queue.Queue(maxsize=50)   # 1 s of audio
        self.usrp_seq = 0
        self.seq_lock = threading.Lock()

        self.ser = None
        self.sock = None
        self.pcm_in = None
        self.pcm_out = None
        self._rxbuf = bytearray()

        self.stats = {"rx_frames": 0, "tx_frames": 0, "serial_frames": 0}

    # -- serial ------------------------------------------------------------

    def open_serial(self):
        port = self.cfg.get("serial", "port")
        # DTR/RTS must be low before open - the MCU treats them as a reset
        # and the radio restarts and loses its frequency.
        ser = serial.Serial()
        ser.port = port
        ser.baudrate = self.cfg.getint("serial", "baudrate")
        ser.timeout = 0
        ser.dtr = False
        ser.rts = False
        ser.open()
        self.ser = ser
        self.log.info("serial port %s open", port)

    def send(self, payload):
        self.log.debug("-> %s", payload)
        self.ser.write(frame(payload))

    def read_frames(self, timeout=0.0):
        """Collect complete SOH..EOT frames from the port."""
        deadline = time.monotonic() + timeout
        out = []
        while True:
            data = self.ser.read(512)
            if data:
                self._rxbuf.extend(data)
                while True:
                    start = self._rxbuf.find(SOH)
                    if start < 0:
                        del self._rxbuf[:]
                        break
                    end = self._rxbuf.find(EOT, start + 1)
                    if end < 0:
                        del self._rxbuf[:start]
                        break
                    payload = bytes(self._rxbuf[start + 1:end])
                    del self._rxbuf[:end + 1]
                    try:
                        text = payload.decode("ascii")
                    except UnicodeDecodeError:
                        continue
                    self.stats["serial_frames"] += 1
                    self.log.debug("<- %s", text)
                    out.append(text)
            if out or time.monotonic() >= deadline:
                return out
            time.sleep(0.005)

    def expect(self, prefix, timeout=3.0):
        """Wait for a frame starting with prefix. Other frames are handled."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for f in self.read_frames(0.05):
                self.handle_serial_frame(f)
                if f.startswith(prefix):
                    return f
        return None

    def handle_serial_frame(self, f):
        if f.startswith("B") and len(f) >= 2:
            # The D1P pushes are lower latency and authoritative. Only fall
            # back to the poll response if the box has gone quiet on them.
            if time.monotonic() - self.last_d1p > 2.0:
                self.set_squelch(f[1] == "1")
        elif f.startswith("D1P") or f.startswith("D1C"):
            # D1P0004<pppp> - length field is four chars, so the status byte
            # is the LAST two characters of the frame.
            try:
                status = int(f[-2:], 16)
            except ValueError:
                return
            self.last_d1p = time.monotonic()
            self.set_squelch(bool(status & STATUS_RX))
            self.tx_active = bool(status & STATUS_TX)
        elif f.startswith("D1V0020"):
            self.radio_present = True

    def set_squelch(self, state):
        if state != self.sql_open:
            self.sql_open = state
            self.log.debug("squelch %s", "OPEN" if state else "closed")

    def handshake(self):
        """Startup sequence. Returns True if the radio answered."""
        self.log.info("handshake...")

        for attempt in range(5):
            self.send("M00")
            if self.expect("M00", 2.0):
                break
            self.log.warning("no answer to M00 (attempt %d)", attempt + 1)
        else:
            raise RuntimeError(
                "HRI-200 does not answer M00 - flash switch in programming mode, "
                "or something else is holding the port")

        self.send("R6423")
        info = self.expect("R", 2.0)
        if info:
            self.log.info("device: %s", decode_r6423(info))

        self.send("P010000")
        self.expect("B", 2.0)

        # A controllable radio needs several seconds before it answers: in the
        # reference capture WIRES-X got nothing at t=1.0 s or t=2.1 s and only
        # succeeded at t=4.1 s. Keep the P poll running throughout.
        #
        # A plain analogue radio never answers at all. A capture of WIRES-X
        # with an FT-7800R shows D1V0000 sent 37 times over 54 seconds with no
        # reply - and WIRES-X then never sends D1M either, because there is
        # nothing to configure. A radio declared analogue is still asked, just
        # not for as long: long enough to notice that someone swapped in a
        # controllable set, without spending twelve seconds every startup
        # waiting for a reply that is not coming.
        profile = RADIO_PROFILES.get(
            self.cfg.get("radio", "model", fallback="custom").lower(), {})
        expect_controllable = profile.get("controllable")
        deadline = time.monotonic() + (3.0 if expect_controllable is False
                                       else 12.0)
        while time.monotonic() < deadline and not self.radio_present:
            self.send("D1V0000")
            self.expect("D1V", 1.2)
            if not self.radio_present:
                self.send("P010000")
                self.expect("B", 0.3)

        if self.radio_present:
            self.log.info("radio found")
            d1m = build_d1m(
                self.cfg.getfloat("radio", "frequency"),
                mode=MODES[self.cfg.get("radio", "mode").lower()],
                narrow=self.cfg.getboolean("radio", "narrow"),
                power=POWERS[self.cfg.get("radio", "power").lower()],
                tone_mode=TONE_MODES[self.cfg.get("radio", "tone_mode").lower()],
                ctcss=self.cfg.getfloat("radio", "ctcss"),
                dcs=self.cfg.getint("radio", "dcs"))
            self.send(d1m)
            if self.expect("D1M", 3.0):
                self.log.info("channel set: %.4f MHz",
                              self.cfg.getfloat("radio", "frequency"))
            else:
                self.log.warning("no D1M reply")
        elif expect_controllable is False:
            # Not a failure. The poll loop carries PTT and squelch and is
            # already working - the box has answered every poll throughout the
            # detection attempts. Only the channel settings are out of reach.
            self.log.info("radio does not identify itself, as expected for "
                          "this model. Set frequency, power and tone on the "
                          "radio; PTT, squelch and audio work normally.")
        else:
            self.log.warning("the radio does not identify itself, so its "
                             "frequency, power and tone cannot be set from "
                             "here. Set those on the radio itself.")
            self.log.warning("If this radio should be controllable it is in "
                             "the wrong mode: power it off and on holding "
                             "[D/X]+[GM] until the display reads HRI-200. "
                             "[D/X] alone gives PDN mode, which will not work.")

        self.send("D1B00010")
        self.expect("D1B", 1.0)
        self.send("D1C0000")
        self.expect("D1C", 1.0)
        return True

    def serial_thread(self):
        """Owns the port: polls, carries PTT, parses squelch."""
        interval = self.cfg.getfloat("serial", "poll_interval")
        next_poll = 0.0
        while self.running.is_set():
            now = time.monotonic()
            if now >= next_poll or self.ptt_dirty.is_set():
                self.ptt_dirty.clear()
                # PTT is asserted by WHAT you poll with, not a one-shot.
                self.send("P100000" if self.ptt else "P010000")
                next_poll = now + interval
            for f in self.read_frames(0.005):
                self.handle_serial_frame(f)

    def set_ptt(self, state):
        if state != self.ptt:
            self.ptt = state
            self.ptt_dirty.set()          # poll now, do not wait for the timer
            self.log.debug("PTT %s", "ON" if state else "OFF")

    # -- audio -------------------------------------------------------------

    def apply_mixer(self):
        if not self.cfg.getboolean("audio", "set_mixer"):
            return
        card = self.cfg.get("audio", "card")
        # The control names do not match their functions: 'Speaker' is the
        # level OUT to the radio, 'PCM' the level IN from it.
        settings = [
            ("Bass Boost", "off"),
            ("Speaker", self.cfg.get("audio", "tx_level")),
            ("PCM", self.cfg.get("audio", "rx_level")),
        ]
        for control, value in settings:
            try:
                subprocess.run(["amixer", "-q", "-c", card, "sset",
                                control, value], check=True,
                               capture_output=True, timeout=5)
            except (subprocess.CalledProcessError, FileNotFoundError,
                    subprocess.TimeoutExpired) as e:
                self.log.warning("could not set mixer %s=%s (%s)",
                                 control, value, e)

    def open_audio(self):
        device = self.cfg.get("audio", "device")
        self.pcm_in = alsaaudio.PCM(
            alsaaudio.PCM_CAPTURE, alsaaudio.PCM_NORMAL,
            device=device, channels=1, rate=8000,
            format=alsaaudio.PCM_FORMAT_S16_LE, periodsize=USRP_SAMPLES)
        self.pcm_out = alsaaudio.PCM(
            alsaaudio.PCM_PLAYBACK, alsaaudio.PCM_NORMAL,
            device=device, channels=1, rate=8000,
            format=alsaaudio.PCM_FORMAT_S16_LE, periodsize=USRP_SAMPLES)
        self.log.info("audio open on %s (8 kHz mono)", device)

    def capture_thread(self):
        """
        Radio -> Asterisk. The capture clock paces this loop; do not add
        sleeps here or chan_usrp will complain about its receive queue.
        """
        mute_periods = int(self.cfg.getfloat("audio", "rx_open_mute_ms") / 20)
        keyed = False
        muted = 0
        pending = bytearray()

        while self.running.is_set():
            try:
                length, data = self.pcm_in.read()
            except alsaaudio.ALSAAudioError as e:
                self.log.warning("capture: %s", e)
                time.sleep(0.05)
                continue
            if length <= 0 or not data:
                continue

            pending.extend(data)
            while len(pending) >= USRP_PAYLOAD:
                chunk = bytes(pending[:USRP_PAYLOAD])
                del pending[:USRP_PAYLOAD]

                # Simplex: never feed our own transmission back upstream.
                want = self.sql_open and not self.ptt

                if want and not keyed:
                    keyed = True
                    muted = mute_periods
                    self.log.debug("RX start")
                if not want and keyed:
                    keyed = False
                    self.send_usrp(b"", keyup=False)   # end of transmission
                    self.log.debug("RX slut")

                if keyed:
                    # The radio's AF stage unmuting is a DC step that saturates
                    # regardless of gain. Drop the first few periods.
                    if muted > 0:
                        muted -= 1
                        chunk = SILENCE
                    self.send_usrp(chunk, keyup=True)

    def playback_thread(self):
        """
        Asterisk -> radio. Writes silence when idle so the stream stays
        clocked - the blocking ALSA write is the ONLY thing pacing this
        loop. Do not wait on the queue as well or the loop runs at half
        rate and underruns continuously.
        """
        tail = self.cfg.getfloat("usrp", "tx_tail_ms") / 1000.0
        prefill = self.cfg.getint("usrp", "jitter_frames")
        streaming = False

        while self.running.is_set():
            depth = self.tx_queue.qsize()

            # Build a small buffer before starting, so ordinary network
            # jitter does not tear holes in the first word.
            if not streaming and depth >= prefill:
                streaming = True
            elif streaming and depth == 0 and not self.usrp_keyed:
                streaming = False

            chunk = None
            if streaming:
                try:
                    chunk = self.tx_queue.get_nowait()
                except queue.Empty:
                    chunk = None          # underrun mid-transmission

            # PTT stays up until the queue has drained plus a short tail,
            # otherwise the end of every transmission gets clipped.
            want_ptt = (self.usrp_keyed
                        or streaming
                        or depth > 0
                        or (time.monotonic() - self.last_tx_audio) < tail)
            self.set_ptt(bool(want_ptt))

            try:
                self.pcm_out.write(chunk if chunk is not None else SILENCE)
            except alsaaudio.ALSAAudioError as e:
                self.log.warning("playback: %s", e)
                time.sleep(0.02)

    # -- USRP --------------------------------------------------------------

    def open_socket(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", self.cfg.getint("usrp", "local_port")))
        self.sock.settimeout(0.5)
        self.remote_addr = (self.cfg.get("usrp", "remote_host"),
                            self.cfg.getint("usrp", "remote_port"))
        self.log.info("USRP: listening on %d, sending to %s:%d",
                      self.cfg.getint("usrp", "local_port"),
                      self.remote_addr[0], self.remote_addr[1])

    def send_usrp(self, payload, keyup):
        with self.seq_lock:
            seq = self.usrp_seq
            self.usrp_seq = (self.usrp_seq + 1) & 0xFFFFFFFF
        try:
            self.sock.sendto(usrp_pack(seq, keyup, payload), self.remote_addr)
            self.stats["tx_frames"] += 1
        except OSError as e:
            self.log.debug("usrp send: %s", e)

    def usrp_thread(self):
        while self.running.is_set():
            try:
                data, addr = self.sock.recvfrom(2048)
            except socket.timeout:
                # No traffic. If Asterisk stopped mid-transmission, unkey.
                if self.usrp_keyed:
                    self.log.warning("USRP silent while keyed - dropping PTT")
                    self.usrp_keyed = False
                continue
            except OSError:
                continue

            parsed = usrp_unpack(data)
            if parsed is None:
                continue
            keyup, ptype, payload = parsed
            self.stats["rx_frames"] += 1

            if ptype != USRP_TYPE_VOICE:
                continue          # metadata / DTMF - app_rpt handles its own

            self.usrp_keyed = keyup
            if keyup and payload:
                self.last_tx_audio = time.monotonic()
                for i in range(0, len(payload), USRP_PAYLOAD):
                    chunk = payload[i:i + USRP_PAYLOAD]
                    if len(chunk) < USRP_PAYLOAD:
                        chunk = chunk + SILENCE[:USRP_PAYLOAD - len(chunk)]
                    try:
                        self.tx_queue.put_nowait(chunk)
                    except queue.Full:
                        # Late audio is worse than no audio - drop the oldest.
                        try:
                            self.tx_queue.get_nowait()
                            self.tx_queue.put_nowait(chunk)
                        except (queue.Empty, queue.Full):
                            pass

    # -- lifecycle ---------------------------------------------------------

    def start(self):
        self.apply_mixer()
        self.open_audio()
        self.open_serial()
        if not self.handshake():
            raise RuntimeError("startup failed")
        self.open_socket()

        self.running.set()
        self.threads = [
            threading.Thread(target=self.serial_thread, name="serial"),
            threading.Thread(target=self.capture_thread, name="capture"),
            threading.Thread(target=self.playback_thread, name="playback"),
            threading.Thread(target=self.usrp_thread, name="usrp"),
        ]
        for t in self.threads:
            t.daemon = True
            t.start()
        self.log.info("running")

    def stop(self):
        self.log.info("shutting down")
        self.running.clear()
        for t in getattr(self, "threads", []):
            t.join(timeout=2.0)
        if self.ser and self.ser.is_open:
            try:
                self.send("P010000")      # PTT off, unconditionally
                time.sleep(0.1)
                self.send("P010010")      # what WIRES-X sends when it exits
                time.sleep(0.1)
            except Exception:
                pass
            self.ser.close()
        for pcm in (self.pcm_in, self.pcm_out):
            if pcm:
                try:
                    pcm.close()
                except Exception:
                    pass
        if self.sock:
            self.sock.close()

    def run(self):
        self.start()
        try:
            while self.running.is_set():
                time.sleep(1.0)
                if self.reload_requested.is_set():
                    self.reload_requested.clear()
                    self.log.info("SIGHUP: reloading configuration")
                    self.restart()
        finally:
            self.stop()

    def restart(self):
        """
        The box only reads D1M during initialisation - changing frequency,
        tone or power means closing the port and repeating the handshake.
        """
        self.running.clear()
        for t in self.threads:
            t.join(timeout=2.0)
        if self.ser and self.ser.is_open:
            self.ser.close()
        self.radio_present = False
        self.cfg = load_config(self.config_path)
        self.open_serial()
        self.handshake()
        self.running.set()
        self.threads = [
            threading.Thread(target=self.serial_thread, name="serial"),
            threading.Thread(target=self.capture_thread, name="capture"),
            threading.Thread(target=self.playback_thread, name="playback"),
            threading.Thread(target=self.usrp_thread, name="usrp"),
        ]
        for t in self.threads:
            t.daemon = True
            t.start()


def decode_r6423(payload):
    """
    Device info. Hex-encoded ASCII at an odd offset: skip the first
    character after 'R', then decode pairwise.
    """
    try:
        hexpart = payload[2:]
        if len(hexpart) % 2:
            hexpart = hexpart[:-1]
        return bytes.fromhex(hexpart).decode("ascii", "replace")
    except ValueError:
        return payload


STYLE = """
:root{
  --panel:#b8bdb2; --panel-hi:#c7cbc1; --panel-lo:#9aa094;
  --ink:#23262a; --ink-soft:#5c625c; --paper:#e9e7e0;
  --lcd-bg:#1b1e1a; --lcd:#e3b23c; --lcd-dim:#6b5622;
  --signal:#a83a28; --ok:#46664b; --rule:#8f958a;
  --sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,
         "Helvetica Neue",Arial,sans-serif;
  --mono:ui-monospace,"DejaVu Sans Mono","SF Mono",Menlo,Consolas,monospace;
}
*{box-sizing:border-box}
body{margin:0;background:var(--panel);color:var(--ink);font-family:var(--sans);
  font-size:15px;line-height:1.5;
  background-image:linear-gradient(rgba(255,255,255,.16),rgba(0,0,0,.06));}
.wrap{max-width:560px;margin:0 auto;padding:20px 16px 56px}

/* Silkscreen label: the vocabulary of an equipment front panel. */
.lbl{font-size:11px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;
  color:var(--ink-soft)}

header{display:flex;align-items:baseline;justify-content:space-between;
  gap:12px;padding:6px 2px 16px;border-bottom:2px solid var(--ink)}
header h1{margin:0;font-size:15px;font-weight:700;letter-spacing:.16em;
  text-transform:uppercase}
header .sub{font-family:var(--mono);font-size:12px;color:var(--ink-soft)}
header a{color:var(--ink-soft);font-size:11px;letter-spacing:.12em;
  text-transform:uppercase;text-decoration:none;border-bottom:1px solid var(--rule)}
header a:hover{color:var(--ink)}

/* Signature element: the readout, built like the radio's own display. */
.readout{margin:18px 0;background:var(--lcd-bg);border-radius:3px;
  padding:16px 18px 14px;box-shadow:inset 0 2px 7px rgba(0,0,0,.75),
  0 1px 0 rgba(255,255,255,.35)}
.readout .freq{font-family:var(--mono);font-size:clamp(34px,10vw,50px);
  font-weight:700;color:var(--lcd);letter-spacing:.02em;line-height:1;
  text-shadow:0 0 14px rgba(227,178,60,.3)}
.readout .freq .u{font-size:.36em;letter-spacing:.16em;margin-left:.5em;
  color:var(--lcd-dim)}
.readout .meta{display:flex;flex-wrap:wrap;gap:14px;margin-top:12px;
  font-family:var(--mono);font-size:11px;color:var(--lcd-dim);
  letter-spacing:.1em;text-transform:uppercase}
.lamps{display:flex;gap:16px;margin-top:13px;padding-top:11px;
  border-top:1px solid #2e332c}
.lamp{display:flex;align-items:center;gap:7px;font-family:var(--mono);
  font-size:11px;letter-spacing:.12em;color:#5d635a;text-transform:uppercase}
.lamp i{width:8px;height:8px;border-radius:50%;background:#333830;
  transition:background .25s,box-shadow .25s}
.lamp.on{color:#9aa38f}
.lamp.on i{background:var(--ok);box-shadow:0 0 8px rgba(70,102,75,.9)}
.lamp.err i{background:var(--signal);box-shadow:0 0 8px rgba(168,58,40,.9)}
/* Transmitting is the one state worth catching from across the room. */
#lTx.on i{background:var(--signal);box-shadow:0 0 9px rgba(168,58,40,1)}
#lTx.on{color:#c58a7c}

.card{background:var(--paper);border:1px solid var(--panel-lo);border-radius:3px;
  padding:16px;margin:14px 0;box-shadow:0 1px 0 rgba(255,255,255,.4)}
.card h2{margin:0 0 14px;font-size:11px;font-weight:700;letter-spacing:.14em;
  text-transform:uppercase;color:var(--ink-soft);
  padding-bottom:9px;border-bottom:1px solid var(--rule)}
.row{display:flex;gap:12px;flex-wrap:wrap}
.row>*{flex:1 1 150px;min-width:0}
.f{margin-bottom:13px}
.f label{display:block;margin-bottom:5px}
input,select{width:100%;padding:9px 10px;font-family:var(--mono);font-size:14px;
  color:var(--ink);background:#fff;border:1px solid var(--panel-lo);
  border-radius:2px}
input:focus,select:focus{outline:2px solid var(--ink);outline-offset:1px;
  border-color:var(--ink)}
.hint{font-size:12px;color:var(--ink-soft);margin-top:5px}
.chk{display:flex;align-items:center;gap:9px}

.picker{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px}
.picker label{flex:1 1 130px}
.picker input{position:absolute;opacity:0;width:0;height:0}
.picker span{display:block;text-align:center;padding:10px 8px;font-size:13px;
  background:#fff;border:1px solid var(--panel-lo);border-radius:2px;
  cursor:pointer;color:var(--ink-soft)}
.picker input:checked+span{border-color:var(--ink);color:var(--ink);
  background:#dcdcd3;box-shadow:inset 0 0 0 1px var(--ink)}
.picker input:focus-visible+span{outline:2px solid var(--ink);outline-offset:2px}

/* An inert control that still looks live is worse than one that looks off. */
.tune.off{opacity:.4;pointer-events:none}
.dumb{background:#d8cdb4;border-left:3px solid #96702a;padding:11px 13px;
  font-size:13px;margin-bottom:14px;border-radius:2px}
.chk input{width:auto;flex:none}

button{font-family:var(--sans);font-size:11px;font-weight:700;letter-spacing:.13em;
  text-transform:uppercase;padding:10px 16px;color:var(--paper);
  background:var(--ink);border:none;border-radius:2px;cursor:pointer}
button:hover{background:#34383d}
button:active{transform:translateY(1px)}
button:disabled{opacity:.45;cursor:default;transform:none}
button.ghost{background:transparent;color:var(--ink);
  border:1px solid var(--ink)}
button.ghost:hover{background:rgba(0,0,0,.07)}
button.danger{background:var(--signal)}
button.danger:hover{background:#bd4531}
button:focus-visible{outline:2px solid var(--ink);outline-offset:2px}

.links{font-family:var(--mono);font-size:13px}
.links .none{color:var(--ink-soft);font-family:var(--sans);font-size:13px}
.link{display:flex;align-items:center;justify-content:space-between;gap:10px;
  padding:8px 0;border-bottom:1px solid var(--rule)}
.link:last-child{border-bottom:none}
.link button{padding:6px 11px}
.link em{display:block;font-family:var(--sans);font-size:11px;font-style:normal;
  letter-spacing:.08em;text-transform:uppercase;color:var(--ink-soft);margin-top:2px}
.via{margin-top:11px;padding-top:10px;border-top:1px solid var(--rule);
  font-size:13px;color:var(--ink-soft);word-break:break-word}
.via .lbl{display:block;margin-bottom:4px}

#msg{position:sticky;bottom:0;margin-top:16px;padding:12px 14px;border-radius:2px;
  font-size:14px;display:none}
#msg.ok{display:block;background:var(--ok);color:#eef2ec}
#msg.bad{display:block;background:var(--signal);color:#f6ece9}

.warn{background:#d8cdb4;border-left:3px solid #96702a;padding:11px 13px;
  font-size:13px;margin:14px 0;border-radius:2px}

footer{margin-top:26px;padding-top:14px;border-top:1px solid var(--rule);
  font-size:11px;color:var(--ink-soft);letter-spacing:.1em;
  text-transform:uppercase}
footer .who{font-family:var(--mono)}
footer strong{color:var(--ink)}
/* The credit line reads as prose, so it drops the uppercase tracking the
   rest of the footer uses. */
footer .dep{margin-top:9px;text-transform:none;letter-spacing:0;
  font-size:12px;line-height:1.45;max-width:46ch}
footer a{color:var(--ink-soft);text-decoration:underline;
  text-underline-offset:2px}
footer a:hover{color:var(--ink)}
.login{max-width:340px;margin:12vh auto;padding:0 16px}
.login .card{padding:22px}
.login h1{margin:0 0 4px;font-size:15px;letter-spacing:.16em;
  text-transform:uppercase}
.login .sub{font-family:var(--mono);font-size:12px;color:var(--ink-soft);
  margin-bottom:20px}
.err{background:var(--signal);color:#f6ece9;padding:9px 12px;font-size:13px;
  border-radius:2px;margin-bottom:14px}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
"""

LOGIN_HTML = """<!doctype html><html lang="sv"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sign in - HRI-200</title><style>{{ style }}</style></head><body>
<div class="login"><form method="post" class="card">
<h1>Allstar-HRI-200</h1>
<div class="sub">Yaesu HRI-200 to AllStarLink bridge<br>by SA7BNB</div>
{% if error %}<div class="err">{{ error }}</div>{% endif %}
<div class="f"><label class="lbl" for="u">User</label>
<input id="u" name="username" autocomplete="username" autofocus required></div>
<div class="f"><label class="lbl" for="p">Password</label>
<input id="p" name="password" type="password" autocomplete="current-password"
 required></div>
<button type="submit" style="width:100%">Sign in</button>
</form></div></body></html>"""

PANEL_HTML = """<!doctype html><html lang="sv"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AllStar node{% if node.node %} {{ node.node }}{% endif %}</title>
<style>{{ style }}</style></head><body>
<div class="wrap">

<header>
  <div><h1>{{ release }}</h1>
  <div class="sub">{{ node.callsign or 'no callsign' }} &middot;
    node {{ node.node or '-' }}</div></div>
  <a href="{{ url_for('logout') }}">Sign out</a>
</header>

<div class="readout">
  <div class="freq" id="rFreq">{{ radio.frequency or '---.----' }}<span
    class="u">MHz</span></div>
  <div class="meta">
    <span id="rMode">{{ radio.mode|upper }}</span>
    <span id="rPower">{{ radio.power|upper }} PWR</span>
    <span id="rTone">{% if radio.tone_mode == 'ctcss' %}CTCSS {{ radio.ctcss }}
      {%- elif radio.tone_mode == 'dcs' %}DCS {{ radio.dcs }}
      {%- else %}NO TONE{% endif %}</span>
    <span id="rBw">{{ 'NARROW' if radio.narrow in ('yes','true','1') else 'WIDE' }}</span>
  </div>
  <div class="lamps">
    <span class="lamp" id="lRx"><i></i>RX</span>
    <span class="lamp" id="lTx"><i></i>TX</span>
    <span class="lamp" id="lBridge"><i></i>Bridge</span>
    <span class="lamp" id="lNode"><i></i>Asterisk</span>
    <span class="lamp" id="lReg"><i></i>Links <b id="nLinks">0</b></span>
  </div>
</div>

<form class="card" id="fRadio">
  <h2>Radio</h2>

  <div class="picker">
    {% for key, p in profiles.items() %}
    <label><input type="radio" name="model" value="{{ key }}"
      {{ 'checked' if radio.model == key }}
      data-tx="{{ p.tx|default('', true) }}" data-rx="{{ p.rx|default('', true) }}"
      data-ctl="{{ '' if p.controllable is none else (1 if p.controllable else 0) }}"
      ><span>{{ p.label }}</span></label>
    {% endfor %}
  </div>

  <div class="dumb" id="dumbRadio" style="display:none">
    <strong>This radio does not identify itself.</strong> It cannot be tuned
    from here &mdash; set frequency, power and tone on the radio. PTT, squelch
    and audio work normally, so the node is fully usable; only these controls
    are inert. A radio that should be controllable is in the wrong mode: power
    it on holding [D/X]&nbsp;+&nbsp;[GM] until the display reads HRI-200.
  </div>

  <div class="tune">
  <div class="row">
    <div class="f"><label class="lbl" for="freq">Frequency (MHz)</label>
      <input id="freq" name="frequency" value="{{ radio.frequency }}"
        inputmode="decimal" required></div>
    <div class="f"><label class="lbl" for="power">Power</label>
      <select id="power" name="power">
        {% for p in ['high','mid','low'] %}<option value="{{ p }}"
        {{ 'selected' if radio.power == p }}>{{ p|capitalize }}</option>
        {% endfor %}</select></div>
  </div>
  <div class="row">
    <div class="f"><label class="lbl" for="mode">Mode</label>
      <select id="mode" name="mode">
        <option value="fm" {{ 'selected' if radio.mode == 'fm' }}>FM</option>
        <option value="digital" {{ 'selected' if radio.mode == 'digital' }}
          >Digital</option></select></div>
    <div class="f"><label class="lbl" for="tone">Tone</label>
      <select id="tone" name="tone_mode">
        <option value="off" {{ 'selected' if radio.tone_mode == 'off' }}>None</option>
        <option value="ctcss" {{ 'selected' if radio.tone_mode == 'ctcss' }}>CTCSS</option>
        <option value="dcs" {{ 'selected' if radio.tone_mode == 'dcs' }}>DCS</option>
      </select></div>
  </div>
  <div class="row">
    <div class="f"><label class="lbl" for="ctcss">CTCSS (Hz)</label>
      <input id="ctcss" name="ctcss" value="{{ radio.ctcss }}" inputmode="decimal"></div>
    <div class="f"><label class="lbl" for="dcs">DCS code</label>
      <input id="dcs" name="dcs" value="{{ radio.dcs }}" inputmode="numeric"></div>
  </div>
  <div class="f chk"><input type="checkbox" id="narrow" name="narrow"
    {{ 'checked' if radio.narrow in ('yes','true','1') }}>
    <label class="lbl" for="narrow" style="margin:0">Narrow (12.5 kHz)</label></div>
  </div>
  <button type="submit" id="bRadio">Apply to radio</button>
  <div class="hint">The HRI-200 only reads its channel settings while it
    starts up, so the bridge re-runs its handshake. Audio drops for a couple
    of seconds; the node stays connected.</div>
</form>

<form class="card" id="fNode">
  <h2>Node identity</h2>
  <div class="row">
    <div class="f"><label class="lbl" for="node">Node number</label>
      <input id="node" name="node" value="{{ node.node }}" inputmode="numeric"
        required></div>
    <div class="f"><label class="lbl" for="callsign">Callsign</label>
      <input id="callsign" name="callsign" value="{{ node.callsign }}"
        autocapitalize="characters" required></div>
  </div>
  <div class="f"><label class="lbl" for="npw">Node password</label>
    <input id="npw" name="password" type="password" autocomplete="off"
      placeholder="leave blank to keep the current one">
    <div class="hint">From your AllStarLink portal. Private nodes
      (1000&ndash;1999) don't register and don't need one. Changing the node
      number updates the registration too.</div></div>
  <button type="submit">Save identity</button>
  <div class="hint">Saving restarts Asterisk. The node drops off the network
    for about ten seconds.</div>
</form>

<div class="card">
  <h2>Links</h2>
  <div class="links" id="links"><span class="none">Checking&hellip;</span></div>
  <div class="row" style="margin-top:14px">
    <div class="f" style="margin:0"><label class="lbl" for="target">Connect to node</label>
      <input id="target" inputmode="numeric" placeholder="55553"></div>
  </div>
  <div style="display:flex;gap:9px;margin-top:11px;flex-wrap:wrap">
    <button type="button" onclick="link('connect')">Connect</button>
    <button type="button" class="ghost" onclick="link('monitor')">Monitor only</button>
  </div>
</div>

<form class="card" id="fAudio">
  <h2>Audio levels</h2>
  <div class="row">
    <div class="f"><label class="lbl" for="tx">Transmit (0&ndash;47)</label>
      <input id="tx" name="tx_level" value="{{ radio.tx_level }}"
        type="number" min="0" max="47" inputmode="numeric" required></div>
    <div class="f"><label class="lbl" for="rx">Receive (0&ndash;55)</label>
      <input id="rx" name="rx_level" value="{{ radio.rx_level }}"
        type="number" min="0" max="55" inputmode="numeric" required></div>
  </div>
  <button type="submit">Set levels</button>
  <div class="hint">Transmit sets how loud you are on the air. If your voice
    sounds harsh or distorted to others, lower it. Receive sets how loud
    incoming audio reaches the node. Picking a radio above loads a starting
    point &mdash; measure or listen from there, since every radio drives the
    data connector differently.</div>
</form>

<form class="card" id="fPass">
  <h2>Panel access</h2>
  <div class="f"><label class="lbl" for="wpw">New password</label>
    <input id="wpw" name="password" type="password" autocomplete="new-password"
      placeholder="at least 8 characters">
    <div class="hint">For signing in to this panel. You'll be asked to sign in
      again.</div></div>
  <button type="submit">Change password</button>
</form>

<div class="card">
  <h2>Services</h2>
  <div style="display:flex;gap:9px;flex-wrap:wrap">
    <button type="button" class="ghost" onclick="svc('allstar','restart')"
      >Restart node</button>
    <button type="button" class="ghost" onclick="svc('asterisk','restart')"
      >Restart Asterisk</button>
  </div>
</div>

{% if default_password %}
<div class="warn"><strong>This panel still uses the default password.</strong>
  Anyone who can reach this address can retune your transmitter and change
  your node number. Set a new one under <strong>Panel access</strong> above.</div>
{% endif %}

<div id="msg"></div>
<footer>
  <div class="who">{{ release }} &middot; by <strong>SA7BNB</strong></div>
  <div class="dep">Runs on <a href="https://github.com/AllStarLink/ASL3"
    target="_blank" rel="noopener noreferrer">AllStarLink 3</a>, which does
    the linking. This software connects the HRI-200 to it.</div>
</footer>
</div>

<script>
const CSRF = {{ csrf|tojson }};

function say(text, good){
  const m = document.getElementById('msg');
  m.textContent = text; m.className = good ? 'ok' : 'bad';
  clearTimeout(say.t); say.t = setTimeout(() => m.className = '', 6000);
}

async function post(url, data){
  const r = await fetch(url, {
    method:'POST', headers:{'Content-Type':'application/json','X-CSRF':CSRF},
    body: JSON.stringify(data)
  });
  return r.json();
}

function busy(form, on){
  form.querySelectorAll('button').forEach(b => b.disabled = on);
}

async function submitForm(ev, url){
  ev.preventDefault();
  const form = ev.target;
  const data = {};
  new FormData(form).forEach((v,k) => data[k] = v);
  data.narrow = form.querySelector('[name=narrow]')?.checked || false;
  if (form.dataset.model) data.model = form.dataset.model;
  busy(form, true);
  try {
    const res = await post(url, data);
    say(res.ok ? res.message : res.error, res.ok);
    if (res.ok) { form.querySelector('[name=password]')?.setAttribute('value',''); refresh(); }
  } catch (e) { say('Could not reach the node: ' + e.message, false); }
  busy(form, false);
}

// Picking a radio loads its starting levels. Moving a level afterwards means
// they are no longer that radio's, so the choice falls back to Other -
// otherwise the button would claim a preset that is not in effect.
function radioPicked(el, loadLevels){
  if (loadLevels && el.dataset.tx) {
    document.getElementById('tx').value = el.dataset.tx;
    document.getElementById('rx').value = el.dataset.rx;
  }
  // An empty data-ctl means "unknown" - leave it to the status poll, which
  // reports what the radio actually did rather than what was declared.
  if (el.dataset.ctl === '') return;
  setTunable(el.dataset.ctl !== '0');
}

function setTunable(on){
  document.querySelector('#fRadio .tune').className = on ? 'tune' : 'tune off';
  document.getElementById('dumbRadio').style.display = on ? 'none' : '';
  document.getElementById('bRadio').disabled = !on;
}

document.querySelectorAll('input[name=model]').forEach(el => {
  el.addEventListener('change', () => radioPicked(el, true));
});

['tx','rx'].forEach(id => {
  document.getElementById(id).addEventListener('input', () => {
    const sel = document.querySelector('input[name=model]:checked');
    if (sel && sel.dataset.tx &&
        (document.getElementById('tx').value != sel.dataset.tx ||
         document.getElementById('rx').value != sel.dataset.rx)) {
      const other = document.querySelector('input[name=model][value=custom]');
      if (other) other.checked = true;
    }
  });
});

document.getElementById('fRadio').addEventListener('submit',
  e => submitForm(e, '/api/radio'));
document.getElementById('fNode').addEventListener('submit',
  e => submitForm(e, '/api/node'));
document.getElementById('fAudio').addEventListener('submit', e => {
  // The model lives in the radio card but decides the levels, so send it
  // along - otherwise saving levels would leave the two disagreeing.
  const sel = document.querySelector('input[name=model]:checked');
  if (sel) e.target.dataset.model = sel.value;
  submitForm(e, '/api/audio');
});
document.getElementById('fPass').addEventListener('submit', async e => {
  e.preventDefault();
  const pw = document.getElementById('wpw').value;
  if (pw.length < 8) { say('Use at least 8 characters.', false); return; }
  const res = await post('/api/webpass', {password: pw});
  say(res.ok ? res.message + ' Reloading\u2026' : res.error, res.ok);
  // The session is cleared server-side, so send the browser to the sign-in
  // page rather than leaving it on a panel that can no longer do anything.
  if (res.ok) setTimeout(() => location.href = '/login', 1800);
});

async function link(mode, target){
  target = target || document.getElementById('target').value.trim();
  if (!target) { say('Enter a node number first.', false); return; }
  const res = await post('/api/link', {mode, target});
  say(res.ok ? res.message : res.error, res.ok);
  if (res.ok) { document.getElementById('target').value = ''; setTimeout(refresh, 1200); }
}

async function svc(service, verb){
  const res = await post('/api/service', {service, verb});
  say(res.ok ? res.message : res.error, res.ok);
  setTimeout(refresh, 2500);
}

function lamp(id, on, err){
  const el = document.getElementById(id);
  el.className = 'lamp' + (on ? ' on' : (err ? ' err' : ''));
}

async function refresh(){
  try {
    const s = await (await fetch('/api/status')).json();
    lamp('lRx', s.rx);
    lamp('lTx', s.ptt);
    // Only trust this once the handshake has finished - before that the
    // bridge is down and we know nothing about the radio either way.
    if (s.bridge) setTunable(s.controllable);
    lamp('lBridge', s.bridge, !s.bridge);
    lamp('lNode', s.asterisk, !s.asterisk);
    lamp('lReg', s.links.length > 0);
    document.getElementById('nLinks').textContent = s.links.length;
    document.getElementById('rFreq').innerHTML =
      s.radio.frequency + '<span class="u">MHz</span>';
    document.getElementById('rPower').textContent = s.radio.power.toUpperCase() + ' PWR';
    document.getElementById('rMode').textContent = s.radio.mode.toUpperCase();

    const box = document.getElementById('links');
    const mine = new Set(s.links.map(l => l.node));
    // In the tree but not ours: reachable through a hub we joined, and not
    // ours to drop. Listed for context, without a button that would do nothing.
    const via = (s.tree || []).filter(n => !mine.has(n));

    // Built with DOM calls rather than HTML strings: node numbers go in as
    // text, and the click handler holds a reference instead of a quoted
    // string that has to survive three levels of escaping.
    box.textContent = '';
    if (!s.links.length) {
      const p = document.createElement('span');
      p.className = 'none';
      p.textContent = 'Not connected to any node.';
      box.appendChild(p);
    } else {
      s.links.forEach(l => {
        const row = document.createElement('div');
        row.className = 'link';
        const label = document.createElement('span');
        label.textContent = l.node;
        const sub = document.createElement('em');
        sub.textContent = (l.direction === 'OUT' ? 'outbound' : 'inbound')
          + (l.state && l.state !== 'ESTABLISHED'
             ? ' \u00b7 ' + l.state.toLowerCase() : '');
        label.appendChild(sub);
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'danger';
        btn.textContent = 'Disconnect';
        btn.addEventListener('click', () => link('disconnect', l.node));
        row.appendChild(label);
        row.appendChild(btn);
        box.appendChild(row);
      });
    }
    // Only meaningful alongside a link of our own - these are reachable
    // through it, so with no links there is nothing to be "also" reachable.
    if (via.length && s.links.length) {
      const d = document.createElement('div');
      d.className = 'via';
      const t = document.createElement('span');
      t.className = 'lbl';
      t.textContent = 'Also reachable';
      d.appendChild(t);
      d.appendChild(document.createTextNode(via.join(', ')));
      box.appendChild(d);
    }
  } catch (e) { /* node busy restarting; the next poll will catch up */ }
}

const picked = document.querySelector('input[name=model]:checked');
if (picked) radioPicked(picked, false);

refresh();
setInterval(refresh, 2000);
</script>
</body></html>"""


# --------------------------------------------------------------------------
# Web panel
# --------------------------------------------------------------------------

def hash_password(plain, iterations=200_000, salt=None):
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", plain.encode(), salt, iterations)
    return "pbkdf2$%d$%s$%s" % (iterations,
                                base64.b16encode(salt).decode().lower(),
                                base64.b16encode(dk).decode().lower())


def check_password(plain, stored):
    try:
        scheme, iters, salt_hex, want = stored.split("$")
        if scheme != "pbkdf2":
            return False
        got = hashlib.pbkdf2_hmac("sha256", plain.encode(),
                                  base64.b16decode(salt_hex.upper()),
                                  int(iters))
        # Constant time, so nobody can measure their way in.
        return hmac.compare_digest(base64.b16encode(got).decode().lower(), want)
    except (ValueError, TypeError):
        return False


def service_active(name):
    try:
        r = subprocess.run(["systemctl", "is-active", name],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() == "active"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def asterisk_rx(cmd, timeout=10):
    """
    Run an Asterisk CLI command and return its output.

    The exit code is ignored when there is output. Running as a user with no
    home directory makes the CLI print "Unable to access the running
    directory" and exit non-zero even though the command ran and the answer
    is on stdout. Trusting the exit code here loses that answer.
    """
    try:
        r = subprocess.run(["asterisk", "-rx", cmd], capture_output=True,
                           text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""
    if r.stdout.strip():
        return r.stdout
    return "" if r.returncode != 0 else r.stdout


def direct_links(node):
    """
    Links this node established itself, from 'rpt lstats':

        NODE   PEER            RECONNECTS  DIRECTION  CONNECT TIME  STATE
        55553  104.232.32.242  0           OUT        00:01:32:385  ESTABLISHED

    These are the only ones we can disconnect. 'rpt nodes' shows the whole
    tree, including everything attached to a hub we joined - a disconnect
    button for those would promise something we cannot deliver.
    """
    if not node:
        return []
    out = asterisk_rx("rpt lstats %s" % node)
    links = []
    for line in out.split("\n"):
        parts = line.split()
        if len(parts) < 5 or not parts[0].isdigit() or parts[0] == node:
            continue
        links.append({"node": parts[0], "direction": parts[3],
                      "uptime": parts[4], "state": parts[-1]})
    return links


def node_tree(node):
    """
    Everything reachable, from 'rpt nodes'. Entries carry a connection-type
    prefix (T transceive, R receive-only) and the list wraps across lines.
    """
    if not node:
        return []
    out = asterisk_rx("rpt nodes %s" % node)
    if not out or "<NONE>" in out:
        return []
    seen, links = set(), []
    for line in out.split("\n"):
        if "CONNECTED NODES" in line or not line.strip():
            continue
        for tok in re.findall(r"[TRC]?(\d{3,7})\b", line):
            if tok != node and tok not in seen:
                seen.add(tok)
                links.append(tok)
    return links


def radio_state(cfg):
    out = {}
    for key in ("frequency", "mode", "narrow", "power", "tone_mode",
                "ctcss", "dcs"):
        out[key] = cfg.get("radio", key, fallback="")
    for key in ("tx_level", "rx_level"):
        out[key] = cfg.get("audio", key, fallback="")
    out["model"] = cfg.get("radio", "model", fallback="custom").lower()
    return out


def make_app(state):
    """
    Build the Flask app. `state` is the shared Service object, so the panel
    can talk to the running bridge instead of restarting it.
    """
    app = Flask(__name__)
    app.secret_key = state.secret_key
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        PERMANENT_SESSION_LIFETIME=60 * 60 * 12,
        MAX_CONTENT_LENGTH=64 * 1024,
    )

    def call_helper(payload):
        """Everything privileged goes through sudo to our own --apply mode."""
        try:
            r = subprocess.run(["sudo", "-n", SELF, "--apply"],
                               input=json.dumps(payload), capture_output=True,
                               text=True, timeout=120)
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": "timed out"}
        if r.returncode != 0:
            err = (r.stderr or "").strip()
            if "password is required" in err or "not allowed" in err:
                return {"ok": False,
                        "error": "sudo is not set up for this account. "
                                 "Re-run install.sh."}
            return {"ok": False, "error": err or "helper failed"}
        try:
            return json.loads(r.stdout)
        except ValueError:
            # The helper died before answering. Its traceback goes to stderr;
            # show the last line rather than dumping it into the browser.
            err = (r.stderr or r.stdout or "no response").strip()
            return {"ok": False, "error": err.split("\n")[-1].strip()[:300]}

    def logged_in():
        return session.get("user") == state.username

    def csrf_ok():
        tok = session.get("csrf")
        return bool(tok) and hmac.compare_digest(
            tok, request.form.get("csrf", "")
            or request.headers.get("X-CSRF", ""))

    @app.before_request
    def guard():
        if request.endpoint in ("login", "static"):
            return None
        if not logged_in():
            if request.path.startswith("/api/"):
                return jsonify({"ok": False, "error": "not signed in"}), 401
            return redirect(url_for("login"))
        if request.method == "POST" and not csrf_ok():
            return jsonify({"ok": False,
                            "error": "stale form, reload the page"}), 400
        return None

    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = None
        if request.method == "POST":
            u = request.form.get("username", "")
            p = request.form.get("password", "")
            if (hmac.compare_digest(u, state.username)
                    and check_password(p, state.password_hash)):
                session.clear()
                session["user"] = u
                session["csrf"] = secrets.token_urlsafe(32)
                session.permanent = True
                return redirect(url_for("panel"))
            # One message for both cases, so it cannot be used to find out
            # which usernames exist.
            error = "Wrong user or password."
        return render_template_string(LOGIN_HTML, style=STYLE, error=error)

    @app.route("/logout")
    def logout():
        session.clear()
        return redirect(url_for("login"))

    @app.route("/")
    def panel():
        cfg = load_config()
        return render_template_string(
            PANEL_HTML, style=STYLE, radio=radio_state(cfg), node=read_node(),
            csrf=session.get("csrf", ""), profiles=RADIO_PROFILES,
            default_password=state.is_default_password,
            release=RELEASE)

    @app.route("/api/status")
    def api_status():
        node = read_node()
        cfg = load_config()
        return jsonify({
            "bridge": state.bridge_ok(),
            "asterisk": service_active("asterisk"),
            "radio": radio_state(cfg),
            "node": node,
            "links": direct_links(node.get("node")),
            "tree": node_tree(node.get("node")),
            "ptt": state.ptt(),
            "rx": state.squelch(),
            "controllable": state.controllable(),
        })

    @app.route("/api/radio", methods=["POST"])
    def api_radio():
        d = request.get_json(silent=True) or {}
        res = call_helper({
            "action": "radio", "model": d.get("model"),
            "frequency": d.get("frequency"), "mode": d.get("mode"),
            "power": d.get("power"), "tone_mode": d.get("tone_mode"),
            "ctcss": d.get("ctcss"), "dcs": d.get("dcs"),
            "narrow": bool(d.get("narrow")),
        })
        # Bridge and panel share a process, so retuning needs no restart -
        # just tell the bridge to redo its handshake with the new settings.
        if res.get("ok") and res.get("reload_bridge"):
            state.request_reload()
        return jsonify(res)

    @app.route("/api/audio", methods=["POST"])
    def api_audio():
        d = request.get_json(silent=True) or {}
        return jsonify(call_helper({
            "action": "audio", "tx_level": d.get("tx_level"),
            "rx_level": d.get("rx_level"), "model": d.get("model"),
        }))

    @app.route("/api/node", methods=["POST"])
    def api_node():
        d = request.get_json(silent=True) or {}
        return jsonify(call_helper({
            "action": "node", "node": d.get("node"),
            "callsign": d.get("callsign"), "password": d.get("password") or "",
        }))

    @app.route("/api/link", methods=["POST"])
    def api_link():
        d = request.get_json(silent=True) or {}
        node = read_node().get("node")
        if not node:
            return jsonify({"ok": False, "error": "no node found in rpt.conf"})
        return jsonify(call_helper({
            "action": "link", "node": node,
            "target": d.get("target"), "mode": d.get("mode"),
        }))

    @app.route("/api/service", methods=["POST"])
    def api_service():
        d = request.get_json(silent=True) or {}
        return jsonify(call_helper({
            "action": "service", "service": d.get("service"),
            "verb": d.get("verb"),
        }))

    @app.route("/api/webpass", methods=["POST"])
    def api_webpass():
        d = request.get_json(silent=True) or {}
        res = call_helper({"action": "webpass", "password": d.get("password")})
        if res.get("ok"):
            state.reload_credentials()
            session.clear()
        return jsonify(res)

    return app


# --------------------------------------------------------------------------
# Privileged helper (allstar.py --apply, invoked through sudo)
# --------------------------------------------------------------------------
#
# The service runs unprivileged. Anything that writes to /etc or restarts a
# service is done here instead, re-validated from scratch. The sudoers rule
# names this exact command with no wildcards:
#
#     allstar ALL=(root) NOPASSWD: /usr/local/bin/allstar.py --apply
#
# The request arrives as JSON on stdin. The web side's own validation only
# exists to give the user a useful message; this is the boundary that counts,
# because a compromised web thread would be talking to this interface.

# Valid values are the keys of the protocol tables above, so there is no
# second list to keep in sync.
VALID_MODES = tuple(MODES)
VALID_POWERS = tuple(POWERS)
VALID_TONE_MODES = tuple(TONE_MODES)


def _fail(msg):
    print(json.dumps({"ok": False, "error": msg}))
    sys.exit(0)


def _done(msg, **extra):
    out = {"ok": True, "message": msg}
    out.update(extra)
    print(json.dumps(out))
    sys.exit(0)


# Which section each setting belongs to, so a key missing from an older
# config file can be added in the right place instead of failing.
KEY_SECTION = {
    "model": "radio", "frequency": "radio", "mode": "radio",
    "narrow": "radio", "power": "radio", "tone_mode": "radio",
    "ctcss": "radio", "dcs": "radio",
    "tx_level": "audio", "rx_level": "audio",
    "password_hash": "web", "username": "web", "secret_key": "web",
}


def set_keys(path, pairs):
    """
    Replace `key = value` lines in place.

    Keeps indentation and any trailing comment, so the notes in the config
    survive being edited from the web panel. Without this the file loses its
    own documentation the first time anyone changes a setting.
    """
    lines = read_lines(path)
    missing = []
    for key, value in pairs.items():
        pat = re.compile(r"^(\s*)%s\s*=([^;]*)(;.*)?$" % re.escape(key))
        for i, ln in enumerate(lines):
            m = pat.match(ln)
            if m:
                indent, old_val, comment = m.group(1), m.group(2), m.group(3)
                if comment:
                    col = len("%s%s =%s" % (indent, key, old_val))
                    body = "%s%s = %s" % (indent, key, value)
                    lines[i] = body + " " * max(1, col - len(body)) + comment
                else:
                    lines[i] = "%s%s = %s" % (indent, key, value)
                break
        else:
            missing.append(key)

    # A config written by an older version will not have every key. Add the
    # missing ones to the section they belong to rather than refusing to
    # save - the alternative is that an upgrade silently breaks the panel.
    for key in list(missing):
        section = KEY_SECTION.get(key)
        if not section:
            continue
        idx = find_stanza(lines, section)
        if idx is None:
            while lines and lines[-1].strip() == "":
                lines.pop()
            lines += ["", "[%s]" % section, "%s = %s" % (key, pairs[key])]
        else:
            lines.insert(idx + 1, "%s = %s" % (key, pairs[key]))
        missing.remove(key)

    if missing:
        _fail("keys not found in %s: %s" % (path, ", ".join(missing)))
    write_lines(path, lines)


def systemctl(*args):
    try:
        r = subprocess.run(["systemctl"] + list(args), capture_output=True,
                           text=True, timeout=90)
        return r.returncode == 0, (r.stderr or r.stdout).strip()
    except subprocess.TimeoutExpired:
        return False, "systemctl timed out"


# ------------------------------------------------------------- validation

def v_freq(raw):
    try:
        f = float(raw)
    except (TypeError, ValueError):
        _fail("frequency must be a number")
    # The D1M field is exactly 9 characters. A protocol limit, not a policy.
    if len("%09.5f" % f) != 9:
        _fail("frequency does not fit the radio's 9-character field")
    if not (0.1 <= f < 1000):
        _fail("frequency out of range")
    return "%.4f" % f


def v_choice(raw, allowed, what):
    if raw not in allowed:
        _fail("%s must be one of: %s" % (what, ", ".join(allowed)))
    return raw


def v_ctcss(raw):
    try:
        v = float(raw)
    except (TypeError, ValueError):
        _fail("CTCSS must be a number")
    if not (60 <= v <= 260):
        _fail("CTCSS out of range (60-260 Hz)")
    return "%.1f" % v


def v_dcs(raw):
    raw = str(raw).strip()
    if not re.fullmatch(r"[0-7]{1,3}", raw):
        _fail("DCS must be up to three octal digits")
    return raw


def v_node(raw):
    raw = str(raw).strip()
    if not re.fullmatch(r"[0-9]{1,7}", raw):
        _fail("node number must be 1-7 digits")
    return raw


def v_callsign(raw):
    raw = str(raw).strip().upper()
    # Permissive on purpose: callsign formats vary worldwide, and this ends
    # up inside a Morse ID string, not a shell command.
    if not re.fullmatch(r"[A-Z0-9/\-]{3,16}", raw):
        _fail("callsign may only contain letters, digits, / and -")
    return raw


def v_password(raw):
    raw = str(raw)
    if not (1 <= len(raw) <= 64):
        _fail("node password must be 1-64 characters")
    if not re.fullmatch(r"[!-~]+", raw):
        _fail("node password must not contain spaces or control characters")
    return raw


def v_level(raw, what, limit=63):
    # The codec fixes these: Speaker tops out at 47, PCM at 55. Clamping
    # silently would look like it worked and quietly change the level.
    try:
        v = int(raw)
    except (TypeError, ValueError):
        _fail("%s must be a whole number" % what)
    if not (0 <= v <= limit):
        _fail("%s must be between 0 and %d" % (what, limit))
    return str(v)


# ---------------------------------------------------------------- actions

def v_model(raw):
    raw = str(raw or "custom").lower()
    if raw not in RADIO_PROFILES:
        _fail("unknown radio model")
    return raw


def act_radio(req):
    """Frequency, mode, power and tone. Only touches our own config."""
    pairs = {
        "model": v_model(req.get("model")),
        "frequency": v_freq(req.get("frequency")),
        "mode": v_choice(req.get("mode"), VALID_MODES, "mode"),
        "power": v_choice(req.get("power"), VALID_POWERS, "power"),
        "tone_mode": v_choice(req.get("tone_mode"), VALID_TONE_MODES, "tone mode"),
        "ctcss": v_ctcss(req.get("ctcss")),
        "dcs": v_dcs(req.get("dcs")),
        "narrow": "yes" if req.get("narrow") else "no",
    }
    backup(CONFIG_PATH)
    set_keys(CONFIG_PATH, pairs)
    # No service restart: the caller signals the running bridge in-process.
    _done("Radio set to %s MHz, %s power." % (pairs["frequency"],
                                              pairs["power"]),
          reload_bridge=True)


def act_audio(req):
    tx = v_level(req.get("tx_level"), "TX level", 47)
    rx = v_level(req.get("rx_level"), "RX level", 55)
    backup(CONFIG_PATH)
    pairs = {"tx_level": tx, "rx_level": rx}
    if req.get("model"):
        pairs["model"] = v_model(req.get("model"))
    set_keys(CONFIG_PATH, pairs)
    cfg = load_config()
    card = cfg.get("audio", "card")
    # The control names do not match their functions: 'Speaker' is the level
    # OUT to the radio, 'PCM' the level IN from it.
    for control, value in (("Speaker", tx), ("PCM", rx)):
        try:
            subprocess.run(["amixer", "-q", "-c", card, "sset", control, value],
                           check=True, capture_output=True, timeout=10)
        except (subprocess.CalledProcessError, FileNotFoundError,
                subprocess.TimeoutExpired):
            _fail("saved, but could not set mixer control '%s'" % control)
    subprocess.run(["alsactl", "store"], capture_output=True, timeout=10)
    _done("Audio levels set: TX %s, RX %s." % (tx, rx))


def act_node(req):
    """Node number, callsign and registration password."""
    node = v_node(req.get("node"))
    callsign = v_callsign(req.get("callsign"))
    password = req.get("password") or ""
    old = current_node()

    if not os.path.exists(RPT_CONF):
        _fail("%s not found - is ASL3 installed?" % RPT_CONF)

    lines = read_lines(RPT_CONF)
    start = find_stanza(lines, old) if old else None
    if start is None:
        _fail("no node stanza with a USRP rxchannel found in rpt.conf")

    backup(RPT_CONF)

    if node != old:
        if find_stanza(lines, node) is not None:
            _fail("node %s already has a stanza in rpt.conf" % node)
        m = HEADER_RE.match(lines[start])
        lines[start] = "[%s]%s" % (node, m.group(2) or "")

    end = stanza_end(lines, start)
    for j in range(start + 1, end):
        if re.match(r"^\s*idrecording\s*=", lines[j]):
            lines[j] = "idrecording = |i%s" % callsign
            break
    else:
        lines.insert(start + 1, "idrecording = |i%s" % callsign)

    write_lines(RPT_CONF, lines)

    # Registration is optional - private nodes (1000-1999) have none.
    #
    # The file holds one register line per node inside a single
    # [registrations] stanza, not a stanza per node:
    #
    #   register => 452680:secret@register.allstarlink.org
    #
    # Only the node number and password are ours; host and port stay.
    extra = ""
    if password or node != old:
        path = reg_conf()
        if not path:
            if password:
                _fail("node and callsign saved, but no registration file was "
                      "found. A private node (1000-1999) does not need one.")
        else:
            if password:
                password = v_password(password)
            reg = read_lines(path)
            # Trailing whitespace, a stray \r from a file edited on Windows,
            # or a comment all have to be tolerated - and preserved. Anchoring
            # on \S+$ alone rejects a line that is otherwise perfectly valid.
            pat = re.compile(r"^(\s*register\s*=>\s*)([^:@\s]+):([^@\s]+)@(\S+)"
                             r"(\s*(?:;.*)?)$")
            found = [(i, m) for i, m in
                     ((i, pat.match(ln)) for i, ln in enumerate(reg)) if m]

            # Prefer the line that names our node.
            hit = next((x for x in found
                        if x[1].group(2) in (old, node)), None)

            # Nothing names us. If there is exactly one register line, it is
            # ours whatever number it carries - rpt.conf and this file have
            # drifted apart, which is precisely what needs fixing rather than
            # a reason to refuse. With several lines we cannot tell which is
            # ours, so leave them all alone.
            renumbered = False
            if hit is None and len(found) == 1:
                hit = found[0]
                renumbered = True
            if hit is None:
                if password:
                    name = os.path.basename(path)
                    if not found:
                        _fail("node and callsign saved, but the password was "
                              "not changed: %s has no register line at all. "
                              "Add one under [registrations]:  register => "
                              "%s:<password>@register.allstarlink.org"
                              % (name, node))
                    others = ", ".join(sorted(m.group(2) for _, m in found))
                    _fail("node and callsign saved, but the password was not "
                          "changed: %s registers nodes %s, not %s. With "
                          "several nodes there is no way to tell which line "
                          "is yours - edit the file by hand."
                          % (name, others, node))
            else:
                backup(path)
                i, m = hit
                reg[i] = "%s%s:%s@%s%s" % (m.group(1), node,
                                           password or m.group(3),
                                           m.group(4), m.group(5) or "")
                write_lines(path, reg)
                if renumbered:
                    extra = (" Registration was on node %s and has been "
                             "corrected." % hit[1].group(2))
                elif password:
                    extra = " Registration updated."
                else:
                    extra = " Registration renumbered."

    ok, err = systemctl("restart", "asterisk")
    if not ok:
        _fail("saved, but Asterisk failed to restart: %s" % err)
    _done("Node %s, callsign %s.%s" % (node, callsign, extra))


def act_link(req):
    node = v_node(req.get("node"))
    mode = req.get("mode")
    # ilink 3 = transceive, 2 = monitor only, 1 = disconnect
    code = {"connect": "3", "monitor": "2", "disconnect": "1"}.get(mode)
    if not code:
        _fail("unknown link action")
    target = v_node(req.get("target"))
    try:
        r = subprocess.run(
            ["asterisk", "-rx", "rpt cmd %s ilink %s %s" % (node, code, target)],
            capture_output=True, text=True, timeout=30)
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        _fail("could not reach Asterisk: %s" % e)
    if r.returncode != 0 and not r.stdout.strip():
        _fail((r.stderr or "Asterisk rejected the command").strip())
    verb = {"connect": "Connected to", "monitor": "Monitoring",
            "disconnect": "Disconnected from"}[mode]
    _done("%s node %s." % (verb, target))


def act_service(req):
    name = req.get("service")
    verb = req.get("verb")
    if name not in ("allstar", "asterisk"):
        _fail("unknown service")
    if verb not in ("restart", "reload", "start", "stop"):
        _fail("unknown action")
    if name == "asterisk" and verb == "reload":
        verb = "restart"
    ok, err = systemctl(verb, name)
    if not ok:
        _fail("%s %s failed: %s" % (verb, name, err))
    _done("%s: %s" % (name, verb))


def act_webpass(req):
    """Change the web panel password."""
    new = str(req.get("password") or "")
    if len(new) < 8:
        _fail("use at least 8 characters")
    if not re.fullmatch(r"[!-~]+", new):
        _fail("no spaces or control characters")
    backup(CONFIG_PATH)
    set_keys(CONFIG_PATH, {"password_hash": hash_password(new)})
    _done("Panel password changed. Sign in again with the new one.")


APPLY_ACTIONS = {
    "radio": act_radio,
    "audio": act_audio,
    "node": act_node,
    "link": act_link,
    "service": act_service,
    "webpass": act_webpass,
}


def run_apply():
    if os.geteuid() != 0:
        _fail("must run as root (invoked through sudo by the service)")
    try:
        req = json.loads(sys.stdin.read(65536))
    except (ValueError, OSError) as e:
        _fail("bad request: %s" % e)
    if not isinstance(req, dict):
        _fail("request must be a JSON object")
    handler = APPLY_ACTIONS.get(req.get("action"))
    if not handler:
        _fail("unknown action")
    try:
        handler(req)
    except SystemExit:
        raise
    except OSError as e:
        if e.errno == 30:
            _fail("filesystem is read-only for this service - check "
                  "ProtectSystem in allstar.service")
        _fail("%s: %s" % (type(e).__name__, e))
    except Exception as e:
        _fail("%s: %s" % (type(e).__name__, e))


# --------------------------------------------------------------------------
# Service: bridge and web panel in one process
# --------------------------------------------------------------------------

class Service:
    """
    Owns the bridge and the web panel, and lets them talk.

    The panel needs three things from the bridge: whether it is running, its
    live PTT and squelch state, and a way to re-run the handshake after the
    radio settings change. Sharing a process makes all three direct calls
    instead of service restarts.
    """

    def __init__(self, config_path=CONFIG_PATH):
        self.config_path = config_path
        self.cfg = load_config(config_path)
        self.log = logging.getLogger("allstar")
        self.bridge = None
        self.reload_flag = threading.Event()
        self.stopping = threading.Event()
        self.reload_credentials()

    # -- web credentials ---------------------------------------------------

    def reload_credentials(self):
        cfg = load_config(self.config_path)
        self.username = cfg.get("web", "username").strip() or "asl3"

        stored = cfg.get("web", "password_hash").strip()
        self.is_default_password = False
        if not stored:
            stored = hash_password("password")
            self.is_default_password = True
        elif check_password("password", stored):
            self.is_default_password = True
        self.password_hash = stored

        secret = cfg.get("web", "secret_key").strip()
        if not secret:
            # Not fatal, but everyone gets signed out on every restart.
            secret = secrets.token_urlsafe(32)
            self.log.warning("no secret_key in %s - sessions will not survive "
                             "a restart", self.config_path)
        self.secret_key = secret

    # -- what the panel asks about ----------------------------------------

    def bridge_ok(self):
        # Deliberately not checking radio_present: a radio that does not
        # identify itself still carries PTT, squelch and audio perfectly
        # well. Requiring an ID would show a working FT-7800R node as down.
        b = self.bridge
        return bool(b and b.running.is_set() and b.ser and b.ser.is_open)

    def controllable(self):
        """Whether the radio answers, so its channel can be set from here."""
        return bool(self.bridge and self.bridge.radio_present)

    def radio_model(self):
        return self.cfg.get("radio", "model", fallback="custom").lower()

    def ptt(self):
        return bool(self.bridge and self.bridge.ptt)

    def squelch(self):
        return bool(self.bridge and self.bridge.sql_open)

    def request_reload(self):
        """
        Re-read the config and repeat the handshake.

        The HRI-200 only reads D1M during initialisation, so changing
        frequency, tone or power means closing the port and starting over.
        A few seconds without audio; there is no way around it.
        """
        self.reload_flag.set()

    # -- lifecycle ---------------------------------------------------------

    def run(self, web=True):
        self.cfg = load_config(self.config_path)
        self.bridge = Bridge(self.cfg)
        self.bridge.config_path = self.config_path
        self.bridge.start()

        if web and self.cfg.getboolean("web", "enabled"):
            app = make_app(self)
            host = self.cfg.get("web", "host")
            port = self.cfg.getint("web", "port")
            t = threading.Thread(
                target=lambda: app.run(host=host, port=port, threaded=True,
                                       use_reloader=False),
                name="web", daemon=True)
            t.start()
            self.log.info("web panel on http://%s:%d", host, port)
            if self.is_default_password:
                self.log.warning("panel is using the default password - "
                                 "change it on the Panel access card")

        try:
            while not self.stopping.is_set():
                time.sleep(0.5)
                if self.reload_flag.is_set():
                    self.reload_flag.clear()
                    self._reload_bridge()
        finally:
            if self.bridge:
                self.bridge.stop()

    def _reload_bridge(self):
        self.log.info("reloading radio settings")
        try:
            self.bridge.stop()
        except Exception as e:
            self.log.warning("stopping bridge: %s", e)
        self.cfg = load_config(self.config_path)
        self.bridge = Bridge(self.cfg)
        self.bridge.config_path = self.config_path
        for attempt in range(3):
            try:
                self.bridge.start()
                self.log.info("radio settings applied")
                return
            except Exception as e:
                self.log.error("reload attempt %d failed: %s", attempt + 1, e)
                time.sleep(2)
        self.log.error("could not restart the bridge - check the radio")

    def stop(self):
        self.stopping.set()


# --------------------------------------------------------------------------
# --check and --selftest
# --------------------------------------------------------------------------

def run_check(cfg, log):
    ok = True

    def report(name, good, detail=""):
        nonlocal ok
        if not good:
            ok = False
        print("  [%s] %-22s %s" % ("OK" if good else "--", name, detail))

    print("%s - checking the chain\n" % RELEASE)

    # 1. USB
    try:
        out = subprocess.run(["lsusb"], capture_output=True, text=True,
                             timeout=5).stdout
        if "045b:0025" in out:
            report("USB", False, "flash switch is in programming mode")
        elif "26aa:0002" in out and "26aa:0003" in out:
            report("USB", True, "26aa:0002 + 26aa:0003")
        else:
            report("USB", False, "HRI-200 not visible in lsusb")
    except Exception as e:
        report("USB", False, str(e))

    # 2. Serial
    port = cfg.get("serial", "port")
    report("serial port exists", os.path.exists(port), port)

    # 3. ALSA
    device = cfg.get("audio", "device")
    for direction, mode in (("capture", alsaaudio.PCM_CAPTURE),
                            ("playback", alsaaudio.PCM_PLAYBACK)):
        try:
            pcm = alsaaudio.PCM(mode, alsaaudio.PCM_NORMAL, device=device,
                                channels=1, rate=8000,
                                format=alsaaudio.PCM_FORMAT_S16_LE,
                                periodsize=USRP_SAMPLES)
            pcm.close()
            report("audio %s" % direction, True, device)
        except Exception as e:
            report("audio %s" % direction, False, str(e))

    # 4. UDP
    lp = cfg.getint("usrp", "local_port")
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", lp))
        s.close()
        report("UDP port free", True, str(lp))
    except OSError as e:
        report("UDP port free", False, "%d: %s" % (lp, e))

    # 5. D1M
    try:
        d1m = build_d1m(cfg.getfloat("radio", "frequency"),
                        mode=MODES[cfg.get("radio", "mode").lower()],
                        narrow=cfg.getboolean("radio", "narrow"),
                        power=POWERS[cfg.get("radio", "power").lower()],
                        tone_mode=TONE_MODES[cfg.get("radio", "tone_mode").lower()],
                        ctcss=cfg.getfloat("radio", "ctcss"),
                        dcs=cfg.getint("radio", "dcs"))
        report("D1M builds", True, d1m[:24] + "...")
    except Exception as e:
        report("D1M builds", False, str(e))

    # 6. Handshake
    bridge = Bridge(cfg)
    try:
        bridge.open_serial()
        bridge.handshake()
        if bridge.radio_present:
            report("handshake", True, "radio answers, channel set from here")
        elif RADIO_PROFILES.get(
                cfg.get("radio", "model", fallback="custom").lower(),
                {}).get("controllable") is False:
            report("handshake", True,
                   "radio does not identify itself, as expected for this "
                   "model - tune it on the radio")
        else:
            report("handshake", False,
                   "radio does not identify itself. If it should, it is in "
                   "PDN mode - restart it with [D/X]+[GM].")
    except Exception as e:
        report("handshake", False, str(e))
    finally:
        if bridge.ser and bridge.ser.is_open:
            try:
                bridge.send("P010000")
            except Exception:
                pass
            bridge.ser.close()

    print("\n%s\n" % ("Everything looks good." if ok else "See the lines marked --."))
    return 0 if ok else 1




def selftest():
    """No hardware needed. Verifies the frame builders."""
    print("selftest...")

    d = build_d1m(145.2875)
    assert d.startswith("D1M0043"), d
    assert len(d) == 74, len(d)                 # 3 + 4 + 67
    assert d[7] == MODE_FM
    assert d[11:20] == "145.28750", d[11:20]
    print("  D1M FM        :", d)

    d = build_d1m(434.5, mode=MODE_DIGITAL, narrow=True, power=POWER_HIGH,
                  tone_mode=TONE_CTCSS, ctcss=71.9, dcs=754)
    assert d[7] == "7"
    assert d[30] == "1"                         # narrow
    assert d[31] == "2"                         # tone mode
    assert d[32:35] == "071", d[32:35]          # truncated, not rounded
    assert d[35:38] == "754"
    assert d[41] == "0"                         # power high
    print("  D1M digital   :", d)

    f = frame("M00")
    assert f == b"\x01M00\x04", f
    print("  framing       :", f)

    p = usrp_pack(7, True, SILENCE)
    assert len(p) == 32 + 320, len(p)
    assert p[:4] == b"USRP"
    keyup, ptype, payload = usrp_unpack(p)
    assert keyup is True and ptype == 0 and len(payload) == 320
    print("  USRP header   :", p[:32].hex())

    e = usrp_pack(8, False)
    assert len(e) == 32 and usrp_unpack(e)[0] is False
    print("  USRP end      :", e.hex())

    assert usrp_unpack(b"NOPE" + b"\x00" * 40) is None
    assert usrp_unpack(b"short") is None

    h = hash_password("test1234")
    assert check_password("test1234", h)
    assert not check_password("wrong", h)
    assert not check_password("x", "garbage")
    print("  passwords     : ok")

    print("selftest OK")
    return 0


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def do_hash():
    p1 = getpass.getpass("New panel password: ")
    if len(p1) < 8:
        print("Use at least 8 characters.", file=sys.stderr)
        return 1
    if p1 != getpass.getpass("Repeat: "):
        print("They don't match.", file=sys.stderr)
        return 1
    print("\nPut this in %s under [web]:\n" % CONFIG_PATH)
    print("password_hash = %s\n" % hash_password(p1))
    print("Then: sudo systemctl restart allstar")
    return 0


def main():
    global CONFIG_PATH
    ap = argparse.ArgumentParser(
        description="HRI-200 to AllStarLink bridge with web control panel")
    ap.add_argument("-c", "--config", default=CONFIG_PATH)
    ap.add_argument("--apply", action="store_true",
                    help="privileged helper, invoked through sudo")
    ap.add_argument("--check", action="store_true",
                    help="test the whole chain and exit")
    ap.add_argument("--selftest", action="store_true",
                    help="test the protocol builders, no hardware needed")
    ap.add_argument("--hash", action="store_true",
                    help="generate a panel password hash")
    ap.add_argument("--secret", action="store_true",
                    help="generate a secret_key")
    ap.add_argument("--no-web", action="store_true",
                    help="run the bridge only")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--version", action="version", version=RELEASE)
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if args.secret:
        print(secrets.token_urlsafe(32))
        return 0
    if args.hash:
        return do_hash()

    CONFIG_PATH = args.config

    if args.apply:
        # No dependency check: the helper touches config files and services,
        # not the radio, and must still work if a library is missing.
        return run_apply()

    require_deps(web=not args.no_web)
    cfg = load_config(args.config)
    level = logging.DEBUG if args.verbose else getattr(
        logging, cfg.get("daemon", "loglevel").upper(), logging.INFO)
    logging.basicConfig(level=level,
                        format="%(asctime)s %(levelname)-7s %(message)s",
                        datefmt="%H:%M:%S")
    log = logging.getLogger("allstar")

    if args.check:
        return run_check(cfg, log)

    if os.geteuid() == 0:
        log.warning("running as root - use the allstar user instead")

    svc = Service(args.config)

    def on_term(signum, frame_):
        log.info("signal %d", signum)
        svc.stop()

    def on_hup(signum, frame_):
        svc.request_reload()

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    signal.signal(signal.SIGHUP, on_hup)

    try:
        svc.run(web=not args.no_web)
    except Exception as e:
        log.error("%s", e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

