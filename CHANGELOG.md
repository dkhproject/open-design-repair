# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-24

### Added
- **OpenDesignRepair** — maintenance tool for Open Design desktop app
  - `doctor`: read-only diagnosis of database integrity, orphan projects/folders, stuck runs, orphaned artifact blobs, ghost project references in renderer cache/local storage
  - `fix`: safe repair — stop app, back up, prune orphaned data, clear stale UI state, vacuum database, verify
  - `clear-ui-state`: targeted fix for "Delete does nothing" / deleted items reappearing
  - `delete-project`: force-delete a project by ID or exact name (DB rows cascade, folder, run history)
  - `delete-session`: delete a conversation/session (messages and related rows cascade, plus runs and task inputs) — **does not auto-create a replacement**
  - `backup` / `restore` / `list-backups`: safety net stored under platform-appropriate config directory
  - `factory-reset`: wipe all app data for a first-run state (requires typing `RESET`)
  - `uninstall`: launch the official uninstaller, optionally wiping data
  - `version`: print tool version and detected app/data locations
  - Interactive menu with numbered pickers (no UUID typing needed)

- **Cross-platform support** — runs on Windows, macOS, and Linux
  - `od-repair.mjs` — cross-platform CLI (uses Electron on Windows, system Node + better-sqlite3 on macOS/Linux)
  - Auto-detection of install/data paths per platform
  - npm package with `bin` entry: `npm install -g .` → `od-repair`

- **Windows PowerShell version** — original `.ps1` script with `.cmd` launcher

### Notes
- Root cause for "Delete does nothing" confirmed: Open Design UI auto-creates a replacement session when the last conversation is deleted. `delete-session` bypasses this.
- Database helper is defensive about schema drift across app versions.
- Data-only commands (`backup`/`restore`/`list-backups`/`factory-reset`) work even after the app is uninstalled.
- Tested against Open Design 0.27.2 on Windows 11.