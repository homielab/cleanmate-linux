# Roadmap

Where CleanMate is going, and the decisions behind it. Ideas and votes are welcome in
[issues](https://github.com/homielab/cleanmate-linux/issues).

## Done in 1.0

- [x] **Engine + terminal app** — Smart Scan over 50+ locations, cleanup sections, Space Lens,
      Large & Old Files, Duplicates, Uninstaller, Startup Items, Maintenance, System Overview,
      Settings, undo, automatic cleaning, updates.
- [x] **Engine protocol** — `cleanmate.sh --json items|scan|details|clean`, one JSON event per line.
- [x] **Desktop app core** — Smart Scan and the six cleanup sections, details, confirm dialog,
      live progress; system items through the standard password dialog (pkexec + polkit policy).
- [x] **Distribution** — app icon, *Show Apps* launcher, one-line install, `.deb` built by CI on
      every release, AppStream metainfo.

## Next

- [ ] **Desktop app: file tools** — Space Lens (drill-down list), Large & Old Files (done), Duplicates,
      each with an *Undo* toast that uses the engine's Trash code.
- [ ] **Desktop app: apps & system** — Uninstaller (done), Startup Items, Maintenance, System Overview with
      the free-space graph, and a Settings page (automatic cleaning, updates, retention).
- [x] **Launchpad PPA** — `ppa:homielab/clean-my-ubuntu`, uploaded by CI on every release (1.0.1).
- [ ] **Snap Store** — classic confinement was declined for now (project too new); ask again once
      the project has a track record.
- [ ] **Translations** — the desktop app is in English and Vietnamese (`po/`); the engine and the terminal app are English only.

Until the desktop app has every tool, its *All tools (terminal)* entry opens `cm`.

## Design decisions

| Topic | Decision | Why |
|---|---|---|
| Engine | One Bash script (`cleanmate.sh`) | Runs everywhere with nothing to install; the terminal app, the desktop app and the timer share every rule and test |
| Desktop app | Python 3 + PyGObject, GTK 4 + libadwaita 1.5 | Preinstalled on Ubuntu 24.04; native GNOME look, dark mode and accent colours for free |
| GUI ↔ engine | JSON lines over a pipe | The GUI never decides what to delete; the engine can be rewritten later without touching the GUI |
| Privileges | GUI runs as you; system items via `pkexec` | Standard password dialog; as root the engine refuses anything in a home folder |
| Older Ubuntu | 22.04 gets the terminal app only | It ships libadwaita 1.1 (no split view, dialogs, toasts) |
| Packaging | `.deb` first, then a PPA | Flathub doesn't accept host system utilities; Snap needs classic confinement |

## Engine protocol

Every line on stdout is one JSON object with an `"event"` field; sizes are bytes.

| Command | Events |
|---|---|
| `--json items` | `item` (`id`, `category`, `label`, `description`, `default`, `root`) …, `done` |
| `--json scan [--only LIST]` | `progress` (`done`, `total`, `current`) …, `item` (+ `status` found/clean/timeout, `bytes`, `note`, `selected`, `locked`: the running program that makes a clean skip the item, empty if none) …, `done` (`ms`, `total_bytes`, `locations`) |
| `--json details ID` | `details` (`id`, `lines`), `done` |
| `--json [--dry-run] clean ID…` | `task` (`id`, `state` run/ok/skip/fail — skip while the item's program runs, `info`, `freed`) …, `done` (`freed`, `avail_before`, `avail_after`) |
| `--json large [--min BYTES] [--days N] [--path DIR]` | `file` (`path`, `bytes`, `mtime`, `atime`, `kind` video/audio/image/archive/package/disk/document/other) … biggest first, at most 500, `done` (`count` listed, `found` matched, `total_bytes` listed). Defaults: 100 MB, any age, your home folder; `--days` = neither changed nor opened for N days; skips `.cache`, `.git` and Trash folders and other file systems |
| `--json [--dry-run] trash PATH…` | `task` (`id` = the path, `state` ok/fail, `info`, `freed`, `trash`: its name in your Trash, empty when it can't be put back — outside your home folder or a dry run) …, `done` (`moved`, `failed`, `freed`). Refused as root |
| `--json [--dry-run] restore NAME…` | `task` (`id` = the original path, `state` ok/fail, `info`, `trash`) …, `done` (`restored`, `failed`). NAME is a `trash` value; only files that came from your home folder are put back, never over an existing file. Refused as root |
| `--json apps` | `app` (`id` = KIND:PACKAGE, `kind` apt/snap/flatpak, `name`, `bytes` of the app, `data_bytes` of its folders, `last_used` epoch or 0, `desktop` launcher id, `leftovers` [{`path`, `bytes`}]: folders in your home only this app uses) …, `done` (`hidden`: parts of Ubuntu left out) |
| `--json uninstall --check ID…` | `check` (`ok`, `message` why not, `extra` number and `extra_text` of other packages apt would remove), `done` |
| `--json [--dry-run] uninstall ID…` | `task` (`id`, `state` run/ok/fail, `info`) …, `done` (`removed`, `failed`). Only IDs `apps` lists; apt removals that would take a part of Ubuntu are refused. apt and Snap need root (`pkexec`), Flatpak runs as you. Leftover folders: `trash` as you, after the app is gone |
| any error | `error` (`message`), non-zero exit |
