# CleanMate

[![CI](https://github.com/homielab/cleanmate-linux/actions/workflows/ci.yml/badge.svg)](https://github.com/homielab/cleanmate-linux/actions/workflows/ci.yml) [![Latest version](https://img.shields.io/github/v/release/homielab/cleanmate-linux?label=version&color=blue)](https://github.com/homielab/cleanmate-linux/releases/latest) [![PPA](https://img.shields.io/badge/PPA-homielab%2Fcleanmate-E95420?logo=ubuntu&logoColor=white)](https://launchpad.net/~homielab/+archive/ubuntu/cleanmate) ![Ubuntu 22.04 | 24.04](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white) [![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**Free up disk space and keep Ubuntu tidy — safely.** CleanMate is a free, open-source (MIT) cleaner
for Ubuntu: caches, old logs and kernels, leftovers of removed apps, Docker, developer and AI-tool
clutter, each downloaded AI model on its own — and it shows what fills your disk. You see exactly what
it would remove; nothing is deleted until you confirm. A desktop app (GTK 4) *and* a terminal app (`cm`)
share one engine. No account, no telemetry.

[**Website**](https://cleanmate.homielab.com) · [**Download the .deb**](https://github.com/homielab/cleanmate-linux/releases/latest) · [All features](docs/FEATURES.md) · [macOS version](https://github.com/homielab/cleanmate-macos) · [Report a bug](https://github.com/homielab/cleanmate-linux/issues/new/choose)

![CleanMate Smart Scan results in the Ubuntu desktop app](docs/screenshots/desktop-1-results.png)

## Install

**Ubuntu 24.04 LTS** — from the [PPA](https://launchpad.net/~homielab/+archive/ubuntu/cleanmate),
with updates through Software Updater:

```bash
sudo add-apt-repository ppa:homielab/cleanmate
sudo apt install cleanmate
```

Then open **CleanMate** from *Show Apps*, or run `cm` in a terminal.

**Any Ubuntu, without `sudo`** (including 22.04):

```bash
curl -fsSLO https://raw.githubusercontent.com/homielab/cleanmate-linux/main/cleanmate.sh
bash cleanmate.sh --install
```

That adds the app to *Show Apps* and the `cm` command to your terminal, all inside your home
folder. On Ubuntu 22.04 the app grid opens the terminal app (the desktop app needs 24.04+).

**Other ways**

- **Package:** download `cleanmate_<version>_all.deb` from
  [Releases](https://github.com/homielab/cleanmate-linux/releases), double-click it (App Center)
  or `sudo apt install ./cleanmate_*_all.deb`.
- **Just try it:** `bash cleanmate.sh --dry-run` — everything works, nothing is deleted.
- **Flatpak:** coming to Flathub; build it now with `packaging/flathub/build.sh`. It cleans your home
  folder only: apt, the journal, old kernels, Docker and the Uninstaller need the PPA or the `.deb`
  ([what the Flatpak can't do](packaging/flathub/README.md#what-the-flatpak-cant-do)).

Also available for macOS: [CleanMate for macOS](https://github.com/homielab/cleanmate-macos).

## Why

I moved from macOS to Ubuntu and missed [CleanMyMac](https://macpaw.com/cleanmymac): one place
that tells you what's eating your disk and lets you clean it safely. Ubuntu has all the pieces —
`apt-get clean`, `journalctl --vacuum`, `snap remove --revision`, `docker image prune` — but you
have to know they exist and remember the flags. CleanMate puts them behind one Scan button,
with a terminal version first, because that's where most Linux users live.

## Use it

**Desktop app** — press **Scan**, untick anything you want to keep, press **Clean**. Items with a 🔒 need
your password; everything else runs as you. Files moved to the Trash come back with **Undo**. Besides Smart
Scan: System Overview, Space Lens, Large & Old Files, Duplicates, Startup Items, Uninstaller (with
leftovers and Reset…), Maintenance and Settings — each described in [docs/FEATURES.md](docs/FEATURES.md#desktop-app).

| Large & Old Files | Uninstaller |
| --- | --- |
| ![Large & Old Files](docs/screenshots/desktop-7-large.png) | ![Uninstaller](docs/screenshots/desktop-8-uninstall.png) |
| Space Lens | Duplicates |
| ![Space Lens](docs/screenshots/desktop-9-lens.png) | ![Duplicates](docs/screenshots/desktop-10-duplicates.png) |
| Startup Items | Settings |
| ![Startup Items](docs/screenshots/desktop-11-startup.png) | ![Settings](docs/screenshots/desktop-12-settings.png) |

**Terminal app** — run `cm`. Press `1` for a Smart Scan, `c` to clean.

![The terminal app](docs/screenshots/terminal-2-smart-scan.png)

| Key | Action |
|---|---|
| `↑` `↓` / `j` `k` / mouse wheel | Move |
| `space` | Select or deselect (on a group header: the whole group) |
| `enter` / `→` | Open, or show exactly what's inside an item |
| `c` | Clean what's selected — you see the list and confirm first |
| `a` / `n` | Select all / none |
| `h` | Show or hide items that are already clean |
| `/` | Find a row by name |
| `z` | Undo: put back what you just moved to the Trash |
| `q` / `esc` / `←` | Back |
| `?` | Help |

Your choices are remembered by both apps: untick something once and it stays unticked.

## What it cleans

**Smart Scan** checks System Junk (APT, Snap revisions, old kernels, old installers and downloads), Logs,
User & App Junk (caches of each browser and app, Steam, game launchers), AI Tools, AI Models (each Ollama,
Hugging Face and LM Studio model) and Developer Junk (package caches, Docker, old runtime and SDK versions,
stale `node_modules` and build folders) in about a second. **Privacy** clears shell and browser history.
The full list, with what each item keeps: [docs/FEATURES.md › What it cleans](docs/FEATURES.md#what-it-cleans).

## How it compares

| | CleanMate | BleachBit |
|---|---|---|
| Price | Free | Free |
| License | MIT, open source | GPL-3.0, open source |
| Platforms | Ubuntu; macOS (separate app) | Linux, Windows; macOS experimental |
| Uninstall apps with their leftovers | yes | no |
| Map of what fills your disk | yes (Space Lens) | no |
| Each downloaded AI model, old runtime and SDK versions on their own | yes | no |

Checked against BleachBit's own website and documentation (November 2026). More comparisons and sources:
[cleanmate.homielab.com/compare](https://cleanmate.homielab.com/compare/).

## Safe by design

- **You see everything first.** Every clean lists the items and sizes and asks; `→` shows the
  exact files. `--dry-run` shows the commands without running them.
- **It uses the system's own tools** — `apt-get clean`, `journalctl --vacuum-*`,
  `snap remove --revision`, `docker image prune`, `npm cache clean` — instead of deleting by hand.
- **Your files go to the Trash**, in the standard format, and `z` puts them back.
- **It never touches** logins and keys (`.ssh`, `.gnupg`, `auth.json`, `.credentials.json`, …),
  settings, bookmarks, Claude Code memory, the running kernel or its fallback.
- **Recent things stay:** only logs, sessions and caches older than a limit you control are
  removed; apps that are running are asked about (and skipped when unattended).
- **System paths are hard-blocked** (`/`, `/usr`, `/etc`, your home folder itself, …), and when it
  runs as root it refuses anything inside a home folder.
- **Folders you never want touched:** add them in *Settings → Never clean* (both apps), or with *Never Clean
  This* on a folder in the desktop app's scan results. Large & Old
  Files, Duplicates, Space Lens, stale `node_modules` and project build folders, old installers and old
  downloads skip them, and nothing in them is moved to the Trash. Only folders inside your home folder, not
  the home folder itself. Smart Scan's caches and logs ignore the list: their apps rebuild them.
- **Everything is logged** to `~/.local/state/cleanmate/clean.log` (*Settings → Activity log* in both apps).

## Automatic cleaning

*Settings → Automatic cleaning* runs a weekly (or daily, monthly) clean of user and developer
junk and notifies you: *"Freed 1.2 GB. Worth a look: Docker build cache 2.0 GB, Google Chrome
1.8 GB."* It never empties the Trash, never touches browsers, apps, Docker volumes, stopped
containers or project build folders and never needs your password. In the desktop app it's in *Settings* in the main
menu (Ctrl+,); both apps share the same settings.

## Low disk alert and scan reminder

CleanMate notifies you when `/` has less than 10 % free (*Settings → Low disk alert*: 5–20 % or
Off; once a day at most) and, if you turn on *Settings → Scan reminder*, when you haven't scanned
for a week or a month. A daily systemd user timer (`cleanmate-check.timer`) checks while either is
on, and the desktop app checks the disk when it opens. Click the notification to open CleanMate.
Check now with `cm --check`.

## Command line & AI agents

```bash
cm --scan                        # what would Smart Scan find, and which items took longest? (changes nothing)
cm --clean                       # Smart Scan, confirm once, clean
cm --clean --yes --only logs     # clean logs without asking (never Docker volumes or containers)
cm --scan --only privacy         # what history is stored?
cm --check                       # low disk alert and scan reminder now
cm --version                     # version and system details for a bug report
cm --help                        # all options
```

`--dry-run` works with everything. `--only` takes `system,logs,user,browser,apps,ai,models,dev,privacy`
(`privacy` only when named). `--clean --yes` and automatic cleaning never remove Docker volumes or
stopped containers, even when ticked in the app: they may hold data. Clean them in the app, or by
name with `cm --json clean docker_volumes`.

**Machine-readable output.** `cm --json CMD` prints one JSON object per line and nothing else:

```bash
cm --json scan --only logs,dev   # items with id, category, label, bytes, locked, root, trash, data_loss, durationMs
cm --json --dry-run clean ID…    # preview
cm --json clean ID…              # task events, then freed bytes and Trash restore keys
```

**Drive these headlessly too** — what takes up space, without going through the app:

```bash
cm --json lens [--path DIR] [--limit N]                            # one folder, biggest first; movable:false = look only
cm --json large [--min BYTES] [--days N] [--path DIR] [--limit N]   # big files: path, bytes, kind, mtime/atime
cm --json dupes [--min BYTES] [--path DIR] [--limit N]              # groups of identical files, newest copy first
```

`trash [--home-only] PATH…` moves the paths the user confirmed into the Trash (one `task` line per path with a `trash` restore key, or `fail` with the reason — it refuses anything touched by *Never clean* or outside your home folder) and `restore KEY…` puts Trash items back. Nothing is ever deleted for good by hand.

`restore --list [--limit N]` lists what CleanMate moved to the Trash (from any session, app or command)
and is still there, newest first, at most 200 — one object:
`{"version":"<app version>","count":N,"items":[{"trashed","path","size","kind","date","source"}]}`, where `trashed` goes
straight to `restore`. Things you trashed yourself are not listed. `cm restore --list` prints the same
for people: date, size and where each item was.

**AI agents.** An [Agent Skill](https://agentskills.io) in `skills/cleanmate/` teaches Claude Code, Codex
and others to scan first, show you the result and clean only what you confirm:

```bash
bunx skills add homielab/cleanmate-linux
```

## Update & uninstall

**Installed from the PPA or the `.deb`:** Software Updater (or `sudo apt upgrade`) keeps it up to
date; remove it with `sudo apt remove cleanmate`.

**Installed with the script:**

```bash
cm --update       # shows your version and the latest, asks, updates the app and icon
cm --uninstall    # removes cm, the desktop app and the Show Apps entry; asks about settings
```

The app also checks for a new version once a day (one request to GitHub; nothing about you is
sent) and shows **⬆ Update** in the menu — turn it off in *Settings → Daily update check*.

## FAQ

**Is it safe to clean the APT cache, journal and old snaps?**
Yes — that's what `apt-get clean`, `journalctl --vacuum-time` and `snap remove --revision` are for.
Packages are downloaded again if ever needed; the snap version you run is never removed.

**After cleaning, Ubuntu offered an upgrade to a new Ubuntu version. Did something break?**
No. Removing old Snap revisions makes systemd reload, which can bring Ubuntu's routine *"new
release available"* check forward. You can turn that prompt off in *Software & Updates → Updates*.

**Why is my `syslog` so big?**
Usually one service logs far too much. *Logs → Oversized active logs* empties it safely;
`sudo tail -n 1000 /var/log/syslog` shows who's flooding it.

**How does the Uninstaller know when I last used an app?**
From GNOME Shell's own record of opened apps (`~/.local/share/gnome-shell/application_state`),
or else the newest change in the app's own folders (config, cache, data) in your home. Apps with
neither show *Unknown*: they are not counted as unused, so the *Unused for 1/3/6/12+ months*
filter hides them until you press *Show* under the list.

**Does it work over SSH?** Yes — use the terminal app; colours and the mouse work in any modern terminal.

**Where does it keep its data?** `~/.config/cleanmate` (choices, settings, Never clean folders) and
`~/.local/state/cleanmate` (activity log, last scan, stats), plus the sizes of your project folders and the list of unused
packages in `~/.cache/cleanmate` for faster scans. Nothing is sent anywhere —
see the [privacy policy](docs/PRIVACY.md).

## Contributing

Found a bug? In the desktop app, *main menu → Report a Bug…* opens a new GitHub issue with your
CleanMate version, Ubuntu version, desktop, install method and last few activity lines filled in — you
see them first, and they hold no user name or personal file path. From a terminal, paste the output of
`cm --version` into a [new issue](https://github.com/homielab/cleanmate-linux/issues/new/choose).
*Suggest a Feature…* opens the feature request form, and *Share CleanMate* copies the website link.

Bug reports and pull requests are welcome — [CONTRIBUTING.md](CONTRIBUTING.md) explains how it
works, how to add a cleaner and how to run the tests. Plans are in
[docs/ROADMAP.md](docs/ROADMAP.md), releases in [CHANGELOG.md](CHANGELOG.md).
The desktop app is in English and Vietnamese, cleanup item names and descriptions included. It
follows the system's language; *Settings → Language* picks English or Tiếng Việt for CleanMate alone
(restart the app to apply). To translate it, see *Translations* in CONTRIBUTING.md (`po/`).

## Support

CleanMate is free and always will be. If it saved you some space (or some time), you can
[buy me a coffee on Ko-fi](https://ko-fi.com/homielab) ☕ — it keeps the project going.

## License

[MIT](LICENSE) © 2026 [HomieLab](https://homielab.com) · contact@homielab.com

*CleanMate is an independent open-source project, not affiliated with MacPaw or CleanMyMac.*
