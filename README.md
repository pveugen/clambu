# clambu

Slice, print and watch a Bambu Lab 3D printer from the terminal on macOS, with no Bambu Studio window. Works with the A1, A1 mini, P1S, X1, H2D, P2S and every other model Bambu Studio has profiles for.

## Install

You need a Mac with macOS 15 or later, Xcode with Swift 6.4 or later, and [Bambu Studio](https://bambulab.com/en/download/studio) in /Applications. clambu slices with Bambu Studio's own engine and profiles.

```sh
git clone https://github.com/pveugen/clambu.git
cd clambu
./install.sh
```

The installer builds clambu, links it to `~/.local/bin/clambu` and starts the setup. The first build downloads its packages and takes a few minutes. Run `./install.sh` again after a `git pull`.

## Set up your printer

### 1. Turn on LAN Only mode and Developer Mode

clambu talks to the printer directly on your network. On current firmware, Bambu printers only accept commands from other apps in LAN Only mode with Developer Mode on. On the printer's screen:

| Printer | Where |
|---------|-------|
| A1, A1 mini | Settings > LAN Only Mode (page 3). Turn it on, then turn on Developer Mode on the same page and confirm. |
| P1P, P1S | Settings > WLAN > LAN Only Mode > Yes. Scroll down on the same page to Developer Mode and enable it. Needs firmware 01.08.02.00 or later. |
| X1, X1 Carbon, X1E, P2S, H2D, H2S | Settings > LAN Only. Turn it on, then turn on Developer Mode on the same page and confirm. |

LAN Only mode disconnects the printer from Bambu's cloud, so Bambu Handy and cloud printing stop working until you turn it off again. Bambu Studio can still print to it over the LAN. See Bambu's guides to [LAN Only mode](https://wiki.bambulab.com/en/knowledge-sharing/enable-lan-mode) and [Developer Mode](https://wiki.bambulab.com/en/knowledge-sharing/enable-developer-mode).

### 2. Note the IP address, access code and serial number

The LAN Only page shows the printer's IP address and its access code. The serial number is under Settings > Device. The access code changes when you turn LAN Only mode off and on.

Give the printer a fixed IP address in your router, so clambu finds it after a restart.

### 3. Run setup

```sh
clambu setup
```

In a terminal, setup walks you through these steps with a picture of the printer's screen. It asks for the IP address, the serial number and the access code (typed hidden). It recognises the model from the serial number, connects to the printer, reads the nozzle size and the loaded spool, and asks for your default material and build plate. It saves everything to `~/.config/bambu/<name>.env`, readable only by you.

Then check everything:

```sh
clambu doctor
```

On a printer with a supported camera, teach clambu what your empty plate looks like. With the plate clear:

```sh
clambu plate learn --sweep
```

For a second printer, run `clambu setup` again. With more than one printer, pick one with `--printer <name>` or `CLAMBU_PRINTER=<name>`.

To set up without questions, for example from a script, pass everything as options and the access code in `PRINTER_ACCESS_CODE`:

```sh
PRINTER_ACCESS_CODE=12345678 clambu setup --ip 192.168.1.50 --serial 01P00A000000000 --material pla --json
```

## What it does

clambu checks every print twice before it starts, confirms with the printer's camera that the plate is clear, and follows the print in your terminal, on a web page and in your tmux status bar.

- Check that the plate is clear and keep the sharpest camera frame with Eye, an on-device vision model that runs on your Mac.
- Slice STL files headless with Bambu Studio's profiles for your printer, nozzle and material.
- Refuse a print when the G-code, the printer model, the spool, the nozzle or the plate doesn't match.
- Follow a print in your terminal as a log with a progress panel and keys to pause, change speed or stop.
- Watch the camera on a web page, on this Mac or on your phone over Tailscale.
- See the print in your tmux status bar and in the Claude Code status line.
- Drive it from scripts and AI agents: every command prints JSON and has fixed exit codes.

## Printers

| | Slicing and safety checks | Status, control, following a print | Camera, plate check, photos |
|---|---|---|---|
| A1, A1 mini, A2L, P1S | yes | yes | yes |
| P1P | needs Bambu Studio profiles for it | yes | yes |
| X1, X1 Carbon, X1E, P2S, H2D, H2S and newer | yes | yes | not yet |

clambu reads the A1, A1 mini, A2L, P1P and P1S camera directly. The X1, P2S and H2 series stream video over RTSP, which clambu doesn't read yet; on those, it skips the plate check and the photos and tells you to check the plate yourself. The current Bambu Studio ships no PLA or PETG profiles for the P1P, so slicing for it fails with a clear message; printing files you sliced elsewhere works.

clambu is developed and tested on an A1 mini. Slicing and the checks are tested against Bambu Studio's profiles for the A1, A1 mini, A2L, P1S, X1 Carbon, X1E, H2D, H2S and P2S.

## Commands

```sh
clambu setup                                # connect a printer
clambu doctor                               # check the setup and the connection
clambu print shell.stl cover.stl            # slice, check, confirm, upload, start, then follow it
clambu slice part.stl -m petg -l 0.12       # slice only, next to the STL
clambu check part.gcode.3mf                 # check a sliced file
clambu send part.gcode.3mf                  # check, upload, start, then follow it
clambu watch                                # follow the print: a log with a panel under it
clambu status                               # progress, finish time, temperatures, spool
clambu cam --open                           # the sharpest of 5 camera frames
clambu pause | resume | stop                # stop asks first
clambu speed sport                          # silent, standard, sport, ludicrous
clambu temp 225                             # nozzle target, this print only
clambu files                                # the SD card
clambu plate                                # is the plate clear?
clambu materials                            # the material presets for your printer
```

`slice` and `print` use the printer's default material, its standard layer height and its plate. `-m`, `-l` and `--plate` change them for one print, and `--walls`, `--infill` and `--supports` change the rest.

## Safety checks

| Step | Refuses when |
|------|--------------|
| slice | the G-code skips the printer's own start routine, the layer 1 nozzle temperature differs from the material's or sits outside its safe range, the bed temperature doesn't match the plate, or Bambu Studio warns about the model |
| send | the file fails those checks, it is sliced for another printer model, the printer is busy, the nozzle size differs, the loaded spool isn't the file's material, or the camera doesn't see a clear plate |
| send | you don't answer y, unless you pass `--yes` |

After the start, `send` follows the heat-up, reports the layer 1 temperatures and saves a photo of layer 1 to `~/Pictures/clambu`.

## Following a print

`clambu watch` writes what happens as a log: state changes, every tenth layer, photos, speed changes and anything the printer reports. A panel under the log shows the progress, the time left, the finish time and the temperatures. The log stays in your scrollback after clambu exits. `send` and `print` continue into the same view after layer 1.

Photos of layer 1 and of the finished print show up in the log in Ghostty, Kitty, WezTerm and iTerm2, outside tmux. Elsewhere the log links to the file.

| Key | Does |
|-----|------|
| p | pause, after a y |
| r | resume |
| 1-4 | silent, standard, sport, ludicrous |
| c | grab a camera frame for the web page |
| o | open the web page |
| x | stop, after a y |
| q | quit; the print goes on |

clambu sends a macOS notification when the print changes state or the printer reports a problem. The terminal tab shows the progress in Ghostty and Windows Terminal; inside tmux that needs `set -g allow-passthrough on`.

## Web page

While clambu follows a print, it serves a read-only page with the live camera frame and the progress, on 127.0.0.1 and on this Mac's Tailscale address. Open `http://<this Mac's name>:8765/` on your phone. `--local` keeps the page on this Mac, and `--port` picks another port.

## Status line for tmux and Claude Code

`clambu hud` prints the print in one line, and nothing when nothing prints. Name the Mac that prints with `--from`, and every machine shows its print over Tailscale. For example, with a Mac called `my-mac`, in `~/.tmux.conf`:

```tmux
set -g status-right "#(clambu hud --tmux --follow --from my-mac) ..."
```

And in `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "clambu hud --from my-mac" }
```

On a single Mac, leave out `--from`.

On the Mac that prints, `--follow` starts a quiet `clambu watch` in the background when nothing follows the printer, so the line also shows prints started from the printer or Bambu Handy.

## Scripts and AI agents

Every command takes `--json`. The result is one JSON document on stdout, and progress goes to stderr. In JSON mode clambu never asks a question, so `send`, `print`, `stop`, `gcode` and `plate learn` need `--yes`.

| Exit code | Means |
|-----------|-------|
| 0 | ok |
| 1 | a safety check refused |
| 2 | the command line is wrong |
| 3 | the printer or its camera can't be reached |
| 4 | the printer is in the wrong state, such as busy for `send` |
| 5 | cancelled, or a prompt needed `--yes` |
| 6 | setup is missing: the printer config, Bambu Studio or a profile |

`clambu events` prints the printer's events as JSON lines: `status`, `state`, `layer`, `frame`, `plate`, `alert`, `finished`, `message` and `error`. The web page's server answers `GET /api/status`, `/api/frame.jpg` and `/api/events` (Server-Sent Events).

## Camera and plate check with Eye

clambu sees through [Eye](https://github.com/Desert-Ant-Labs/desert-ant-core), the on-device vision model from Desert Ant Labs' desert-ant-core. Eye runs on your Mac, so no camera frame leaves your network. It downloads its model the first time clambu uses it. clambu uses Eye for two things.

The bed moves while the printer prints, so one camera frame is often blurred. clambu grabs a few frames in a row and keeps the sharpest, scored by Eye. That's the frame you see in the terminal, on the web page and in the photos of layer 1 and the finished print.

Before a print starts, Eye also compares a camera frame with photos of your empty plate. The weakest of 8 tiles decides: below 0.90 is busy, 0.95 and up is clear.

```sh
clambu plate learn --sweep  # with the plate clear: keep it every 10mm of bed travel, about 3 minutes
clambu plate                # clear, busy or unsure, with the scores
```

Every print clambu follows to the end adds a photo of the finished parts as a busy reference. Learn the empty plate again after you move the printer or change the light. `--plate-is-clear` skips the check.

## Materials

| Name | Bambu Studio profile | Nozzle |
|------|----------------------|--------|
| pla | Bambu PLA Basic | the profile's |
| polyterra | PolyTerra PLA | the profile's |
| pla-generic | Generic PLA | the profile's |
| petg | Generic PETG | 260 C |

clambu picks the version of each profile made for your printer and nozzle, so `pla` on an A1 mini is `Bambu PLA Basic @BBL A1M` and on a P1S is `Bambu PLA Basic @BBL P1S 0.4 nozzle`. `clambu materials` shows what each name means for your printer, with its temperatures. PETG prints at 260 C instead of Bambu's 255 C, because on an A1 mini at sport speed 255 C made the extruder click.

Set your default with `clambu setup`, or with `MATERIAL=` in the printer's file in `~/.config/bambu`. Add your own spools in `~/.config/clambu/materials.toml`, with any filament profile name from Bambu Studio:

```toml
[pla-silk]
profile = "Bambu PLA Silk"
plate = "Textured PEI Plate"
nozzle = 225
```

The plates are Textured PEI Plate, Cool Plate, Engineering Plate and High Temp Plate.

## Printer config

`clambu setup` writes this file. You can also edit it by hand:

```sh
# ~/.config/bambu/a1mini.env
PRINTER_IP=192.168.1.50
PRINTER_SERIAL=0309DA000000000
PRINTER_ACCESS_CODE=12345678
PRINTER_MODEL="A1 mini"
PRINTER_NOZZLE=0.4
MATERIAL=pla
PLATE="Textured PEI Plate"
```

`PRINTER_MODEL` is the name in Bambu Studio's printer list without "Bambu Lab", such as `P1S` or `X1 Carbon`. Without it, clambu goes by the serial number.

## Printer connection

| Port | For | How |
|------|-----|-----|
| 8883 | status and commands | MQTT over TLS |
| 990 | uploads and the SD card | FTPS through the system curl, with the access code on its stdin |
| 6000 | camera on the A1, A1 mini, A2L, P1P and P1S | JPEG frames over TLS |

## Development

```sh
swift build
swift test
```

To also check a real sliced file, set `CLAMBU_TEST_3MF` to a PLA `.gcode.3mf`. The tests cover the G-code check, the profiles for each printer model, the printer reports, the plate decisions, the materials file, the JSON state, the status line and the panel under the log, drawn at fixed sizes.

## License

MIT. See [LICENSE](LICENSE). clambu isn't made by or affiliated with Bambu Lab.
