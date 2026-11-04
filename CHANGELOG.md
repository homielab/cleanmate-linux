# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Desktop app: **Run Smart Scan** on System Overview (with when you last scanned) and as the welcome's last step; **Ctrl+F** searches Large & Old Files, Duplicates, Space Lens, Startup Items, Maintenance and Uninstaller too; **Stop** in Large & Old Files and Space Lens; **Never Clean This Folder** from a row's menu in Large & Old Files, Duplicates and Space Lens.
- Desktop app: closing the window while something is cleaning asks first instead of leaving the engine running; opening CleanMate again brings up the window already open.
- Desktop app, **Moved to the Trash** (Ctrl+Shift+5, *Settings › Moved to the Trash*, **View Moved Items** after a clean): everything CleanMate moved to the Trash, also in earlier sessions and from the terminal app, newest first — search, filter by the tool that moved it, **Put Back** one item, the ticked ones or all, **Show in Files**; items emptied from the Trash since are greyed out as *No longer in the Trash*.
- `cm restore --list --gone DAYS` also lists what left the Trash in the last DAYS days; every item now has `inTrash` and `location` (its path in the Trash).
- Desktop app, **Space Lens** for the whole disk: a Locations button opens your home folder, the system disk (`/`) or any other disk, with the full path in the path bar. Outside your home folder each row shows a lock that says why it stays (system packages, Docker, the journal, logs, snaps, another user's files) and links to the page that cleans it; folders you can't read say *no permission* instead of 0. **Ctrl+Shift+.** shows or hides hidden files, and every row has **Open**. System Overview adds **Outside your home folder** with **View in Space Lens**. The terminal Space Lens follows the same rules, and `cm --json lens` adds `reason`, `denied` and `unreadable`; `cm --json places` lists the disks.
- Desktop app: **Why is this safe?** — an ⓘ button on every Smart Scan and Privacy item says what it is, where it is, what cleaning does (rebuilt, moved to the Trash or deleted for good) and when it is skipped; **Open Folder** and **Never Clean** (the item's folders go to *Settings › Never clean*, and scans leave it out). A row locked by a running program names it. `cm --json items` and `scan` carry the same as `why`.
- **Settings › Scan groups**: turn off a whole group (System Junk, Logs, User & App Junk, AI Tools, Developer Junk, Privacy) and Smart Scan leaves it out in both apps, `cm --scan`, `--clean` and automatic cleaning; its page in the desktop app says it is off, with **Turn On**.
- Desktop app: a notification with what a clean freed when the window isn't in front; it reopens on the last page and at the last size; Ctrl+0 and Ctrl+Shift+1…4 open Large & Old Files, Duplicates, Uninstaller, Startup Items and Maintenance; every icon-only button has a name for screen readers.
- Desktop app, **Large & Old Files**, **Duplicates** and **Similar Photos**: images and videos show a thumbnail, **Open** (or Enter on a row) opens a file in its default app, and Similar Photos shows the photo you point at large beside the list, the suggested one marked. Large & Old Files sorts by size, date modified, name or kind and can show only videos, images, disk images and virtual machines, archives, documents or other files.
- Flatpak for Flathub (`packaging/flathub/`): the desktop app and the `cleanmate` engine, with access to your home folder only. In the Flatpak, items and pages that need your password or the host system (apt, the journal, old kernels, Docker, Uninstaller, Startup Items, Maintenance) are left out and System Junk and Logs say why; items whose program must be closed are not pre-selected, because the sandbox can't see running programs. Its Flathub listing shows only screenshots of pages the Flatpak has.
- **Duplicates › Similar Photos** in the desktop app: finds photos that look alike (resized or re-saved copies, edits, burst shots) on your computer only, suggests keeping the largest one and moves the others you tick to the Trash, with Undo. Hidden folders, Never clean folders and Shotwell or digiKam libraries are skipped.
- Desktop app, Smart Scan and the cleanup pages: **Stop** ends a scan and lists what it checked so far; **Ctrl+F** searches the results by name or path; **Never Clean This** on a listed folder (old downloads, stale build folders) adds it to *Settings › Never clean*. The confirmation lists every item with *To the Trash* or *Deleted permanently* and the total of each, and after a clean a summary (space freed, Trash vs deleted, Undo, Open Trash) stays until the next scan. The results show how long the scan took.
- `cm --scan` ends with how long the scan took and its three slowest items; `cm --json scan` gives `durationMs` for each item and for the whole scan (the same field as the macOS app).

- Desktop app, **Large & Old Files**: says how many files it skipped and why, and **Search Other Drives Too** also searches the disks mounted inside the folder you picked (`cm --json large --all-drives`).
- `cm --scan`, `--clean` and automatic cleaning exit with 1 when a task failed and 3 when only part was done (no `sudo`), so scripts can tell; `cm --json clean` reports `status`.

### Changed

- Desktop app in Vietnamese: errors, task results and the low disk, scan reminder and automatic cleaning notifications are translated too (the engine sends codes the app translates); `cm` in the terminal stays in English. Opening the terminal app also works with Konsole and Xfce Terminal.
- Repeat scans of a home with many idle projects are faster: the stale `node_modules` item reads its folders in parallel (about 80 → 60 ms for 50 projects).
- The README starts with what CleanMate does, a screenshot and the install commands, and compares it with BleachBit; the full list of what it cleans moved to `docs/FEATURES.md`.
- Minecraft caches are skipped only while Minecraft itself runs, not while any Java program (an IDE, a Gradle daemon) is open.
- Desktop app: the password dialog says what it's for — cleaning system files, uninstalling apps or Maintenance. Installed with the script or from git, it asks for no password: system items say to install the package or run `sudo cm`.

### Fixed

- The PPA now has CleanMate for every Ubuntu release Launchpad supports: 24.04 LTS, 26.04 LTS and 26.10.
- Automatic cleaning from the PPA, the `.deb` or the snap no longer asks you to install the launcher, and the snap's keeps running after the snap updates.
- Flatpak: the welcome only promises what the Flatpak does, and the welcome and Settings link to what it can't do.
- Desktop app: results are honest. Items whose check ran out of time are listed under **Not finished** with **Scan Again**, and the scan is never called clean while one remains. An engine failure shows its reason, **Copy Details** and **Report a Bug…** on Smart Scan, Large & Old Files, Duplicates and Space Lens instead of an empty page, and items a crashed clean never reached are marked failed, not skipped.
- Desktop app: the clean summary separates the space freed from what went to the Trash, and **Empty Trash…** frees it. Free space is shown for both `/` and the home partition when they differ, and System Overview measures again after a clean. `cm --json clean` adds `to_trash` and `disks` to its `done` event.
- Desktop app, **Uninstaller**: an app that can't be removed keeps its row with the reason, and the summary says how many could not be uninstalled. A dismissed or missing password dialog says so.
- A scan that hits its time limit no longer reports an item as clean when its check was cut short.
- *Never clean* folders inside app caches, app logs and temporary files are kept when those are cleaned.
- Caches stay untouched while Gradle, Android Studio or another tool using them runs, also from a snap or Flatpak.
- System Overview: **Freed** counts only space really freed; what went to the Trash shows below it.
- The `.deb` brings video thumbnails along, and moving to the Trash outside your home folder says when `gio` is missing.

## [2.3.0] — 2026-11-02

### Added

- **User & App Junk** now cleans Steam caches, web cache, logs and crash dumps, often 0.5–2 GB.
- **User & App Junk** also tidies Minecraft and Prism Launcher caches, logs and crash reports.
- Your games, saves, worlds, mods and sign-ins are never touched.

## [2.2.0] — 2026-11-02

### Added

- **Developer Junk** finds many more leftovers: old build folders (Gradle, Flutter, Next.js and more) and Terraform, Helm, minikube, Haskell, Scala and Composer caches.
- **Developer Junk** also finds old versions you no longer use: asdf and mise runtimes, Proton and Wine builds, Unity Editor versions, Vagrant boxes.
- Cleans game launcher caches (Wine, Lutris, Heroic) and the package cache left by GNOME Software.
- See what CleanMate moved to the Trash, even in earlier sessions, and put it back.
- AI agents like Claude Code and Codex can scan and clean with CleanMate, only touching what you confirm.

### Changed

- **Smart Scan** is about a third faster.
- Automatic cleaning and the command line no longer delete Docker volumes or stopped containers, because they may hold your data.
- The About window and GNOME Software link to the CleanMate website.

## [2.1.0] — 2026-11-01

### Added

- A **Welcome** screen on first launch explains what CleanMate cleans and lets you set the main options.
- Notifications for low disk space and, if you want, a reminder to scan.
- **Report a Bug…** in the main menu fills in your system details and opens a GitHub issue. Nothing is sent until you submit.
- **Uninstaller** can reset an app to a fresh start and remove AppImage apps.
- **Privacy** cleans browsing history, downloads list and cookies in Firefox, Chrome, Brave, Edge and more.
- **Startup Items** marks entries left by removed apps as Missing, so you can sweep them out.
- New cleanups: desktop search index, GPU shader cache, old Android SDK versions and old editor extensions (VS Code, Cursor and others).

### Changed

- **System Overview** shows how much space CleanMate freed: last 30 days, in total and last cleanup, with a daily chart.
- **Smart Scan** is faster, especially with many projects or packages.
- New app icon, matching the macOS app.

### Fixed

- Docker sizes now show correctly in languages like Vietnamese, and project build folders no longer go missing from **Smart Scan**.

## [2.0.0] — 2026-10-31

First public release of CleanMate for Linux.

### Cleaning

- **Smart Scan** checks 50+ places in about a second and shows one checklist with sizes, so you choose what goes.
- **System Junk**: APT cache, unused packages, old kernels, old Snap versions, old downloads, installers and screenshots.
- **Logs**: system journal, crash reports and old app logs.
- **User & App Junk**: Trash (also on USB drives), thumbnails, and every browser and app cache as its own choice.
- **AI Tools**: caches and logs of Claude Code, Codex, Cursor and more. Chats and logins are never touched.
- **AI Models**: downloaded Ollama, Hugging Face and LM Studio models, each with its size and never pre-selected.
- **Developer Junk**: package caches, idle `node_modules`, old Node, Python and Java versions, Docker and Android emulator files.
- **Privacy**: shell, recent files and other history.

### Tools

- **Space Lens**, **Large & Old Files**, **Duplicates**, **Uninstaller**, **Startup Items**, **Maintenance** and **System Overview**.
- **Undo** puts back anything CleanMate moved to the Trash.
- **Never clean** lets you pick folders CleanMate must never touch.
- Automatic cleaning every day, week or month, with a low disk alert.

### Apps

- A desktop app for Ubuntu 24.04 and newer, in English and Vietnamese.
- A terminal app and a command line for scripts.

### Install & updates

- Install from the PPA, the `.deb` on GitHub, snap or the install script.

[2.3.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.3.0
[2.2.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.2.0
[2.1.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.1.0
[2.0.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.0.0
