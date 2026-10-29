<p align="center">
  <img src="data/icons/hicolor/scalable/apps/com.homielab.CleanMate.svg" width="128" height="128" alt="CleanMate icon">
</p>

<h1 align="center">CleanMate</h1>

<p align="center">
  <a href="https://github.com/homielab/cleanmate-linux/actions/workflows/ci.yml"><img src="https://github.com/homielab/cleanmate-linux/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/version-2.0.0-blue" alt="Version 2.0.0">
  <a href="https://launchpad.net/~homielab/+archive/ubuntu/clean-my-ubuntu"><img src="https://img.shields.io/badge/PPA-homielab%2Fclean--my--ubuntu-E95420?logo=ubuntu&logoColor=white" alt="PPA"></a>
  <img src="https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white" alt="Ubuntu 22.04 | 24.04">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT">
  <a href="https://ko-fi.com/homielab"><img src="https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=ko-fi&logoColor=white" alt="Support on Ko-fi"></a>
</p>

**Free up disk space and keep Ubuntu tidy — safely.** CleanMate finds caches, old logs,
leftovers of removed apps, developer and AI-tool clutter, and shows you exactly what it would
remove. Nothing is deleted until you confirm. It's a desktop app *and* a terminal app (`cm`)
that share one engine. Formerly **Clean My Ubuntu**.

[Install](#install) · [What it cleans](#what-it-cleans) · [Safety](#safe-by-design) · [FAQ](#faq) · [Report a bug](https://github.com/homielab/cleanmate-linux/issues)

![The desktop app](docs/screenshots/desktop-1-results.png)

## Why

I moved from macOS to Ubuntu and missed [CleanMyMac](https://macpaw.com/cleanmymac): one place
that tells you what's eating your disk and lets you clean it safely. Ubuntu has all the pieces —
`apt-get clean`, `journalctl --vacuum`, `snap remove --revision`, `docker image prune` — but you
have to know they exist and remember the flags. CleanMate puts them behind one Scan button,
with a terminal version first, because that's where most Linux users live.

## Install

**Ubuntu 24.04 LTS** — from the [PPA](https://launchpad.net/~homielab/+archive/ubuntu/clean-my-ubuntu),
with updates through Software Updater:

```bash
sudo add-apt-repository ppa:homielab/clean-my-ubuntu
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

## Use it

**Desktop app** — open *CleanMate*, press **Scan**, untick anything you want to keep, press
**Clean**. Items with a 🔒 need your password (the standard Ubuntu dialog); everything else runs
as you. **Large & Old Files** lists your biggest files (by minimum size, how long unused, and
folder or drive); what you move to the Trash comes back with **Undo**. **Uninstaller** removes apt,
Snap and Flatpak apps and, if you tick them, the folders they leave in your home (to the Trash).

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

**Smart Scan** checks all of these at once (≈ 1 s):

| | What | Examples |
|---|---|---|
| **System Junk** | Package and system leftovers | APT cache, unused packages, extra old kernels (a fallback always stays), leftover configs, old Snap revisions, old temp files |
| **Logs** | Logs nobody reads | systemd journal (keeps 7 days), rotated logs, oversized live logs (e.g. a 300 MB `syslog`), crash reports, core dumps, old app logs |
| **User & App Junk** | Your caches | Trash, thumbnails, stale caches, and **each browser** and **each app** (VS Code, Slack, Discord, Steam's shader cache, Snap and Flatpak apps) as its own choice |
| **AI Tools** | AI assistant clutter | caches, logs and *old* sessions of Claude Code, Claude Desktop, Codex, Gemini/Antigravity, Cursor, Windsurf, opencode, Cline, Kilo Code, MiMoCode, ZCode, Zed, Copilot CLI, Continue |
| **AI Models** | Downloaded models | **each** Ollama, Hugging Face and LM Studio model on its own — never pre-selected, never cleaned automatically |
| **Developer Junk** | Build and package caches | npm, Yarn, pnpm, Bun, pip, uv, Go, Cargo, rustup downloads, Gradle, Maven, Conda; Docker images, build cache, containers and volumes (each separately); Podman; Playwright, Puppeteer and Cypress browsers (never pre-selected); Firebase CLI logs and downloaded emulators (not pre-selected); `node_modules` of projects idle for 90 days |

**Privacy** (never part of Smart Scan) clears shell history (bash, zsh, fish), *Recent files*,
Python/Node/database shell history, Vim history, and the Alt+F2 and emoji history.

**More tools in the terminal app** (the Uninstaller and Large & Old Files are in the desktop app too):

- **Uninstaller** — every app you can open (apt, Snap, Flatpak), with its real size (the app *plus*
  its folders in your home) and when you last used it. Sort by size or last use, or show only apps
  you haven't opened in 90+ days. Parts of Ubuntu itself are hidden, and a removal that would take
  something Ubuntu needs with it (GNOME Shell, the login screen, sudo, the running kernel…) is
  refused. Afterwards it offers the app's own folders for the Trash — never folders other apps share.
- **Maintenance** — update everything (with a list of what will change first), repair packages,
  TRIM, free RAM, and lasting limits so old snap versions and system logs don't pile up again.
- **System Overview** — storage, free-space history, and space outside your folders: Timeshift
  snapshots, the swap file, ext4's reserved space.
- Space Lens (browse folders by size), Large & Old Files (here with virtual machine disks),
  Duplicates, Startup Items and Settings.

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
- **Everything is logged** to `~/.local/state/cleanmate/clean.log` (*Settings → Activity log*).

## Automatic cleaning

*Settings → Automatic cleaning* runs a weekly (or daily, monthly) clean of user and developer
junk and notifies you: *"Freed 1.2 GB. Worth a look: Docker build cache 2.0 GB, Google Chrome
1.8 GB."* It never empties the Trash, never touches browsers or apps, never needs your password,
and can warn you when the disk is almost full.

## Command line

```bash
cm --scan                        # what would Smart Scan find? (changes nothing)
cm --clean                       # Smart Scan, confirm once, clean
cm --clean --yes --only logs     # clean logs without asking
cm --scan --only privacy         # what history is stored?
cm --help                        # all options
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

**I had Clean My Ubuntu. What changes?**
Only the name. Updates move you over by themselves — from the PPA (the same one), the `.deb` or
`--update` — and bring your settings, logs and automatic cleaning along. The old
`clean-my-ubuntu` command keeps working; the short command is now `cm`.

**Is it safe to clean the APT cache, journal and old snaps?**
Yes — that's what `apt-get clean`, `journalctl --vacuum-time` and `snap remove --revision` are for.
Packages are downloaded again if ever needed; the snap version you run is never removed.

**After cleaning, Ubuntu offered an upgrade to a new Ubuntu version. Did something break?**
No. Removing old Snap revisions makes systemd reload, which can bring Ubuntu's routine *"new
release available"* check forward. You can turn that prompt off in *Software & Updates → Updates*.

**Why is my `syslog` so big?**
Usually one service logs far too much. *Logs → Oversized active logs* empties it safely;
`sudo tail -n 1000 /var/log/syslog` shows who's flooding it.

**Does it work over SSH?** Yes — use the terminal app; colours and the mouse work in any modern terminal.

**Where does it keep its data?** `~/.config/cleanmate` (choices, settings) and
`~/.local/state/cleanmate` (activity log, last scan, stats). Nothing is sent anywhere —
see the [privacy policy](docs/PRIVACY.md).

## Contributing

Bug reports and pull requests are welcome — [CONTRIBUTING.md](CONTRIBUTING.md) explains how it
works, how to add a cleaner and how to run the tests. Plans are in
[docs/ROADMAP.md](docs/ROADMAP.md), releases in [CHANGELOG.md](CHANGELOG.md).

## Support

CleanMate is free and always will be. If it saved you some space (or some time), you can
[buy me a coffee on Ko-fi](https://ko-fi.com/homielab) ☕ — it keeps the project going.

## License

[MIT](LICENSE) © 2026 [HomieLab](https://homielab.com) · contact@homielab.com

*CleanMate is an independent open-source project, not affiliated with MacPaw or CleanMyMac.*
