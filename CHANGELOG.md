# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Desktop app, **Duplicates**: nothing is ticked after a search, and *Select automatically* now keeps the **oldest** copy of each group (usually the original), like the terminal app, instead of the newest.
- README and app store listing: screenshots of Space Lens, Duplicates, Startup Items and Settings.
- Desktop app, **Startup Items**: switching one of your systemd services or timers on or off now also starts or stops it right away, not only at the next login.

### Added

- Desktop app, **System Overview**: a chart of free space over the last 30 days (hover a day for its date and value) with the trend in words, space in use outside your folders (Timeshift snapshots, the swap file, ext4's reserved space) and the largest folders in your home — click one to explore it in Space Lens. The system and disks still show at once; folder sizes fill in when measured. Opening the page also records the day's free space, so the chart grows without the terminal app.
- Settings › **Old installers** (both apps): choose how many days an installer stays in Downloads before CleanMate offers to clean it (7–3650, default 30). If your Downloads folder is outside your home folder, the item now says so instead of staying silent.
- **Stale project build folders** (Developer Junk, not pre-selected): Cargo `target/`, Python `.venv/` (or `venv/`) and CocoaPods `Pods/` of projects whose project files, lockfiles and Git index haven't changed for 90 days (the *node_modules* setting, now called *Project build folders*). They go to the Trash, so `z` in the terminal app gets them back; the desktop app lists each project with its size. Projects a build or Python process works in, or with a file open, are left alone; automatic cleaning never touches them.
- **Old installers in Downloads** (System Junk, not pre-selected): `.deb`, AppImage, `.iso`, `.img`, `.run`, `.snap` and Flatpak files at the top of your Downloads folder that you downloaded more than 30 days ago. They go to the Trash, so you can get them back (in the terminal app, `z` on the home screen undoes it). The desktop app lists each file with its size, so you can keep some. Subfolders, links, files still downloading and files a program has open are left alone; automatic cleaning never touches them.
- **Trash on external drives** (User & App Junk, not pre-selected): what you deleted on a USB stick or another drive stays in that drive's own Trash and keeps its space used; Smart Scan now finds it and empties it for good. The desktop app lists each drive with its size, so you can empty one and keep another. Read-only and network drives, other users' Trash and files a program still has open are left alone; automatic cleaning never empties it.
- Desktop app in Vietnamese: cleanup item names and descriptions are translated too (Smart Scan, the six cleanup pages, details and the confirm dialog). Names of apps found on your computer and scan notes stay in English; the terminal app is unchanged.
- Desktop app: **System Overview** page, where the app now opens — the system (OS, kernel, uptime, processor, apt/snap/flatpak package counts), each disk with a usage bar that turns to the warning colour over 90 % full, RAM and swap in use, and what CleanMate freed in the last 30 days and in total, with a **Refresh** button. Cleanups are now recorded one by one (`~/.local/state/cleanmate/cleanups.tsv`), so the 30-day figure starts with your next cleanup.
- Desktop app: **Maintenance** page — update everything, repair packages, remove unused Flatpak runtimes, TRIM, free up RAM, rebuild the font cache and update the locate database, each with a Run button and its output in a log window; tasks that change the system ask for your password once. Switches keep fewer snap versions and limit the journal size, showing what is in effect now. A task whose tool isn't installed is locked and says why.
- Desktop app: **Docker dangling images and build cache, one by one** — expand the item to see each image or build-cache record with its size, untick the ones you still need, and Clean removes only the ticked ones; the size shows "selected / total". Build-cache records in use are never listed, and a shared record counts 0 bytes because removing it alone frees nothing. Only for Docker on this computer; the terminal app still cleans them as a whole.
- Desktop app: **Settings** (main menu, Ctrl+,) — automatic cleaning, the daily update check, the low-disk alert, how long logs, temporary files, caches and AI chats are kept, and resetting remembered selections. They are the terminal app's settings: a change in one app shows in the other, and turning on automatic cleaning starts its timer right away.
- Desktop app: **Startup Items** page — the apps and your systemd user services and timers that start when you log in, each with an on/off switch. The system's own services are only shown. Removing one of yours moves its file to the Trash; **Undo** in the notification puts it back (and turns a service on again if it was on).
- Desktop app: **Duplicates** page — identical files (same size, then same content) grouped, biggest first, from a minimum size (1 MB by default) in a folder or drive you choose. Every copy except the newest is ticked (*Select automatically* does it again), you're warned when every copy of a file is ticked, and **Undo** in the notification puts moved copies back. Hard links count as one file.
- Desktop app: **Space Lens** page — your home folder's files and folders by size, biggest first; click a folder to dig deeper, go back with the path bar. Tick what you don't need and move it to the Trash; **Undo** in the notification puts it back. Other folders and drives can be explored too, view only outside your home folder.
- New screenshots of the desktop app, including the Large & Old Files and Uninstaller pages.
- Desktop app in Vietnamese: it follows your system language. Cleanup item names and notes are still in English.
- Developer Junk: uv cache, rustup downloads (installed toolchains are kept) and the Playwright, Puppeteer and Cypress browser downloads (not pre-selected).
- Developer Junk: Firebase CLI debug logs (`firebase mcp` can grow them to gigabytes; a log still being written is skipped) and downloaded Firebase emulators (not pre-selected). Your Firebase login, Crashlytics and extensions are kept.
- AI Tools: ZCode logs (sessions and credentials are kept) and MiMoCode cache and logs (its databases and login are kept); both are skipped while the tool runs.
- AI Tools: caches and logs of Cursor, Windsurf (code index, browser cache), Cline and Kilo Code, and opencode logs. Chats, sessions, settings and logins are kept.
- Desktop app: larger checkboxes, rows at least 48 px tall, a three-state checkbox on each group header, and the reason shown on items that need your password.
- Desktop app: **Large & Old Files** page — list your biggest files by minimum size, how long they've been unused and folder (or drive), tick them and move them to the Trash; **Undo** in the notification puts them back where they were.
- Desktop app: **Uninstaller** page — your apt, Snap and Flatpak apps with their size and last use, search and sort; each app's own folders in your home are listed under it and go to the Trash with it if ticked (*Restore folders* in the notification puts them back). Parts of Ubuntu are never listed, and apt is checked first: you're told about other packages it would remove, and removals that would take something Ubuntu needs are refused.
- Desktop app: an item whose program is running (a browser, Claude Code, LM Studio…) shows a lock and "Close <program> and scan again", and can't be selected, also not with the group checkbox. The terminal app shows "close <program> first" next to it.

### Fixed

- Large & Old Files and Duplicates: files on a USB or other mounted drive (under `/media` or `/mnt`) now go to that drive's own Trash, so **Undo** in the notification (and `z` in the terminal app) puts them back.
- Undo (`z`) never replaces or moves into a file or folder that appeared where the trashed file used to be.
- Terminal app: key presses were sometimes ignored with bash older than 5.3 (Ubuntu 22.04 and 24.04), and keys typed while a screen was busy were printed over it.

## [2.0.0] — 2026-10-25

**Clean My Ubuntu is now CleanMate**, the name of HomieLab's cleaner on every platform.

### Changed

- The app, the command (`cleanmate`), the package and the app ID (`com.homielab.CleanMate`) are
  renamed. The short command is now `cm`.
- The repository moved to [homielab/cleanmate-linux](https://github.com/homielab/cleanmate-linux)
  (the old address redirects).

### Moving over

- Settings, remembered selections, logs and automatic cleaning move to their new place the first
  time CleanMate starts; the journal limit (*Maintenance*) is still honoured.
- **PPA:** a normal upgrade installs `cleanmate`; `clean-my-ubuntu` stays as a small transitional
  package that keeps the `clean-my-ubuntu` and `cmu` commands working (safe to remove).
- **Installed with the script:** `--update` (or the daily check) installs CleanMate and replaces
  the old launcher; `clean-my-ubuntu` and `cmu` keep working as links to `cleanmate`.
- **`.deb` from Releases:** installing `cleanmate_2.0.0_all.deb` removes `clean-my-ubuntu`.
- A pinned launcher in the dock needs pinning again (the app ID changed).

## [1.1.1] — 2026-10-17

### Fixed

- Scanning no longer runs Podman for people who have it installed but never used it — `podman
  info` would create Podman's folders in your home, and a scan must change nothing.
- A Conda installed in your home folder (`~/miniconda3`, …) is preferred over one on the `PATH`.

1.1.1 is the first GitHub release with the 1.1.0 features (1.1.0's release build stopped at the
tests).

## [1.1.0] — 2026-10-17

### Cleaning

- **AI Models** — every downloaded Ollama, Hugging Face and LM Studio model is listed on its own
  with its size. They're never pre-selected, automatic cleaning never touches them, and a tick is
  not remembered for the next scan. Ollama models are removed with `ollama rm`.
- **Conda** package cache (`conda clean --all`), **Podman** stopped containers and dangling
  images (`podman system prune`), and **Steam's shader cache**.
- *Stale app caches* no longer removes Hugging Face or LM Studio files from `~/.cache` — models
  are only removed when you pick them.

### Tools

- **Maintenance → Keep fewer snap versions** (`snap set system refresh.retain=2`) and **Limit
  journal size** (a journald drop-in using *Settings → Journal size limit*), so the same junk
  doesn't come back after a clean. Both can be undone from the same menu.
- **System Overview → Space outside your folders:** Timeshift snapshots, the swap file and ext4's
  reserved space — explained, never deleted.
- **Large & Old Files → Virtual machine disks:** VirtualBox, VMware, GNOME Boxes, virt-manager and
  Multipass disk images.
- **Uninstaller, rebuilt:** opens straight to the list of your apps (from their launchers — no
  libraries or drivers), each with its total size (app + its folders in your home) and when you
  last used it (GNOME's record of opened apps, or the newest change in its folders). `s` sorts by
  size, last use or name; `f` shows only apps unused for 90+ days or over 500 MB; `enter` shows
  the details. Parts of Ubuntu itself are hidden. The old search over every package is under `p`.
- **Safer uninstalling:** a removal is refused when apt would also take something Ubuntu needs
  (GNOME Shell, GDM, systemd, sudo, NetworkManager, the running kernel, …), and folders shared by
  several apps are never offered for the Trash.
- **Update everything** first lists what will be updated (apt, snap, flatpak) before asking.
- Flatpak apps now show their size in the Uninstaller.

## [1.0.1] — 2026-10-15

### Packaging

- **PPA** — install with `sudo add-apt-repository ppa:homielab/clean-my-ubuntu`
  and `sudo apt install clean-my-ubuntu`, with updates through Software Updater.
- The snap is now a single build for all architectures.

## [1.0.0] — 2026-10-13

First public release.

### Cleaning

- **Smart Scan** — 50+ locations scanned in parallel in about a second; one checklist with sizes,
  remembered choices, and a confirm dialog that lists exactly what will be removed.
- **System Junk** — APT cache, unused packages, extra old kernels (a fallback always stays),
  leftover configs, old Snap revisions, old temp files.
- **Logs** — systemd journal, rotated and oversized live logs, crash reports, core dumps, old app logs.
- **User & App Junk** — Trash, thumbnails, stale caches, and every browser and app cache as its own choice.
- **AI Tools** — caches, logs and old sessions of Claude Code, Claude Desktop, Codex,
  Gemini/Antigravity, opencode, Zed, Copilot CLI and Continue; memory and logins are never touched.
- **Developer Junk** — npm, Yarn, pnpm, Bun, pip, Go, Cargo, Gradle, Maven, idle `node_modules`,
  and Docker images, build cache, containers and volumes as separate items.
- **Privacy** — shell, Recent files, REPL, Vim, Alt+F2 and emoji history.

### Tools

- Space Lens, Large & Old Files, Duplicates (with **undo** via the Trash), Uninstaller (apt, Snap,
  Flatpak and leftovers), Startup Items, Maintenance, System Overview with free-space history.
- **Automatic cleaning** — daily/weekly/monthly systemd user timer; the notification reports what
  was freed and what's left to review; low-disk alert.

### Apps

- **Desktop app** (Ubuntu 24.04+) — GTK 4 + libadwaita, Smart Scan and the six cleanup sections;
  system items use the standard password dialog.
- **Terminal app** (`cmu`) — keyboard and mouse, `/` find, `z` undo, `?` help, works from 60×20.
- **Command line** — `--scan`, `--clean [--yes]`, `--only`, `--dry-run`, `--auto`, `--json`.

### Install & updates

- `--install` adds `cmu`, the desktop app and a *Show Apps* entry with icon (downloading the app
  files when the script was installed on its own); `--update` and `--uninstall` cover all of it.
- `.deb` package with AppStream metadata and a polkit policy, built by CI for every release.

### Quality

- 27 tests (`tests/run.sh`) in a throwaway home folder, including the terminal UI and a headless
  desktop-app self-test; CI with ShellCheck on Ubuntu 22.04 and 24.04.

[2.0.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.0.0
[1.1.1]: https://github.com/homielab/clean-my-ubuntu/releases/tag/v1.1.1
[1.1.0]: https://github.com/homielab/clean-my-ubuntu/releases/tag/v1.1.0
[1.0.1]: https://github.com/homielab/clean-my-ubuntu/releases/tag/v1.0.1
[1.0.0]: https://github.com/homielab/clean-my-ubuntu/releases/tag/v1.0.0
