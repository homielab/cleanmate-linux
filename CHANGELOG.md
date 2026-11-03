# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Flatpak for Flathub (`packaging/flathub/`): the desktop app and the `cleanmate` engine, with access to your home folder only. In the Flatpak, items and pages that need your password or the host system (apt, the journal, old kernels, Docker, Uninstaller, Startup Items, Maintenance) are left out and System Junk and Logs say why; items whose program must be closed are not pre-selected, because the sandbox can't see running programs.

### Changed

- Minecraft caches are skipped only while Minecraft itself runs, not while any Java program (an IDE, a Gradle daemon) is open.

## [2.3.0] — 2026-11-02

### Added

- **User & App Junk** (both apps): Steam caches — the web cache of Steam's store and library pages (`appcache/httpcache`, `config/htmlcache`), depot manifests, logs and crash dumps, for deb, Flatpak and Snap Steam; often 0.5–2 GB. One row per folder, pre-selected, skipped while Steam runs; a Steam folder reached through a link counts once. Games, downloads, Proton prefixes, saves and your sign-in are never touched.
- **User & App Junk** (both apps): Minecraft caches — the official launcher's logs, crash reports and web cache (`~/.minecraft`, Flatpak) and Prism Launcher's logs, download cache and each instance's logs and crash reports (also Flatpak). One row per folder, pre-selected, skipped while a launcher or Java runs. Worlds, mods, resource packs, screenshots, settings and accounts are never touched.

### Changed

- `cleanmate --json restore --list`: `version` is now the app version as a string (like the other commands and the macOS app), not the number `1`.

## [2.2.0] — 2026-11-02

### Changed

- The About window, GNOME Software and the README now link to the website, [cleanmate.homielab.com](https://cleanmate.homielab.com), with guides and downloads; the source code stays one click away in About.
- **Smart Scan** is about a third faster: the engine loads faster and starts 40 % fewer helper processes while scanning (a whole scan on a 4-core Ubuntu 24.04 machine: 0.09 s instead of 0.14 s). Results are unchanged.
- **Command line**: `cm --clean --yes` and automatic cleaning no longer remove Docker volumes or stopped containers, even when they are ticked in the app — they may hold databases or other data and are deleted for good. Each one skipped is named, with how to clean it on purpose (in the app, or `cm --json clean docker_volumes`). `cm --json items` and `scan` mark these items with `data_loss`, and the Agent Skill cleans them only when you name them.

### Added

- **Undo across sessions**: `cm --json restore --list` (and `cm restore --list` in a terminal) lists what CleanMate moved to the Trash and is still there — from the apps, a clean or `cm --json trash` — newest first with size, date and where it came from; each `trashed` key goes straight to `cm --json restore`. Things you trashed yourself are not listed. The Agent Skill uses it when you ask to get something back.
- **Developer Junk** (both apps): stale project build folders now include Gradle and Android (`build/`, `.gradle/`, `app/build/`), Maven, SwiftPM, Flutter, Next.js, Nuxt, SvelteKit, Angular, Turborepo, Haskell, Elixir and Zig projects untouched for 90 days. Each folder is listed only next to the project file that makes it, never through a symlink; still moved to the Trash, with Undo.
- **Developer Junk** (both apps): old Vagrant box versions, one by one in the desktop app. The newest version of each box and those your machines use are kept; not pre-selected, skipped while Vagrant runs.
- **Developer Junk** (both apps): package caches of Haskell (cabal, Stack, ghcup), Scala (Coursier, Ivy, sbt) and OCaml (opam), not pre-selected, and the Composer cache, each skipped while its tool runs. Installed compilers, tools, local Ivy packages and opam switches are kept.
- The desktop app in Vietnamese now translates the Terraform, minikube, Helm, Haskell, Scala, opam, Composer and Vagrant items.
- **Developer Junk** (both apps): infrastructure tool caches — the Terraform/OpenTofu plugin cache and the minikube download cache (ISO, preloaded images; not pre-selected) and the Helm cache, each skipped while its tool runs. Clusters, profiles, certificates, Helm repositories and plugins are kept.
- **Stale project build folders** now include `.terraform/providers` and `.terraform/modules` of Terraform/OpenTofu projects idle for 90 days (moved to the Trash; state files are never touched).
- **AI agents**: large files, Space Lens and Duplicates can be driven headlessly, without the app. `cm --json lens`, `large` and `dupes` list what is taking up space (they now accept `--limit` besides `--path`/`--min`/`--days`), and `cm --json trash [--home-only]` plus `cm --json restore` move just the confirmed paths to (and back from) the Trash, refusing anything outside your home folder or excluded in *Never clean*. The README documents the commands and the Agent Skill uses them instead of pointing agents to the app — they never delete files by hand. An Agent Skill (`skills/cleanmate/`) lets Claude Code, Codex and other agents scan with `cm --json`, show the result and clean only what you confirm.
- **System Junk › PackageKit cache**: packages and package lists GNOME Software and Software Updater downloaded to `/var/cache/PackageKit`, often hundreds of MB that `apt-get clean` leaves. Ticked by default; skipped while PackageKit, GNOME Software or Software Updater is running.
- **Uninstaller (terminal app)**: **f** now also shows apps not used for 365+ days, after the 90+ days filter.
- **User & App Junk** (both apps): game launcher caches — installers winetricks and Wine downloaded (`~/.cache/winetricks`, `~/.cache/wine`) and the cover art and temporary installers of Lutris and Heroic, deb and Flatpak. One row per folder, pre-selected, skipped while a launcher, Wine or Proton runs; Wine prefixes, games and saves are never touched.
- **Developer Junk** (both apps): old asdf and mise runtime versions (Node.js, Python, Ruby, Java…, often 100 MB–1 GB each). The newest version of each tool is kept, as is every version pinned in `~/.tool-versions`, mise's settings or the `.tool-versions` / `mise.toml` of a project in your home; a pin like `20` or `lts` keeps the newest match. Not pre-selected, deleted for good (`asdf install` or `mise install` brings one back), skipped while asdf or mise runs, a version a program runs from is skipped; each version on its own in the desktop app.
- **Developer Junk** (both apps): old Proton and Wine versions — Proton-GE, Wine-GE and other builds (often 0.5–1 GB each) that Steam (`compatibilitytools.d`), Lutris, Heroic and Bottles leave behind, deb and Flatpak. The newest of each and the versions a game or bottle is set to use are kept; Steam's own Proton is never touched. Not pre-selected, deleted for good (the launcher or ProtonUp-Qt downloads any version again), skipped while a launcher, Wine, Proton or gamescope runs; each version on its own in the desktop app.
- **Developer Junk** (both apps): old Unity Editor versions in Unity Hub (often 5–15 GB each). The newest is kept, as is every version a project uses (its `ProjectSettings/ProjectVersion.txt`, for Unity Hub's projects and projects in your home). Not pre-selected, deleted for good (Unity Hub installs one again), skipped while Unity or Unity Hub runs; each version on its own in the desktop app.
- **Developer Junk** (both apps): Unity caches — package, build and Asset Store downloads (`~/.cache/unity3d`, `~/.config/unity3d/cache`, `~/.local/share/unity3d`). Not pre-selected, skipped while Unity runs; licenses, settings and game saves are kept.

### Fixed

- **Developer caches**: when `XDG_CACHE_HOME` is not set, the scan no longer looks for Deno, Zig, Bazel, ccache, sccache, Poetry, pipx, pre-commit and GPU shader caches at the root of the disk (`/zig`, `/pre-commit`, …). Nothing there was ever deleted.

## [2.1.0] — 2026-11-01

### Added

- **Desktop search index** (User & App Junk, not pre-selected): the file search index of GNOME (Tracker / LocalSearch, `~/.cache/tracker3`) and KDE (Baloo, `~/.local/share/baloo`), which can grow to several GB. Reset with `localsearch3`/`tracker3 reset --filesystem` or `balooctl6 purge` when installed, otherwise the folder is emptied while the indexer is not running. File search is slow or incomplete until it is rebuilt; indexing settings are kept.
- **GPU shader cache** (User & App Junk, not pre-selected): shaders compiled by Mesa, NVIDIA and Qt (often 1–5 GB on gaming machines), each folder listed with its size. Skipped while Steam, Lutris, Heroic, Gamescope or Wine/Proton run; a game may stutter briefly the first time afterwards.
- **Welcome** (desktop app): the first time it opens, three short steps — what CleanMate cleans and how it keeps your files safe, what needs your password and what it never touches, and the main options (language, automatic cleaning, scan reminder, low disk alert), saved like in Settings. *Main menu → Getting Started…* shows it again.
- **Report a Bug…** (desktop app, main menu): shows your CleanMate version, Ubuntu version, desktop (GNOME, Wayland or X11), how CleanMate was installed (deb, PPA, snap…), language and last five activity lines — without your user name or personal file paths — then opens a new GitHub issue with them filled in. Nothing is sent until you submit it. **Suggest a Feature…** opens the feature request form and **Share CleanMate** copies the website link. `cm --version` prints the same details, and `--json sysreport` gives them to other tools.
- **Startup Items** (both apps): login entries and systemd user services whose program is gone — left behind by an app you removed — are marked **Missing** and listed first under *Broken items* in the desktop app, with **Remove** (the file goes to the Trash, a service is turned off first; Undo puts it back). The terminal app marks them with **!** and moves them to the Trash with **t** (**z** puts them back). `--json startup` adds `missing` and `missing_cmd`.
- **Low disk alert and scan reminder** (both apps): a notification when `/` has less than 10 % free (*Settings → Low disk alert*: 5–20 % or Off; once a day at most), and, when *Settings → Scan reminder* is on, when no scan ran for a week or a month. A daily systemd user timer checks, the desktop app checks the disk when it opens, and clicking the notification opens CleanMate. `cm --check` checks now.
- **Uninstaller** (both apps): **Reset** an app — it stays installed and its data in your home (config, cache, data and state folders; a Flatpak app's `~/.var/app` data, a snap's current revision) goes to the Trash, so it starts as if new. The desktop app lets you untick folders and offers **Restore**; the terminal app resets with **r** and puts it back with **z**. Refused while the app runs.
- **Uninstaller** (both apps): AppImage apps — an AppImage with a launcher in `~/.local/share/applications` (made by hand, AppImageLauncher or Gear Lever) is listed as kind *AppImage*, its size the file plus its folders in your home. Uninstalling moves the file, its launcher and the icon only it uses to the Trash, as you and without a password; **Restore** (desktop app) or **z** (terminal app) puts it back. A running AppImage is skipped.
- **Privacy** (both apps): browsing history, the downloads list and cookies of Firefox, Chrome, Chromium, Brave, Edge, Vivaldi and Opera (deb, Snap and Flatpak, every profile), one item per browser with the number of entries. Passwords, bookmarks and extensions are kept; clearing signs you out of websites. Not pre-selected, skipped while the browser runs; Firefox needs `sqlite3`.
- **Developer Junk** (both apps): old Android SDK components — the NDK (1–4 GB each), build-tools, SDK platform and CMake versions an SDK Manager update leaves behind in `~/Android/Sdk`, `ANDROID_HOME` or `ANDROID_SDK_ROOT`. The newest of each kind and the versions a project in your home pins in `build.gradle`, `build.gradle.kts` or `local.properties` are kept. Not pre-selected, deleted for good (the SDK Manager downloads any version again), skipped while Android Studio, Gradle or the emulator runs; each version on its own in the desktop app.
- **Developer Junk** (both apps): old extension versions of VS Code, VS Code Insiders, VSCodium, Cursor and Windsurf (also the Flatpak builds) — each extension update leaves the previous version behind, often 100–500 MB. The newest version and the one the editor uses are kept. Not pre-selected, deleted for good (the editor downloads any version again), skipped while that editor runs; each extension on its own in the desktop app.

### Changed

- **System Overview** (desktop app): *Freed by CleanMate* shows three cards with big numbers — the last 30 days, in total and the last cleanup with its date and time — and a bar per day over the last 30 days; hover a bar for the day and what it freed. The numbers count up once when the page opens, unless animations are turned off in the system settings.
- **App icon**: the same broom and sparkles as the macOS app, on a white tile with a gray-to-black glyph.
- **Smart Scan** is faster on a computer with many projects: idle `node_modules`, project build folders and editor data of deleted projects are measured several at a time (up to one per CPU) and their sizes are kept in `~/.cache/cleanmate` until something in the folder changes: a file added or removed up to three levels down, or anything CleanMate moves to the Trash or puts back inside it (a week at most). On 50 projects these items take 0.24 s instead of 0.38 s, and 0.10 s on the next scan.

- **Smart Scan** no longer waits about a second for **Unused packages** on a computer with many packages: apt now works out the list from the installed packages alone, without loading the package lists, and the answer is kept in `~/.cache/cleanmate` until a package is installed, removed or marked, apt's settings change or another kernel runs (a day at most). With 2700 packages (Ubuntu 24.04 container) this item takes 0.09 s instead of 1.25 s, under 0.02 s on the next scan, and a whole Smart Scan 0.64 s instead of 1.44 s; the packages found and what cleaning removes are unchanged.

- **Smart Scan** starts and finishes sooner: simple items (caches, AI tool folders, Trash) are scanned a few per process instead of one process each, the scan wakes when an item is done instead of every 0.1 s, and loading reads your shell startup files once instead of running `grep` per variable. Measured in an Ubuntu 24.04 container on a busy machine (the scan of `tests/bench-scan.sh`, old and new version taking turns, median of 15): a first scan 0.62 s instead of 1.18 s, a scan again 0.58 s instead of 1.05 s. Results are unchanged.

### Fixed

- **Project build folders** could leave out a project at random during Smart Scan, when another item was reading a folder of it at the same moment.
- **Docker** sizes (both apps) were wrong or missing when the system language writes decimals with a comma (Vietnamese, German, French…): a 1.5 GB volume showed as 1 GB, and unused volumes or the build cache sized by `docker system df` could show 0 B and drop out of the scan. Sizes like Docker's "1.5GB" now read the same in every language.

## [2.0.0] — 2026-10-31

First public release of CleanMate for Linux.

### Added

- **Developer Junk** (both apps): Android emulator snapshots — the `snapshots` folder of each virtual device (`~/.android/avd`, `ANDROID_AVD_HOME`, `ANDROID_USER_HOME`, `ANDROID_EMULATOR_HOME`, `ANDROID_SDK_HOME`, and AVDs an `.ini` points to elsewhere), often several GB each. The next start is a cold boot; disks (`userdata*.img`, `sdcard.img`) and settings stay. Not pre-selected, deleted for good, skipped while the emulator runs; each AVD on its own in the desktop app.
- **User & App Junk** (both apps): the Telegram Desktop media cache (`cache` and `media_cache` of each account in `tdata`, also the Snap and Flatpak builds; logins and chats are never touched) and the Spotify cache (`~/.cache/spotify/Storage`; it also holds songs downloaded for offline listening, which must be downloaded again) — often 5–20 GB. Not pre-selected, deleted for good, skipped while the app runs. The stale `~/.cache` item no longer counts Spotify's cache.
- Desktop app, **Uninstaller**: remove several apps at once — tick them (the box above the list ticks or unticks every app shown, and ticks stay while you search, filter or sort), check the selection in the panel at the top, then **Uninstall N apps…** asks once and your password once: all apt apps go in one `apt-get purge` and all snaps in one `snap remove`, Flatpak apps as you. Each app reports on its own, so one that fails doesn't stop the others; an app that is running is skipped and says so. The folders of every removed app go to the Trash together, and **Restore folders** puts them all back.
- **Developer Junk** (both apps): caches of Deno, Zig, Bazel, ccache, sccache, NuGet, Poetry, pre-commit and `pipx run`, each its own item — often 1–10 GB, made again by the next build or run. Not pre-selected, deleted for good, skipped while the tool runs (also a Bazel server) or has a file open in the folder; automatic cleaning leaves them alone. Only cache folders are listed, also where `DENO_DIR`, `ZIG_GLOBAL_CACHE_DIR`, `CCACHE_DIR`, `SCCACHE_DIR`, `POETRY_CACHE_DIR`, `PRE_COMMIT_HOME`, `PIPX_HOME` or `XDG_CACHE_HOME` move them; Deno's `location_data`, Poetry virtualenvs, pipx apps, `ccache.conf`, Bazel's workspace outputs and `~/.nuget/packages` are never touched.
- **User & App Junk** (both apps): Dropbox, Nextcloud / ownCloud and MEGAsync client caches — Dropbox's logs and the `.dropbox.cache` of each Dropbox folder in `~/.dropbox/info.json` (older copies of synced files, often GBs; files changed in the last 7 days stay), the Nextcloud / ownCloud logs and `~/.cache` folders, and MEGAsync's logs. Not pre-selected, deleted for good, skipped while the client runs or has a file open; automatic cleaning leaves them alone. Synced folders, settings and logins are never touched.
- Desktop app, **Space Lens**: on a USB stick or other writable drive (mounted under `/media`, `/run/media` or `/mnt`) you can now tick things and move them to the Trash — the drive's own Trash, so the space comes back there — and **Undo** puts them back. The path bar starts at the drive. Read-only and network drives, the drive's Trash and Timeshift backups stay view only.
- **AI Models** (both apps): models PyTorch Hub, Whisper, sentence-transformers and Keras downloaded — `~/.cache/torch/hub/checkpoints`, `~/.cache/whisper`, `~/.cache/torch/sentence_transformers`, `~/.keras/models` and `datasets`, also where `TORCH_HOME`, `SENTENCE_TRANSFORMERS_HOME`, `KERAS_HOME` or `XDG_CACHE_HOME` point — often several GB, downloaded again when a program needs them. Not pre-selected, each model on its own in the desktop app, deleted for good; a model a program has open is skipped, and automatic cleaning leaves them alone.
- **Developer Junk**: old JetBrains IDE and Android Studio versions — each upgrade of IntelliJ IDEA, PyCharm, WebStorm, Android Studio and the other JetBrains IDEs leaves the old version's settings, plugins, caches and logs behind (`IntelliJIdea2023.1`, `AndroidStudio2023.3`… in `~/.config`, `~/.local/share` and `~/.cache`, also in Flatpak and Snap builds), often 1–5 GB each. A version is offered only when a newer version of the same IDE is there; its folders count as one, listed on their own in the desktop app, not pre-selected and moved to the Trash, so Undo (or `z` in the terminal app) puts them back. Skipped while that IDE runs; automatic cleaning leaves them alone. User caches no longer touches `~/.cache/JetBrains` and Android Studio's caches.
- **Abandoned downloads** (System Junk, not pre-selected, both apps): unfinished downloads left at the top of your Downloads folder — Chrome's `.crdownload`, Firefox's `.part`, aria2's `.aria2` and qBittorrent's `.!qB` — untouched for 7 days. The empty file Firefox makes next to a `.part` and the data aria2 keeps next to a `.aria2` go along with it. A download still in progress is skipped; each one is listed on its own in the desktop app, and cleaning moves them to the Trash, so Undo (or `z` in the terminal app) puts them back. Automatic cleaning leaves them alone.
- **Developer Junk**: old runtime versions — every Node.js (nvm), SDKMAN (Java, Gradle, Maven…), Flutter (fvm), Python (pyenv), Ruby (rbenv) and Rust toolchain (rustup) version installed, and every Go SDK in `~/sdk`, that isn't your default, often hundreds of MB to a few GB each. Not pre-selected, each version on its own in the desktop app, deleted (install one again with the same tool). When a tool's default can't be read, all its versions are kept; a version a program is running from is skipped and the scan says which. Aliases, `current`, `default`, `version`, `settings.toml`, shims, `.nvmrc` files and pyenv versions holding virtualenvs are never touched, and automatic cleaning leaves the item alone.
- **Old screenshots** (System Junk, not pre-selected, both apps): screenshots and screen recordings (`Screenshot from …`, `Screencast from …`, KDE's `Screenshot_<date>…`) at the top of your Pictures folder or of Pictures/Screenshots that you haven't opened or changed for 90 days — the same *Old downloads* setting decides. Each file is listed on its own in the desktop app; cleaning moves them to the Trash, so Undo (or `z` in the terminal app) puts them back. Automatic cleaning leaves them alone.
- Desktop app, **Developer Junk**: unused Docker volumes and unused Docker images can be chosen one by one, like dangling images. Each volume shows its name, driver and size and whether it is anonymous or a named volume that may hold data; each image shows its name and tag, size and age. Nothing is pre-selected, and Clean removes only the ones you ticked (`docker volume rm`, `docker rmi`). The terminal app still cleans them all at once.
- **System Overview** (both apps): a read-only **System protection** group shows whether the firewall (ufw), AppArmor, automatic security updates (unattended-upgrades) and Secure Boot are on. One that is off says why and shows the command that turns it on, for you to run in a terminal (the desktop app has a button to copy it); CleanMate never changes these settings itself. When APT's settings can't be read, automatic security updates show *Unknown* rather than *Off*.
- **Developer Junk**: Android emulator system images no virtual device (AVD) uses — often several GB each, and they stay after you delete the AVD. Found in `~/Android/Sdk`, `ANDROID_HOME` and `ANDROID_SDK_ROOT`; not pre-selected, each image on its own in the desktop app, deleted for good, and skipped while Android Studio, the emulator, sdkmanager or avdmanager runs. If an AVD's settings can't be read, every image is kept. Platforms, build tools, the NDK, the emulator and your AVDs are never touched.
- Desktop app, **Smart Scan and the cleanup pages**: after a clean that moved items to the Trash (old installers, old downloads, stale build folders, editor data of deleted projects), the message offers **Undo** for 10 seconds and puts them back. The confirmation says whether the selection can be undone; everything else is still deleted for good.
- **Old downloads** (System Junk, not pre-selected, both apps): files and folders at the top of your Downloads folder that you haven't opened or changed for 90 days — a folder counts as used when anything inside it was. Each one is listed on its own in the desktop app and moved to the Trash, so you can put it back. Old installers, unfinished downloads, open files and *Never clean* folders are skipped. Change the 90 days in Settings › Old downloads.
- **Desktop app**: keyboard shortcuts — Ctrl+1…9 switch pages, Ctrl+R (or F5) scans, searches or lists again, Ctrl+? opens the shortcut list (also in the main menu). After a clean, the result shows *Free space: before → after*.
- **Uninstaller (desktop app)**: filter *Unused for 1/3/6/12+ months*. Apps without a last-used date show *Unknown*, stay hidden under the filter and come back with *Show*.
- **AI Models**: unfinished Ollama downloads (`sha256-…-partial`, also in the folder `OLLAMA_MODELS` points to). Not pre-selected and skipped while Ollama runs; complete models are kept.
- **Developer Junk**: the Dart and Flutter pub cache (`hosted`, `git/cache`, also `PUB_CACHE`). Not pre-selected, skipped while dart or flutter runs; your pub login and activated tools are kept.
- **AI Tools**: data VS Code, VS Code Insiders, VSCodium, Cursor and Windsurf keep for projects you deleted (`workspaceStorage`, also the Snap and Flatpak builds). Each project is listed on its own, not pre-selected, moved to the Trash, and skipped while the editor runs.

### Changed

- **AI Models**: LM Studio models in the folder you chose in LM Studio's My Models are listed too, and LM Studio models stay locked while its headless daemon (`llmster`) or the `lms` CLI runs.
- Desktop app, **Duplicates**: nothing is ticked after a search, and *Select automatically* now keeps the **oldest** copy of each group (usually the original), like the terminal app, instead of the newest.
- README and app store listing: screenshots of Space Lens, Duplicates, Startup Items and Settings.
- Desktop app, **Startup Items**: switching one of your systemd services or timers on or off now also starts or stops it right away, not only at the next login.

### Added

- Settings › **Never clean** (both apps): list folders in your home that CleanMate must never touch, such as a project you work on now and then or installers you keep. Large & Old Files, Duplicates, Space Lens, stale `node_modules` and project build folders and old installers skip them, and nothing in them is moved to the Trash. The desktop app adds them with a folder picker; your home folder itself, folders above it and symbolic links are refused.
- **Uninstaller**: *Leftovers of removed apps* lists folders no installed app uses any more — `~/.var/app` of removed Flatpak apps, `~/snap` of removed snaps, and folders in `~/.config`, `~/.local/share`, `~/.local/state` and `~/.cache` whose name matches nothing installed. Nothing is ticked; they go to the Trash, with Undo (`z` in the terminal app). In the terminal app it's the last row of the Uninstaller, in the desktop app a group at the end of the list.
- Desktop app, Settings › Your data: **Remember recent files** turns GNOME's recent-files list on or off (as in the terminal app), and **Activity log** shows what was cleaned and when, newest first, with a button to open the log folder.
- Desktop app, Settings › **Language**: run CleanMate in English or Tiếng Việt whatever your system's language is, or keep *Same as system*. A **Restart** button next to it reopens the app in the new language; the terminal app stays in English.
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

- Desktop app, **Uninstaller**: when one app stops the shared `apt-get purge` or `snap remove` of several apps, each app still installed is removed on its own in the same run (no second password), so only the app at fault shows an error — its own — and the others are uninstalled.
- Desktop app in Vietnamese: Smart Scan no longer mixes in English — the notes under each item ("3 files in /var/log", "skipped while running: …"), apps found on the computer, model descriptions and the lines of an item's details are translated too.
- Sizes no longer promise more than cleaning frees: with Docker 23 or newer the terminal app's *Docker: unused volumes* (and the desktop app's, when no volume is picked one by one) counts only anonymous volumes — the only ones `docker volume prune` removes — and says how many named volumes it keeps. Stale `node_modules` and project build folders no longer count files pnpm or Bun hard-linked from their store.
- Large & Old Files and Duplicates: files on a USB or other mounted drive (under `/media` or `/mnt`) now go to that drive's own Trash, so **Undo** in the notification (and `z` in the terminal app) puts them back.
- Undo (`z`) never replaces or moves into a file or folder that appeared where the trashed file used to be.
- Terminal app: key presses were sometimes ignored with bash older than 5.3 (Ubuntu 22.04 and 24.04), and keys typed while a screen was busy were printed over it.


### Cleaning

- **Smart Scan** — 50+ locations scanned in parallel in about a second; one checklist with sizes,
  remembered choices, and a confirm dialog that lists exactly what will be removed.
- **System Junk** — APT cache, unused packages, extra old kernels (a fallback always stays),
  leftover configs, old Snap revisions, old temp files.
- **Logs** — systemd journal, rotated and oversized live logs, crash reports, core dumps, old app logs.
- **User & App Junk** — Trash, thumbnails, stale caches, Steam's shader cache, and every browser
  and app cache as its own choice.
- **AI Tools** — caches, logs and old sessions of Claude Code, Claude Desktop, Codex,
  Gemini/Antigravity, opencode, Zed, Copilot CLI and Continue; memory and logins are never touched.
- **AI Models** — every downloaded Ollama, Hugging Face and LM Studio model on its own with its
  size; never pre-selected and never touched by automatic cleaning.
- **Developer Junk** — npm, Yarn, pnpm, Bun, pip, Conda, Go, Cargo, Gradle, Maven, idle
  `node_modules`, Docker and Podman images, build cache, containers and volumes as separate items.
- **Privacy** — shell, Recent files, REPL, Vim, Alt+F2 and emoji history.

### Tools

- Space Lens, Large & Old Files (virtual machine disks included), Duplicates (with **undo** via the
  Trash), Uninstaller (apt, Snap, Flatpak and leftovers; refuses removals that would take parts of
  Ubuntu), Startup Items, Maintenance (keep fewer snap versions, limit journal size), System
  Overview with free-space history and the space outside your folders.
- **Automatic cleaning** — daily/weekly/monthly systemd user timer; the notification reports what
  was freed and what's left to review; low-disk alert.

### Apps

- **Desktop app** (Ubuntu 24.04+) — GTK 4 + libadwaita; system items use the standard password dialog.
- **Terminal app** (`cm`) — keyboard and mouse, `/` find, `z` undo, `?` help, works from 60×20.
- **Command line** — `--scan`, `--clean [--yes]`, `--only`, `--dry-run`, `--auto`, `--json`.

### Install & updates

- PPA (`ppa:homielab/cleanmate`), `.deb` from GitHub Releases, snap, or the script with
  `--install`, `--update` and `--uninstall`.

[2.3.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.3.0
[2.2.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.2.0
[2.1.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.1.0
[2.0.0]: https://github.com/homielab/cleanmate-linux/releases/tag/v2.0.0
