# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Automatic cleaning tries again within the hour if it fails or your laptop sleeps, tells you if it still can't finish, and *Settings* shows its last run.
- The low disk alert now reaches you in the Flatpak too: CleanMate warns you when you open it.

## [2.4.1] — 2026-11-06

First published release of the 2.4 series (a 2.4.0 tag was never published).


### Added

- **Smart Scan** in the desktop app: run it from System Overview and the welcome, **Stop** it any time, and see how long it took and what is still unfinished, with **Scan Again**.
- **Why is this safe?** on every Smart Scan and Privacy item: what it is, what cleaning does and when it is skipped, plus **Open Folder** and **Never Clean**.
- **Moved to the Trash** (Ctrl+Shift+5): everything CleanMate moved to the Trash, also from earlier sessions and the terminal app. Search, filter, **Put Back** or **Show in Files**.
- **Space Lens** reads the whole disk: pick your home folder, the system disk or another drive, and see why each system folder stays and where to clean it.
- **Duplicates › Similar Photos** finds resized, edited or burst copies of the same photo, suggests the biggest to keep and moves the rest to the Trash, with Undo. It runs on your computer only.
- Thumbnails and **Open** for images and videos in Large & Old Files, Duplicates and Similar Photos; Large & Old Files sorts and filters by kind.
- **Settings › Scan groups** turns whole groups of cleaning off, in both apps and in automatic cleaning.
- **Never Clean This Folder** from a row's menu, and **Ctrl+F** search on more pages.
- Unused Flatpak runtimes show up in **System Junk**, and Maintenance says how much removing them frees.
- A notification with what a clean freed, and the window reopens where you left it.
- `man cm` opens a manual page, and `cm --help` lists every `--json` command.
- Flatpak build for Flathub, with access to your home folder only.

### Changed

- **Duplicates** is about six times faster on folders with many same-size files, and repeat scans of a home with many projects are faster.
- Automatic cleaning also clears AI tool caches (never chat history or models), and on a laptop waits until it is plugged in.
- The desktop app speaks Vietnamese in errors, results and notifications too.
- Closing the window during a clean asks first.
- The password dialog says what it is for.
- Minecraft caches are skipped only while Minecraft itself is running.

### Fixed

- Results are honest: a scan that ran out of time lists the item under **Not finished** instead of calling it clean, and failed or partly done cleans exit with a clear code in `cm`.
- Caches stay untouched while Gradle, Maven, Android Studio or similar tools using them run.
- *Never clean* folders are kept inside app caches, logs and temporary files.
- **Freed** counts only space really freed; what went to the Trash shows separately, with **Empty Trash…**.
- **Uninstaller** keeps a row it could not remove and says why.
- The PPA now has CleanMate for Ubuntu 24.04 LTS, 26.04 LTS and 26.10.
- Automatic cleaning from the PPA, `.deb` or snap no longer asks for the launcher.
- Names with “&” and sizes like “<1%” show up everywhere.
- Release builds and PPA uploads are more reliable.

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

[2.4.1]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.4.1
[2.3.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.3.0
[2.2.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.2.0
[2.1.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.1.0
[2.0.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.0.0
