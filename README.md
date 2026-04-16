# Downloads Organizer

Small macOS menu bar utility that keeps `~/Downloads` organized and exposes a lightweight recent-files popover.

## What It Does

- Sorts new files in `~/Downloads` into stable folders such as `_PDF`, `_Images`, `_CSV`, and `_Docs/...`
- Shows recent files from Downloads in a compact menu bar popover
- Supports dragging files out of the popover into Finder, Mail, Slack, and other apps
- Keeps path-copy actions on right click instead of cluttering the main UI

## Repo Layout

- `app/DownloadsOrganizer.swift`: app source
- `scripts/build_app.sh`: builds a signed `.app` bundle in `~/Applications`
- `scripts/install_launch_agent.sh`: installs a login LaunchAgent for the app
- `scripts/uninstall_launch_agent.sh`: removes the LaunchAgent cleanly

## Build

```bash
./scripts/build_app.sh
```

Optional overrides:

```bash
APP_NAME=DownloadsOrganizer \
BUNDLE_ID=io.github.downloadsorganizer \
APP_PATH="$HOME/Applications/DownloadsOrganizer.app" \
./scripts/build_app.sh
```

## Install At Login

```bash
./scripts/install_launch_agent.sh
```

Optional overrides:

```bash
APP_NAME=DownloadsOrganizer \
APP_PATH="$HOME/Applications/DownloadsOrganizer.app" \
LAUNCH_AGENT_LABEL=io.github.downloadsorganizer \
./scripts/install_launch_agent.sh
```

## Remove Launch Agent

```bash
./scripts/uninstall_launch_agent.sh
```

## Notes

- The app is menu-bar-only by design.
- The organizer intentionally skips regular folders in the Downloads root; it organizes files and `.app` bundles.
- If macOS blocks Downloads access, grant the built app Full Disk Access and restart it.
