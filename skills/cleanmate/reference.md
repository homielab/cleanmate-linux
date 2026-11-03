# CleanMate `cm` reference

## Plain output

| Command | Does |
| --- | --- |
| `cm --scan [--only LIST]` | print what Smart Scan finds, changes nothing |
| `cm --clean [--yes] [--only LIST]` | scan, then clean selected items; without a terminal `--yes` is required, running apps are skipped; with `--yes` items marked `data_loss` are skipped too |
| `--dry-run` / `-n` | with anything: delete nothing |
| `cm --check` | low-disk alert and scan reminder, cleans nothing |

`--only LIST`: comma-separated `system,logs,user,browser,apps,ai,models,dev,privacy`. `privacy` is only included when named.

## JSON (`cm --json CMD`)

One JSON object per line, ending with `{"event":"done"}`; failures are `{"event":"error","message":…}` with exit code 2.

- `items`: every item (`id`, `category`, `label`, `description`, `default`, `root`, `trash`, `data_loss`: deleted for good and may hold data — `docker_volumes`, `docker_containers`; cleaned only when named), and `why`: why it is safe to clean — `effect` (`regenerated`: deleted, its app or tool rebuilds it; `trash`: moved to the Trash; `delete`: deleted for good), `where` (its paths that exist, `~` for the home folder; all its paths when none exists), `where_note` (where it is, in words, for items without a fixed path), `after` (what cleaning does), `skipped` (when it is left alone, with the current settings), `running` (programs whose running makes it skip; set only for items that check), `folders` (its folders in your home folder: what Settings › Never clean takes). "What it is" is `description`.
- `scan [--only LIST]`: the same plus `status`, `bytes`, `note`, `selected`, `locked`, `entries` and `durationMs` (how long that item's scan took, whole milliseconds; items are scanned in parallel, so their times overlap); done line has `total_bytes`, `locations` and `durationMs` (the whole scan; `ms` is the same number).
- `details ID`: `lines` explaining the item; items that can be cleaned in parts also list `entry` events.
- `clean ID…` and `clean ID --entries E1,E2`: see SKILL.md. Honors `--dry-run`. As root only system items are allowed.
- `lens [--path DIR] [--limit N]`: one folder's files and folders, biggest first — `entry` has `path`, `bytes`, `kind` (`dir`/`file`), `count`, `movable` (false: excluded or outside the home folder / a writable drive — view only), `excluded`, `reason` (why it is view only: `packages`, `docker`, `journal`, `logs`, `snap`, `apt`, `user`, `mount`, `system`…; `""` when movable), `denied` (a folder you can't read), `unreadable` (folders inside du couldn't read). `kind` `mount` is another disk mounted there. Beyond a home folder the `done` line adds `drive` and whether that drive has its own Trash (`drive_trash`); `denied`, `unreadable`, and `disk_size` / `disk_used` when the path is a mount point. Never reads as root.
- `places`: where to start exploring — `place` events (`path`, `kind` `home`/`system`/`drive`, `size`, `used`, `avail`, `fstype`), then `done`.
- `large [--min BYTES] [--days N] [--path DIR] [--limit N]`: the biggest files (`file` events: `path`, `bytes`, `mtime`, `atime`, `kind`) — with `--days N` neither changed nor opened for N days.
- `dupes [--min BYTES] [--path DIR] [--limit N]`: `progress` events, then one `group` per set of identical files — `hash`, `bytes`, `files` (`path`, `mtime`, newest first). Hidden folders, `node_modules`, empty files and hard-link siblings are left out.
- `trash [--home-only] PATH…`: move confirmed paths to the Trash — one `task` per path (`state` `ok`/`fail`, `info` with the reason a move was refused, `trash` key for `restore`); refuses excluded or protected paths, and as root. Honors `--dry-run`.
- `restore KEY…`: put Trash items back (keys from the `trash` fields); refuses as root and files that have taken the original's place.
- `restore --list [--limit N] [--gone DAYS]`: what CleanMate moved to the Trash and is still there, newest first, at most 200 by default. One object instead of event lines: `{"version":"<app version>","count":N,"items":[{"trashed","path","size","kind","date","source","inTrash","location"}]}` — `trashed` is the key for `restore`, `size` in bytes, `kind` `file`/`folder`, `date` ISO 8601 with offset, `source` where it was moved from (`Command Line`, `Smart Scan › <item>`, `Large & Old Files`, `Duplicates`, `Space Lens`, `Uninstaller`, `Startup Items`), `location` the item's path in the Trash. `--gone DAYS` adds what it moved there in the last DAYS days that has left the Trash since (emptied or deleted) and is not back in its place: `inTrash` false, `size`/`kind`/`location` null — those can't be restored. Read only; refuses as root.
- `apps`, `uninstall`, `startup`, `maintenance`, `overview`: used by the desktop app; run `cm --help`.

## Safety

Cleaning only touches known cache, log and junk locations; nothing else is deleted. Browser profiles, documents and project sources are never touched. Every action is written to the activity log (`cm --help` shows its path).
