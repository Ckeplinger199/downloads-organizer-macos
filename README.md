# Downloads Organizer

Small macOS menu bar file viewer for recent items in `~/Downloads`, plus screenshots from macOS's configured screenshot save location, with light background sorting to keep common file types in stable folders.

## What It Does

- Shows recent files from Downloads and recent screenshots in a compact menu bar popover
- Filters the recent-files list with a search box at the top of the popover
- Supports dragging files out of the popover into Finder, Mail, Slack, and other apps
- Keeps path-copy actions on right click instead of cluttering the main UI
- Opens the Downloads folder from the popover
- In the background, sorts new files in `~/Downloads` into stable folders such as `_PDF`, `_Images`, `_CSV`, and `_Docs/...`
- Writes a machine-readable move index so helper tools can resolve the final path for an organized download

## Repo Layout

- `app/DownloadsOrganizer.swift`: app source
- `scripts/build_app.sh`: builds a signed `.app` bundle in `~/Applications`
- `scripts/install_launch_agent.sh`: installs a login LaunchAgent for the app
- `scripts/resolve_download.sh`: resolves an original downloaded filename to its organized path
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

## Resolve Organized Downloads

The app writes move records to:

```text
~/Library/Application Support/DownloadsOrganizer/move-index.tsv
```

Resolve a moved file by its original downloaded name:

```bash
./scripts/resolve_download.sh "example.pdf"
```

## Notes

- The app is menu-bar-only by design.
- The background sorter intentionally skips regular folders in the Downloads root; it only organizes files and `.app` bundles.
- If macOS blocks Downloads access, grant the built app Full Disk Access and restart it.
