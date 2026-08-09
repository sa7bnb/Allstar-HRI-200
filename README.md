# Allstar-HRI-200

Connect a Yaesu **HRI-200** WIRES-X interface to an **AllStarLink 3** node, and
configure the whole thing from a web page.

The HRI-200 speaks a proprietary Yaesu serial protocol and has no CM108 GPIO, so
AllStarLink's own `chan_simpleusb` and `chan_usbradio` cannot see it. This
software sits between them: it talks the HRI-200's protocol on one side and
presents itself to `app_rpt` as a USRP channel on the other.

The serial protocol was reverse-engineered for
[Svxlink-HRI-200](https://github.com/sa7bnb/Svxlink-HRI-200); this project
applies the same work to AllStarLink.

**By SA7BNB.** Runs on [AllStarLink 3](https://github.com/AllStarLink/ASL3),
which does the linking — this software connects the HRI-200 to it.

![The Allstar-HRI-200 web panel: frequency readout with RX, TX, bridge and
link indicators, and cards for radio settings, node identity, audio levels
and links](image.png)

Everything is configured from this page — node number, callsign, frequency,
power, audio levels and links. No `asl-menu`, no editing config files by hand.

---

## What you need

**A Raspberry Pi 4** (2 GB or more) or any 64-bit machine. A Pi 3 or Zero 2 W
works, but their older USB controller is fussier about audio — see
[Troubleshooting](#audio-breaks-up-or-crackles).

**A Yaesu HRI-200** with its CT-174 cable.

**A radio the HRI-200 supports:**

| Radio | Channel control | Notes |
|---|---|---|
| **FTM-400D** | From the web page | Verified. Frequency, power and tone are set remotely |
| **FT-7800R** | On the radio | Works fully — it just never identifies itself over the data port, which is normal, not a fault |
| Other | Try `custom` | The node adapts to whatever the radio actually replies |

Only PTT, squelch and audio travel over the HRI-200's data connector. Those work
on every supported radio. Channel control is the only thing that depends on the
model.

**A dummy load.** The node keys a real transmitter as soon as it starts.

Raspberry pi 4 IMG : https://drive.google.com/drive/folders/1N8AKE4ZkhbSrf4JPaC5szdNmfgb7Es1L?usp=sharing

---

## 1. Install Raspberry Pi OS

Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager.

ASL3 requires 64-bit. The 32-bit image will not work, and the installer stops
with an explanation rather than failing halfway through.

In Imager, open the settings gear before writing and set:

- **Hostname:** `allstar-hri-200`
- **Username:** `asl3`
- **Password:** `password`
- **Enable SSH**
- Your Wi-Fi details, if you are not using Ethernet

> **Change this password once the node works.** It is the login for the whole
> machine, not just the web page, and it is the first thing anyone scanning your
> network will try. Run `passwd` over SSH and pick something else. It is only
> `password` here so the first boot is predictable.

Boot the Pi and log in. With that hostname set, mDNS usually saves you from
hunting for the IP address:

```bash
ssh asl3@allstar-hri-200.local
```

If `.local` does not resolve on your network, find the address in your router's
client list and use that instead.

---

## 2. Install the software

Raspberry Pi OS Lite ships without git, so install it first:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/sa7bnb/Allstar-HRI-200.git
cd Allstar-HRI-200
chmod +x install.sh
sudo ./install.sh
```

Or skip git entirely — `wget` and `tar` are always present:

```bash
wget https://github.com/sa7bnb/Allstar-HRI-200/archive/refs/heads/main.tar.gz
tar xzf main.tar.gz
cd Allstar-HRI-200-main
chmod +x install.sh
sudo ./install.sh
```

The installer takes about fifteen minutes on a Pi 4 and asks nothing. It
installs AllStarLink 3, the bridge, its service, a udev rule for a stable serial
port name, and the hooks into ASL3's configuration.

**Expect it to stop once.** A system upgrade installs a new kernel that is not
running yet. The installer notices, prints both version numbers, and asks you to
reboot:

```bash
sudo reboot
```

Log back in and run `sudo ./install.sh` again. It picks up where it left off.

---

## 3. Configure from the web page

Everything else is done in the browser. You do **not** need `asl-menu`.

```
http://allstar-hri-200.local:8080
```

Or `http://<address-of-your-pi>:8080` if `.local` does not resolve.

| | |
|---|---|
| **User** | `asl3` |
| **Password** | `password` |

Type `http://` explicitly. Browsers with HTTPS-Only mode will otherwise try TLS
and fail, because the panel serves plain HTTP on your local network.

### Change the panel password first

Under **Panel access**. Anyone who can reach this address can retune your
transmitter and change your node number. A warning stays on the page until you
change it.

This is a separate password from your Raspberry Pi login and from your node
password. Three different things.

### Then set up the node

**Node identity** — node number, callsign, and the node password from
[allstarlink.org](https://www.allstarlink.org/). Nodes **1000–1999** are private,
need no registration and no password; a good place to start. Saving restarts
Asterisk, so the node drops off the network for about ten seconds.

**Radio** — model, frequency, power, mode and tone. The bridge re-runs its
handshake, so audio drops for a couple of seconds, but the node stays connected.

**Audio levels** — transmit and receive. Picking a radio model loads a sensible
starting point; adjust from there by listening.

**Links** — connect to other nodes and disconnect again. Your own links get a
Disconnect button. Nodes reachable through a hub you joined are listed for
context without one, because you have no link of your own to drop.

---

## 4. Two things the web page cannot do

### Put the radio in HRI-200 mode

Start the FTM-400D by holding **[D/X] + [GM]** until the display reads
`HRI-200`.

`[D/X]` alone gives PDN mode, which looks identical and does not work. **This
setting does not survive a power cut**, so a radio that lost power needs it
again. The node keeps retrying every fifteen seconds, so once you set the radio
right it comes up on its own.

### Forward UDP 4569

In your router, to the Pi. Without it you can connect out and hear the other
station, but nobody can reach your node — and nothing in the log says so until
someone tries.

**Never forward port 8080.** If you want the panel from outside, use an SSH
tunnel:

```bash
ssh -L 8080:localhost:8080 asl3@allstar-hri-200.local
```

Then open `http://localhost:8080`. To refuse anything else, set
`host = 127.0.0.1` in `/etc/allstar.conf`.

---

## 5. Test it

Against a **dummy load**, from a handheld on the node's frequency.

**Telemetry.** Key up, press `*`, release. The node answers in Morse. That
proves the whole chain: squelch, DTMF decoding, telemetry and PTT.

**Parrot.** Records you and plays it back, so you hear your own audio through
the node:

```bash
sudo asterisk -rx "rpt cmd <your-node> cop 55"
```

Key up immediately afterwards and talk. If it sounds harsh or distorted, lower
the transmit level under **Audio levels**.

**A real link.** Connect to **55553**, AllStarLink's parrot, from the Links card.
Key up, talk, release — it plays you back over the network. This is the test that
proves everything, since the audio has been out to the internet and back.

Disconnect when you are done.

---

## Before you put up an antenna

`434.5000 MHz` is a placeholder, not a recommendation.

**You are responsible for operating on a frequency you are licensed and
permitted to use in your own country.** Rules for unattended and remotely
controlled stations vary, and many countries require the channel to be
coordinated first. Check with your national society or regulator before you
connect an antenna.

Keep the dummy load on until that is sorted.

---

## Troubleshooting

### The node transmits while I am talking, and I never hear myself

`duplex` is set to `2`, which is repeater mode — the node repeats what it hears
straight back out. On a simplex node with one radio it transmits on top of you.

Recent installs set `duplex = 1` in your node's own stanza. If yours predates
that:

```bash
grep -n "^duplex" /etc/asterisk/rpt.conf
sudo sed -i '/^\[<your-node>\](node-main)/a duplex = 1' /etc/asterisk/rpt.conf
sudo systemctl restart asterisk
```

ASL3's `[node-main]` template ships `duplex = 2` because it is written for a hub
with no radio. A setting in your own stanza wins over the template.

### The radio is not detected

```
no radio found - PDN mode instead of HRI-200 mode?
```

Start the radio with **[D/X] + [GM]**, not `[D/X]` alone. If you are running an
FT-7800R or another radio that does not identify itself, this message is
informational — pick that model on the **Radio** card and the node stops waiting
for a reply that will never come.

### The HRI-200 is not found at all

```bash
lsusb
```

`26aa:0002` and `26aa:0003` mean the box is in normal mode. `045b:0025` means
the flash switch is in programming mode, and nothing will work until you move
it back.

### Audio breaks up or crackles

Raise `jitter_frames` in `/etc/allstar.conf` — each step adds 20 ms of buffer:

```bash
sudo nano /etc/allstar.conf
sudo systemctl restart allstar
```

Most common on a Pi 3 or Zero 2 W, whose `dwc_otg` USB controller handles
isochronous audio less gracefully than the Pi 4's.

### The panel shows no links even though I am connected

The web user needs read access to Asterisk's control socket:

```bash
sudo -u allstar asterisk -rx "rpt localnodes"
```

If that fails, `/etc/asterisk/asterisk.conf` needs `astctlpermissions = 0660`
under `[files]`. The installer sets this; a manual ASL3 install may not have it.

### DAHDI will not build

```
error: implicit declaration of function 'del_timer_sync'
```

DAHDI 3.4.0 does not compile against kernel 6.18 — the function was renamed to
`timer_delete_sync()` upstream. **This does not matter here.** Asterisk 22 gets
its timing from `res_timing_timerfd`, and a node using a USRP channel never
touches DAHDI. Verify with:

```bash
sudo asterisk -rx "timing test"
```

### Check the whole chain

```bash
sudo systemctl stop allstar
sudo -u allstar allstar.py --check
sudo systemctl start allstar
```

Tests USB, the serial port, both audio directions, the UDP port, the protocol
builder and the handshake with the radio — and says what is wrong, not just that
something is.

### Logs

```bash
journalctl -u allstar -f
journalctl -u asterisk -f
sudo asterisk -rvvv
```

For more detail, set `loglevel = debug` in `/etc/allstar.conf` and restart. It
logs about five lines per second, so set it back afterwards.

---

## Useful CLI commands

The web page covers everything below, but these are handy for scripting:

```bash
sudo asterisk -rx "rpt localnodes"              # nodes running here
sudo asterisk -rx "rpt lstats <node>"           # your own links
sudo asterisk -rx "rpt nodes <node>"            # everything reachable
sudo asterisk -rx "rpt show registrations"      # is the node registered
sudo asterisk -rx "rpt cmd <node> ilink 3 <target>"   # connect
sudo asterisk -rx "rpt cmd <node> ilink 1 <target>"   # disconnect
```

`rpt show nodes` does **not** exist in ASL3 3.9.x. It is `rpt localnodes`.

From the radio, `*3` plus a node number connects, `*1` plus a node number
disconnects, and `*70` reads the node's status aloud.

---

## What gets installed where

| Path | What |
|---|---|
| `/usr/local/bin/allstar.py` | The bridge and web panel |
| `/etc/allstar.conf` | Configuration |
| `/etc/systemd/system/allstar.service` | The service |
| `/etc/sudoers.d/allstar` | One rule, one program, no wildcards |
| `/etc/udev/rules.d/99-hri200.rules` | Stable `/dev/hri200` name |
| `/etc/asterisk/custom/allstar.conf` | Node stanza, when the node is new |
| `/var/backups/allstar/` | Every file replaced, timestamped |

ASL3's own files are touched in exactly three places: one `#includeifexists`
line in `rpt.conf`, and two lines in `modules.conf` to enable `chan_usrp`. Each
is tagged `; allstar`.

The `chan_usrp` change cannot be avoided: ASL3 ships `autoload=no` plus an
explicit `noload` for the module, and a `noload` beats a `load` wherever it
appears.

### How the privileges work

The service runs as an unprivileged `allstar` user. It cannot write to `/etc` or
restart services. Everything that changes something goes through `sudo` to
`allstar.py --apply`, which re-validates the request from scratch. The sudoers
rule names one program with one fixed argument and no wildcards, and the request
travels as JSON on stdin.

---

## Licence and thanks

Built on [AllStarLink 3](https://github.com/AllStarLink/ASL3), which does the
linking.

Protocol work from
[Svxlink-HRI-200](https://github.com/sa7bnb/Svxlink-HRI-200).

73 de **SA7BNB**
