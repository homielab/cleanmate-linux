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

- `items`: every item (`id`, `category`, `label`, `description`, `default`, `root`, `trash`, `data_loss`: deleted for good and may hold data — `docker_volumes`, `docker_containers`; cleaned only when named).
- `scan [--only LIST]`: the same plus `status`, `bytes`, `note`, `selected`, `locked`, `entries`; done line has `total_bytes`, `locations`, `ms`.
- `details ID`: `lines` explaining the item; items that can be cleaned in parts also list `entry` events.
- `clean ID…` and `clean ID --entries E1,E2`: see SKILL.md. Honors `--dry-run`. As root only system items are allowed.
- `restore KEY…`: put Trash items back. `trash PATH…`: move paths to the Trash.
- `large`, `lens`, `dupes`, `apps`, `uninstall`, `startup`, `maintenance`, `overview`: used by the desktop app; run `cm --help`.

## Safety

Cleaning only touches known cache, log and junk locations; nothing else is deleted. Browser profiles, documents and project sources are never touched. Every action is written to the activity log (`cm --help` shows its path).
