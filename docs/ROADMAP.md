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

- [x] **Desktop app: file tools** — Space Lens (drill-down list), Large & Old Files, Duplicates,
      each with an *Undo* toast that uses the engine's Trash code.
- [ ] **Desktop app: apps & system** — Uninstaller (done), Startup Items (done), Settings (done: automatic
      cleaning, updates, retention), Maintenance (done), System Overview with the free-space graph.
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
| `--json scan [--only LIST]` | `progress` (`done`, `total`, `current`) …, `item` (+ `status` found/clean/timeout, `bytes`, `note`, `selected`, `locked`: the running program that makes a clean skip the item, empty if none, `entries`: `details` lists parts to clean one by one) …, `done` (`ms`, `total_bytes`, `locations`) |
| `--json details ID` | `entry` (`item`, `id`, `bytes`, `label`, `selected`: ticked by default) … for items that can be cleaned part by part, then `details` (`id`, `lines`), `done`. Entries: `docker_dangling` = each dangling image (`id` sha256:…, ticked), `docker_build` = each build-cache record not in use (`id` BuildKit base-32, biggest first, at most 300, a shared record counts 0 bytes, not ticked); only for a Docker on this computer (unix socket) |
| `--json [--dry-run] clean ID…` | `task` (`id`, `state` run/ok/skip/fail — skip while the item's program runs, `info`, `freed`) …, `done` (`freed`, `avail_before`, `avail_after`) |
| `--json [--dry-run] clean ID --entries E1,E2…` | Same events; cleans only these entries of one item (`docker rmi ID` / `docker builder prune --force --filter id=ID`). Each ID must match the item's format (else `error`, exit 2, Docker isn't called) and be one `details` lists now (others are skipped; none left → `fail`). Dry run: `freed` = the entries' size |
| `--json large [--min BYTES] [--days N] [--path DIR]` | `file` (`path`, `bytes`, `mtime`, `atime`, `kind` video/audio/image/archive/package/disk/document/other) … biggest first, at most 500, `done` (`count` listed, `found` matched, `total_bytes` listed). Defaults: 100 MB, any age, your home folder; `--days` = neither changed nor opened for N days; skips `.cache`, `.git` and Trash folders and other file systems |
| `--json lens [--path DIR]` | `entry` (`path`, `bytes`, `kind` dir/file — a link is a file, `count` files and folders inside a folder or 1, `movable`: inside your home folder and not protected) … biggest first, at most 500, `done` (`path`, `bytes` and `items` of DIR, `count` listed, `found` entries). Measured like `du -x -b` (one file system), as you; default your home folder; skips names that aren't UTF-8 |
| `--json dupes [--min BYTES] [--path DIR]` | `progress` (`stage` list/compare/verify, `done`, `total`) …, `group` (`hash` MD5, `bytes` of one copy, `files` [{`path`, `mtime`}] newest first) … biggest files first, at most 500, `done` (`groups` listed, `found` groups, `files` listed, `total_bytes` freed by keeping one copy of each listed group). Same size → same MD5 of the first 64 KB → same full MD5, like the terminal app; defaults: 1 MB, your home folder; hard links count once; skips empty files, hidden folders, `node_modules`, other file systems and names that aren't UTF-8 |
| `--json [--dry-run] trash [--home-only] PATH…` | `task` (`id` = the path, `state` ok/fail, `info`, `freed`, `trash`: its name in your Trash, or for a file on a drive mounted under `/media/$USER`, `/run/media/$USER` or `/mnt` its path in that drive's own Trash (`<drive>/.Trash/<uid>/files/…` for an admin's sticky `.Trash`, else `<drive>/.Trash-<uid>/files/…`, made if missing; `Path=` relative to the drive); empty when it can't be put back — other places outside your home folder, a read-only drive or a dry run, which go through `gio trash`) …, `done` (`moved`, `failed`, `freed`). `--home-only` (Space Lens) fails what `lens` marks not `movable`. Refused as root |
| `--json [--dry-run] restore KEY…` | `task` (`id` = the original path, `state` ok/fail, `info`, `trash`) …, `done` (`restored`, `failed`). KEY is a `trash` value; a file is put back only inside your home folder, or on the drive whose Trash it is in (that Trash must be yours, not reached through a symlink), never over an existing file. Refused as root |
| `--json startup` | `unit` (`id` autostart:FILE.desktop or systemd:UNIT, `kind` autostart/systemd-user, `name`, `enabled`, `path`, `system`: comes with the system, `hidden`: a NoDisplay entry or the system's own service, `toggle`: can be switched here, `removable`, `description`, `command`) …, `done` (`count`, `systemd`: false when `systemctl --user` doesn't answer). Your `~/.config/autostart` and the system's entries (`/etc/xdg/autostart`); systemd user services and timers that are enabled or disabled — the system's own only when enabled, view only. Refused as root |
| `--json [--dry-run] startup-set ID enable\|disable\|remove` | `task` (`id`, `state` ok/fail, `info`, `trash`: name in your Trash after `remove`), `done`. Autostart: off = `Hidden=true` (a system entry gets your own copy, the system file is never changed), on = removes `Hidden=` and `X-GNOME-Autostart-enabled=false`; `remove` only your own entries (not a copy of a system one), to the Trash. systemd: `systemctl --user enable\|disable` for units in your `~/.config/systemd/user` or `~/.local/share/systemd/user`; `remove` (disable, Trash, daemon-reload) only in `~/.config/systemd/user`. Undo = `restore`. Refused as root |
| `--json settings` | `setting` (`key`, `value`; numbers also `min`, `max`, `default`) for `schedule` (`value` off/daily/weekly/monthly, `choices`, `default`: automatic cleaning, read from the systemd user timer), `update_check` (0/1), `low_disk_pct`, `journal_days`, `journal_mb`, `log_max_mb`, `app_log_days`, `tmp_days`, `cache_days`, `node_modules_days`, `ai_history_days`, then `selections` (`value` = number of remembered Smart Scan choices), `done` (`systemd`: `systemctl` exists, `packaged`: updates come from apt/snap). The terminal app's settings file `~/.config/cleanmate/settings`; a missing or out-of-range value reads as its default. Refused as root |
| `--json [--dry-run] settings-set KEY VALUE` | `task` (`id` = KEY, `state` ok/fail, `info`), `setting` (KEY as saved now), `done`. `schedule off\|daily\|weekly\|monthly` writes and enables (or disables and removes) `cleanmate.timer` at once; `selections reset` forgets remembered choices; a number must be within its range. Only that line of the settings file changes. A wrong key or value: `error`, exit 2. Refused as root |
| `--json apps` | `app` (`id` = KIND:PACKAGE, `kind` apt/snap/flatpak, `name`, `bytes` of the app, `data_bytes` of its folders, `last_used` epoch or 0, `desktop` launcher id, `leftovers` [{`path`, `bytes`}]: folders in your home only this app uses) …, `done` (`hidden`: parts of Ubuntu left out) |
| `--json uninstall --check ID…` | `check` (`ok`, `message` why not, `extra` number and `extra_text` of other packages apt would remove), `done` |
| `--json [--dry-run] uninstall ID…` | `task` (`id`, `state` run/ok/fail, `info`) …, `done` (`removed`, `failed`). Only IDs `apps` lists; apt removals that would take a part of Ubuntu are refused. apt and Snap need root (`pkexec`), Flatpak runs as you. Leftover folders: `trash` as you, after the app is gone |
| `--json maintenance` | `maint` (`id` update/repair/flatpak_unused/fstrim/free_ram/fonts/locate/snap_versions/journal_limit, `label`, `description`, `available`: its tool is installed, `reason` why not, `root`: has steps that need root, `user`: has steps run as you, `toggle`: a lasting limit switched on or off, `on`, `value` now — snap's `refresh.retain` or the journal limit in MB, empty if none — and `target`: what `on` sets) … the terminal app's nine Maintenance items in its order, `done` |
| `--json [--dry-run] maintain ID [on\|off] [--user-steps]` | per step `task` (`id` step, `label`, `state` run/ok/skip/fail, `info`) with its output as `log` (`line`) in between, `done` (`ok`, `failed`, `skipped`). `on`/`off` only and always for `snap_versions` and `journal_limit`. As root only the steps that need root run (a user-only item: `error`); as you every step runs (root steps via `sudo -n`) — `--user-steps` runs only yours, after the root part through `pkexec`. Unknown item, missing tool: `error`, exit 2 |
| any error | `error` (`message`), non-zero exit |
