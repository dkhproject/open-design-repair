# Open Design Repair

A cross-platform maintenance tool for the **[Open Design](https://github.com/nexu-io/open-design)** desktop app. Diagnoses and fixes common problems — projects or sessions that won't delete, deleted items reappearing, stuck runs, orphaned/corrupted data — and can reset the app to a factory-fresh state.

> **Unofficial community tool.** Not affiliated with or endorsed by the Open Design authors. It only touches app *data* (database, caches, local state), never the app binaries. Use at your own risk; automatic backups are taken before any destructive action.

---

## Why you might need this

- **"Delete does nothing" / deleted projects keep coming back.** The app's renderer keeps stale copies of deleted projects in its HTTP cache and Local Storage and restores them as ghosts. The database delete actually worked — the UI state is what's stale. `fix` / `clear-ui-state` clears it.
- **A project is stuck or half-deleted.** If a project's folder was removed outside the app (e.g. by an agent run), its database row becomes an orphan. `doctor` flags it; `fix` prunes it.
- **You want a clean slate.** `factory-reset` wipes all app data so the next launch behaves like a first run — useful before reinstalling or handing off a machine.
- **Leftover data after uninstall.** `backup`, `restore`, `list-backups` and `factory-reset` work even when the app itself is no longer installed.

---

## Why a session "won't delete" in the app

This is the most common confusion, and it is **intended app behavior, not a bug**:

The Open Design UI keeps **at least one conversation per project**. When you delete the *only* session in a project, the UI immediately creates a new empty conversation to replace it. So the session appears to "come back" or the Delete button seems to do nothing. (The server-side delete actually succeeds — the UI just re-creates a session right after.)

This tool's `delete-session` removes the conversation directly in the database and does **not** create a replacement, so the session is genuinely gone.

To remove a project *and* all its sessions with no replacement, use `delete-project`.

---

## Requirements

| Platform | Requirement |
|----------|-------------|
| **Windows** | PowerShell 5.1+ **or** Node.js 22+ |
| **macOS** | Node.js 22+ |
| **Linux** | Node.js 22+ |

**No Python or other runtime needed.** The database helper uses the app's own SQLite environment:
- Windows: runs inside the app's bundled Electron (`ELECTRON_RUN_AS_NODE=1`) with `better-sqlite3`
- macOS/Linux: system Node + `better-sqlite3` (install via `npm install better-sqlite3`)

---

## Install

### Option 1: npm (recommended)
```bash
npm install -g open-design-repair
# or from source:
npm install -g .
```

### Option 2: Direct download
Download the repo as ZIP and extract, or:
```bash
git clone https://github.com/dkhproject/open-design-repair.git
cd open-design-repair
```

### Option 3: Windows PowerShell (original)
Use `OpenDesignRepair.ps1` directly on Windows:
```powershell
.\OpenDesignRepair.ps1 doctor
```
If scripts are blocked, use the `.cmd` launcher or:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\OpenDesignRepair.ps1 doctor
```

---

## Quick start

### Cross-platform (Node.js)
```bash
od-repair doctor          # diagnose (read-only, safe)
od-repair fix             # repair detected problems
od-repair factory-reset   # wipe all app data, start fresh
```

### Windows PowerShell
```powershell
# Double-click OpenDesignRepair.cmd for menu
.\OpenDesignRepair.ps1 doctor
.\OpenDesignRepair.ps1 fix
```

---

## Commands

| Command | What it does |
|---|---|
| `doctor` | Read-only diagnosis: DB integrity, orphan projects (row without folder / folder without row), stuck or stale runs, orphaned artifact blobs, **ghost project references** in UI cache/local storage. |
| `fix` | Stops the app → backs up → prunes orphaned data → clears renderer caches and stale UI state → vacuums the DB → verifies. |
| `clear-ui-state` | Clears only the renderer cache + Local/Session Storage. The targeted fix for *"Delete does nothing"*. Projects in the database are untouched. |
| `delete-project` | Force-deletes one project completely: DB rows (conversations/messages/tabs cascade), its folder, and its run history. Use `--id <uuid>` or `--name "exact name"`. |
| `delete-session` | Deletes one conversation/session (messages and related rows cascade, plus its runs and task inputs). **Does not** auto-create a replacement (see below). |
| `backup` | Snapshot `data` + `user-data` into the backup folder. |
| `restore` | Restore the newest backup, or a specific one via `--backup-path`. Takes a safety backup of the current state first. |
| `list-backups` | List available backups and sizes. |
| `factory-reset` | Deletes **all** app data and local state (database, projects, caches, logs, updates). App stays installed; next launch is a first run. Requires typing `RESET`. |
| `uninstall` | Runs the app's official uninstaller; optionally wipes app data too. |
| `version` | Print tool version and detected app/data locations. |

### Flags

| Flag | Effect |
|---|---|
| `--dry-run` | Show what would happen; change nothing. |
| `--yes` | Skip confirmation prompts (for scripting). |
| `--no-backup` | Skip the automatic backup (not recommended). |
| `--app-path <dir>` | Override the install location if auto-detection fails. |
| `--namespace <name>` | Target a specific app namespace (default: most recently used). |
| `--start-after` | Relaunch the app when the command finishes. |

### Examples

```bash
od-repair doctor
od-repair fix --dry-run
od-repair delete-project --id 99c6942b-e053-4323-a990-456d89102a51
od-repair delete-project --name "My Project"
od-repair delete-session --id 17a18cfd-159f-4412-86cc-3447e78861aa
od-repair factory-reset --start-after
od-repair restore --backup-path "C:\Users\me\AppData\Roaming\Open Design\od-repair-backups\release-stable-win\20261123-185526-manual"
```

---

## Safety model

- Every destructive command **stops the app first**, then **backs up** `data` + `user-data` before changing anything (unless `--no-backup`).
- Destructive commands ask for confirmation; `factory-reset` requires typing `RESET`.
- `doctor`, `version`, and anything with `--dry-run` never modify data.
- Backups live in:
  - Windows: `%APPDATA%\Open Design\od-repair-backups\<namespace>\`
  - macOS: `~/Library/Application Support/Open Design/od-repair-backups/`
  - Linux: `~/.config/Open Design/od-repair-backups/`
- Backups are **never** touched by `factory-reset`, so you can always restore.

---

## How it works

- **Discovery:** auto-detects the install (`%LOCALAPPDATA%\Programs\Open Design`, `Program Files`, or registry on Windows; `/Applications` on macOS; `/opt` on Linux) and the data root (`%APPDATA%\Open Design\namespaces\*` on Windows; `~/Library/Application Support/Open Design/namespaces` on macOS; `~/.config/Open Design/namespaces` on Linux). Override with `--app-path` / `--namespace`.
- **Database access:** `lib/od-data.mjs` runs inside the app's Electron binary on Windows (using bundled `better-sqlite3`), or under system Node with `better-sqlite3` on macOS/Linux. It checks tables/columns before querying, so it degrades gracefully across app versions.
- **Ghost detection:** scans renderer state directories (Cache, Local/Session Storage, IndexedDB, …) for project UUIDs that no longer exist in the database.
- **Repair:** prunes orphan rows/folders/runs/blobs, clears stale renderer state, and `VACUUM`s the database.

---

## Compatibility

Tested against Open Design **0.27.2** on Windows 11. The helper is defensive about schema differences, but other versions may store data differently — run `doctor` first and review its report before `fix`.

---

## Troubleshooting

- **"Open Design installation not found"** — pass `--app-path "/path/to/Open Design"`.
- **"No Open Design data found"** — the app has never been opened, or use `--namespace <name>`.
- **Helper errors / no output** — ensure the app is fully closed; re-run. Include the `doctor` output when reporting issues.
- **Deleted items still reappear after `fix`** — close the app completely and run `clear-ui-state` again.

---

## Contributing

Issues and PRs welcome. Please include your Open Design version, Windows version, and the `doctor` output (redact project names if needed).

---

## License

[MIT](LICENSE)