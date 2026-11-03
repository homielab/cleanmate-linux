# CleanMate on Flathub

`com.homielab.CleanMate.yml` builds the desktop app (GTK 4 + libadwaita, GNOME 51 runtime) and its
engine (`cleanmate.sh`, also `cleanmate` and `cm` inside the sandbox) from a release tag.

## Build it locally

```bash
sudo apt install flatpak flatpak-builder
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
packaging/flathub/build.sh            # builds this working tree and installs it for your user
flatpak run com.homielab.CleanMate --gui
flatpak run com.homielab.CleanMate --scan   # the engine, in the sandbox
```

`build.sh` copies the manifest to `dist/flatpak/` with this folder as the source, so you test your
changes, not the last tag. Remove it with `flatpak uninstall --user com.homielab.CleanMate`.

## Lint

Flathub runs the same checks on every pull request:

```bash
flatpak install --user flathub org.flatpak.Builder
flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest packaging/flathub/com.homielab.CleanMate.yml
flatpak run --command=flatpak-builder-lint org.flatpak.Builder appstream data/com.homielab.CleanMate.metainfo.xml
```

Without Flatpak, use the linter image:
`docker run --rm -v "$PWD:/src" -w /src ghcr.io/flathub-infra/flatpak-builder-lint:latest appstream data/com.homielab.CleanMate.metainfo.xml`.
CI (`.github/workflows/flatpak.yml`) lints both files and builds, installs and runs the Flatpak on
every push.

## Permissions

| Permission | Why |
|---|---|
| `--filesystem=home` | Everything the Flatpak cleans is in your home folder: caches, app logs, the Trash, developer and AI tool leftovers, and the files Space Lens, Large & Old Files and Duplicates show. |
| `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc`, `--device=dri` | The window. |

No network (the update check is off: Flathub updates the app), no D-Bus names, no host file system
and no `org.freedesktop.Flatpak` (running commands on the host would need a Flathub exception and
would make the sandbox pointless).

## What the Flatpak can't do

The sandbox has no root, no view of the host's processes and none of the host's system folders.
The app says so instead of failing, and the full `.deb` version (PPA or Releases) does all of it.

- **Left out** (not listed, not scanned): everything that needs your password — the apt and
  PackageKit caches, unused packages, leftover configs, the systemd journal, old and oversized logs
  in `/var/log`, crash reports and core dumps, old Snap revisions, old kernels — and items that need
  the host: `/tmp`, the Trash on other drives, Docker and Podman, GNOME settings history
  (gsettings), Zeitgeist activity, and the Tracker and Baloo search indexes.
  System Junk and Logs show a banner with a link to this section.
- **Pages left out:** Uninstaller, Startup Items and Maintenance (they run `apt`, `snap`,
  `flatpak`, `systemctl` on the host), and *Open in Terminal*. The same tools in `cm` are left out
  of its menu, and their `--json` commands answer *Not available in the Flatpak*. System Overview shows only your home
  folder's disk and leaves out the system protection checks and the system folders.
- **Programs can't be seen:** the sandbox has its own process list, so CleanMate can't tell whether
  the program behind an item (a browser, an editor, Steam, an AI tool) is open. Those items are not
  pre-selected, the scan says *close it first: the Flatpak can't see if it's open*, and the
  unattended clean (`--clean --yes`, `--auto`) skips them. Select one in the app after closing the
  program.
- **No schedule and no reminders:** automatic cleaning and scan reminders use systemd user timers
  on the host.

The manifest installs the metainfo without the screenshots marked `<!-- not in the Flatpak` in
`data/com.homielab.CleanMate.metainfo.xml` (Uninstaller, Startup Items), so Flathub shows only pages
the Flatpak has. Mark a new screenshot of a hidden page the same way.

## Submit to Flathub

Do it after a release that includes the Flatpak support (the tag the manifest names must contain
`/.flatpak-info` detection; v2.3.0 doesn't).

1. Set `tag` and `commit` in `com.homielab.CleanMate.yml` to the new release
   (`git rev-parse vX.Y.Z^{commit}`), build and lint it as above, commit.
2. Fork [flathub/flathub](https://github.com/flathub/flathub) and branch from `new-pr`
   (`git clone --branch new-pr …`).
3. Add `com.homielab.CleanMate.yml` at the top of the fork, commit, and open a pull request
   against `new-pr` titled `Add com.homielab.CleanMate`.
4. Answer the reviewers; the bot builds it (`bot, build`). Once merged, Flathub creates
   `flathub/com.homielab.CleanMate` and you get write access to it.
5. Verify the app ID's domain (`homielab.com`) on Flathub to get the verified checkmark.

After that, the Flathub bot reads `x-checker-data` and opens a pull request in
`flathub/com.homielab.CleanMate` for each new `vX.Y.Z` tag; merge it after the build passes. Keep
this file's manifest in step with that repo.
