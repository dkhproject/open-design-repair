<#
.SYNOPSIS
  OpenDesignRepair - diagnose, repair, reset and fully wipe Open Design app data.

.DESCRIPTION
  An unofficial community maintenance tool for the Open Design desktop app on
  Windows. It never modifies the app binaries; it operates on the app's data,
  renderer cache and local state, and can restore the app to a first-run
  (factory) state.

  Install location and data directories are auto-detected, so it works on any
  machine. No Node.js or other dependencies are required: the database helper
  runs inside the app's own bundled Electron runtime.

  All destructive actions create a backup first (unless -NoBackup) and ask for
  confirmation (unless -Yes or -DryRun). Backup/restore/list-backups/version
  work even if the app itself has been uninstalled.

.PARAMETER Command
  doctor            Show install paths, DB health, orphan projects, stuck runs,
                    and stale UI-state references ("ghost" projects).
  fix               Safe repair: prune orphaned data, clear caches/UI state,
                    vacuum the database, then verify.
  clear-ui-state    Clear renderer cache + Local/Session Storage only.
                    (Usually fixes "Delete does nothing" / deleted items reappearing.)
  delete-project    Delete one project by -ProjectId or -ProjectName.
  delete-session    Delete one conversation/session by -SessionId, or by
                    -ProjectId/-ProjectName + -SessionTitle. Unlike the app UI,
                    this does not auto-create a replacement session.
  backup            Snapshot data + user-data into the backup folder.
  restore           Restore the newest backup (or -BackupPath).
  list-backups      List available backups.
  factory-reset     Delete all app data and local state -> app starts as new.
  uninstall         Launch the app's uninstaller (optionally wipes data too).
  version           Print tool version and detected app/data locations.

.PARAMETER ProjectId
  Project UUID for delete-project.

.PARAMETER ProjectName
  Exact project name for delete-project.

.PARAMETER SessionId
  Conversation UUID for delete-session.

.PARAMETER SessionTitle
  Exact conversation title for delete-session (used with -ProjectId/-ProjectName).

.PARAMETER BackupPath
  Specific backup folder to restore from.

.PARAMETER Namespace
  Target a specific app namespace (default: most recently used).

.PARAMETER AppPath
  Override the install directory if auto-detection fails.

.PARAMETER Yes
  Skip confirmation prompts (for scripting).

.PARAMETER DryRun
  Show what would happen without changing anything.

.PARAMETER NoBackup
  Skip the automatic backup before destructive actions (not recommended).

.PARAMETER KeepAppDataOnUninstall
  With uninstall: do not offer to wipe app data.

.PARAMETER StartAfter
  Relaunch the app when the command finishes.

.EXAMPLE
  .\OpenDesignRepair.ps1 doctor

.EXAMPLE
  .\OpenDesignRepair.ps1 fix

.EXAMPLE
  .\OpenDesignRepair.ps1 delete-project -ProjectName "My Project"

.EXAMPLE
  .\OpenDesignRepair.ps1 delete-session -ProjectName "My Project" -SessionTitle "Chat"

.EXAMPLE
  .\OpenDesignRepair.ps1 factory-reset

.NOTES
  Unofficial tool; not affiliated with the Open Design authors. Use at your own
  risk. Backups are written to %APPDATA%\Open Design\od-repair-backups.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('doctor', 'fix', 'clear-ui-state', 'delete-project', 'delete-session', 'backup', 'restore', 'list-backups', 'factory-reset', 'uninstall', 'version')]
  [string]$Command,

  [string]$ProjectId,
  [string]$ProjectName,
  [string]$SessionId,
  [string]$SessionTitle,
  [string]$BackupPath,
  [string]$Namespace,
  [string]$AppPath,

  [switch]$Yes,
  [switch]$DryRun,
  [switch]$NoBackup,
  [switch]$KeepAppDataOnUninstall,
  [switch]$StartAfter
)

$ErrorActionPreference = 'Stop'
$script:ToolVersion = '1.1.0'
$script:HelperPath = Join-Path $PSScriptRoot 'lib\od-data.mjs'
$script:BackupRootName = 'od-repair-backups'

# ---------------------------------------------------------------- output utils
function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "   [ok]   $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "   [warn] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "   [fail] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "   $Text" -ForegroundColor Gray }

function Wait-MenuPause {
  if ([Environment]::UserInteractive) { Read-Host "`nPress Enter to return to the menu" | Out-Null }
}

function Confirm-Action([string]$Question, [string]$TypedWord) {
  if ($Yes) { return $true }
  if ($DryRun) { return $true }
  if ($TypedWord) {
    $answer = Read-Host "$Question`nType '$TypedWord' to continue"
    return ($answer -eq $TypedWord)
  }
  $answer = Read-Host "$Question [y/N]"
  return ($answer -match '^(y|yes)$')
}

function Format-Bytes([double]$Bytes) {
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
  return ('{0:N0} B' -f $Bytes)
}

function Get-DirSize([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum
  if ($null -eq $sum) { return 0 }
  return [double]$sum
}

# ------------------------------------------------------------- discovery layer
function Get-AppVersionFromPackage([string]$Dir) {
  $pkg = Join-Path $Dir 'resources\app\package.json'
  if (Test-Path -LiteralPath $pkg) {
    try { return (Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
  }
  return $null
}

function Get-AppInstall {
  $candidates = @()
  if ($AppPath) { $candidates += $AppPath }
  $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Open Design')
  $candidates += 'C:\Program Files\Open Design'
  $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Open Design')

  foreach ($dir in $candidates) {
    if (-not $dir) { continue }
    $exe = Join-Path $dir 'Open Design.exe'
    if (Test-Path -LiteralPath $exe) {
      $configPath = Join-Path $dir 'resources\open-design-config.json'
      $config = $null
      if (Test-Path -LiteralPath $configPath) {
        try { $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
      }
      $version = if ($config -and $config.appVersion) { $config.appVersion } else { $null }
      if (-not $version) { $version = Get-AppVersionFromPackage $dir }
      return [pscustomobject]@{
        Dir     = (Resolve-Path -LiteralPath $dir).Path
        Exe     = (Resolve-Path -LiteralPath $exe).Path
        AppRoot = (Join-Path (Resolve-Path -LiteralPath $dir).Path 'resources\app')
        Version = $version
        Config  = $config
      }
    }
  }

  # Registry fallback (per-user and per-machine installs).
  $keys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($key in $keys) {
    $entry = Get-ItemProperty $key -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -match '^Open Design' } | Select-Object -First 1
    if ($entry -and $entry.InstallLocation) {
      $exe = Join-Path $entry.InstallLocation 'Open Design.exe'
      if (Test-Path -LiteralPath $exe) {
        $version = $entry.DisplayVersion
        if (-not $version) { $version = Get-AppVersionFromPackage $entry.InstallLocation }
        return [pscustomobject]@{
          Dir     = $entry.InstallLocation
          Exe     = $exe
          AppRoot = (Join-Path $entry.InstallLocation 'resources\app')
          Version = $version
          Config  = $null
        }
      }
    }
  }
  return $null
}

function Get-RootCandidates {
  $roots = @()
  $namespacesPath = Join-Path $env:APPDATA 'Open Design\namespaces'
  if (Test-Path -LiteralPath $namespacesPath) {
    foreach ($dir in Get-ChildItem -LiteralPath $namespacesPath -Directory -ErrorAction SilentlyContinue) {
      if ($Namespace -and $dir.Name -ne $Namespace) { continue }
      $data = Join-Path $dir.FullName 'data'
      $db = Join-Path $data 'app.sqlite'
      $roots += [pscustomobject]@{
        Name       = $dir.Name
        Path       = $dir.FullName
        Data       = $data
        UserData   = (Join-Path $dir.FullName 'user-data')
        Logs       = (Join-Path $dir.FullName 'logs')
        Updates    = (Join-Path $dir.FullName 'updates')
        HasDb      = (Test-Path -LiteralPath $db)
        LastWrite  = if (Test-Path -LiteralPath $db) { (Get-Item -LiteralPath $db).LastWriteTime } else { [datetime]::MinValue }
      }
    }
  }
  $roots | Sort-Object -Property LastWrite -Descending
}

function Get-PrimaryRoot {
  $roots = @(Get-RootCandidates)
  if ($roots.Count -eq 0) {
    throw "No Open Design data found under `"$env:APPDATA\Open Design\namespaces`". Has the app been opened at least once? (Use -Namespace to target a specific one.)"
  }
  $withDb = $roots | Where-Object { $_.HasDb } | Select-Object -First 1
  if ($withDb) { return $withDb }
  return $roots[0]
}

function Get-OdProcesses([string]$ExePath) {
  if (-not $ExePath) { return @() }
  Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -and ($_.Path -ieq $ExePath) } catch { $false }
  }
}

function Stop-OdApp([string]$ExePath) {
  if (-not $ExePath) {
    Write-Warn 'App executable not found; make sure Open Design is closed before continuing.'
    return
  }
  $procs = @(Get-OdProcesses $ExePath)
  if ($procs.Count -eq 0) {
    Write-Ok 'Open Design is not running.'
    return
  }
  Write-Info ("Stopping {0} process(es)..." -f $procs.Count)
  $procs | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { } }
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 300
    if (@(Get-OdProcesses $ExePath).Count -eq 0) { break }
  }
  if (@(Get-OdProcesses $ExePath).Count -gt 0) {
    Write-Warn 'Some Open Design processes did not exit. Close them manually, then re-run.'
  } else {
    Write-Ok 'Open Design stopped.'
  }
}

function Start-OdApp($Install) {
  if (-not $Install) { Write-Warn 'App not found; cannot relaunch.'; return }
  Write-Info 'Starting Open Design...'
  Start-Process -FilePath $Install.Exe | Out-Null
  Write-Ok 'Launched.'
}

# ------------------------------------------------------------------ DB helper
function Invoke-OdHelper {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [Parameter(Mandatory)]$Install,
    [Parameter(Mandatory)]$Root
  )
  if (-not (Test-Path -LiteralPath $script:HelperPath)) {
    throw "Helper script missing: $($script:HelperPath)"
  }
  $previous = $env:ELECTRON_RUN_AS_NODE
  $env:ELECTRON_RUN_AS_NODE = '1'
  $outFile = [IO.Path]::GetTempFileName()
  $errFile = [IO.Path]::GetTempFileName()
  try {
    # The app is a GUI-subsystem executable: PowerShell cannot capture its
    # stdout through a pipeline, so redirect to files and wait explicitly.
    $quoted = @($script:HelperPath) + $Arguments + @('--app', $Install.AppRoot, '--data', $Root.Data)
    $argLine = ($quoted | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' }) -join ' '
    $proc = Start-Process -FilePath $Install.Exe -ArgumentList $argLine -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $text = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    $text = if ($null -eq $text) { '' } else { $text.Trim() }
    # Tolerate stray non-JSON lines: keep the outermost JSON object only.
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) { $text = $text.Substring($start, $end - $start + 1) }
    if (-not $text) {
      $errText = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
      if ($errText) { throw "Helper produced no output (exit $($proc.ExitCode)): $($errText.Trim())" }
      throw "Helper produced no output (exit $($proc.ExitCode))."
    }
    return $text | ConvertFrom-Json
  } finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    if ($null -eq $previous) { Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
    else { $env:ELECTRON_RUN_AS_NODE = $previous }
  }
}

# --------------------------------------------------------------- ghost finder
function Find-UiStateGhosts($Root, $KnownProjectIds) {
  $sessionDir = Join-Path $Root.UserData 'session'
  if (-not (Test-Path -LiteralPath $sessionDir)) {
    return [pscustomobject]@{ Scanned = 0; GhostIds = @() }
  }
  $latin1 = [System.Text.Encoding]::GetEncoding(28591)
  $uuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  $patterns = @(
    "project:($uuid)",
    ('"projectId"\s*:\s*"(' + $uuid + ')"'),
    "project-tabs:v1:($uuid)"
  )
  $known = @{}
  foreach ($id in $KnownProjectIds) { $known[$id.ToLowerInvariant()] = $true }

  # Only scan directories that hold web/renderer state (fast, fewer false hits).
  $stateDirs = @('Cache', 'Code Cache', 'Local Storage', 'Session Storage', 'IndexedDB', 'Network', 'Service Worker', 'blob_storage')
  $files = @()
  foreach ($d in $stateDirs) {
    $p = Join-Path $sessionDir $d
    if (Test-Path -LiteralPath $p) {
      $files += Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue
    }
  }
  $files += Get-ChildItem -LiteralPath $sessionDir -File -Force -ErrorAction SilentlyContinue
  $files = $files | Where-Object { $_.Length -lt 25MB }

  $found = @{}
  $scanned = 0
  foreach ($file in $files) {
    $scanned++
    try { $text = $latin1.GetString([System.IO.File]::ReadAllBytes($file.FullName)) } catch { continue }
    foreach ($pattern in $patterns) {
      foreach ($m in [regex]::Matches($text, $pattern, 'IgnoreCase')) {
        $id = $m.Groups[1].Value.ToLowerInvariant()
        if (-not $known.ContainsKey($id)) { $found[$id] = $true }
      }
    }
  }
  return [pscustomobject]@{ Scanned = $scanned; GhostIds = @($found.Keys | Sort-Object) }
}

# -------------------------------------------------------------------- backups
function Get-BackupRoot([string]$NamespaceName) {
  $root = Join-Path $env:APPDATA "Open Design\$script:BackupRootName\$NamespaceName"
  if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
  return $root
}

function New-Backup($Root, [string]$Label = 'manual') {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dest = Join-Path (Get-BackupRoot $Root.Name) "$stamp-$Label"
  Write-Step "Backup -> $dest"
  if ($DryRun) {
    Write-Info 'Dry run: would copy data + user-data.'
    return $dest
  }
  New-Item -ItemType Directory -Path $dest -Force | Out-Null
  if (Test-Path -LiteralPath $Root.Data) {
    Copy-Item -LiteralPath $Root.Data -Destination (Join-Path $dest 'data') -Recurse -Force
  }
  if (Test-Path -LiteralPath $Root.UserData) {
    Copy-Item -LiteralPath $Root.UserData -Destination (Join-Path $dest 'user-data') -Recurse -Force
  }
  $size = (Get-DirSize (Join-Path $dest 'data')) + (Get-DirSize (Join-Path $dest 'user-data'))
  Write-Ok ("Backup written ({0})." -f (Format-Bytes $size))
  return $dest
}

function Get-Backups($Root) {
  $dir = Get-BackupRoot $Root.Name
  Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
}

function Restore-Backup($Root, [string]$Source) {
  if (-not $Source) {
    $latest = Get-Backups $Root | Select-Object -First 1
    if (-not $latest) { throw 'No backups found.' }
    $Source = $latest.FullName
  }
  if (-not (Test-Path -LiteralPath $Source)) { throw "Backup not found: $Source" }
  if (-not (Confirm-Action "Replace current app data with backup '$Source'?")) {
    Write-Warn 'Cancelled.'; return
  }
  New-Backup $Root 'pre-restore' | Out-Null
  if ($DryRun) { Write-Info 'Dry run: would restore files.'; return }
  foreach ($pair in @(@('data', $Root.Data), @('user-data', $Root.UserData))) {
    $src = Join-Path $Source $pair[0]
    $dst = $pair[1]
    if (-not (Test-Path -LiteralPath $src)) { continue }
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
  }
  Write-Ok 'Restore complete.'
}

# ------------------------------------------------------- interactive pickers
function Select-ProjectInteractive($projects, [string]$Action = 'delete') {
  $list = @($projects)
  if ($list.Count -eq 0) { Write-Warn 'There are no projects.'; return $null }
  Write-Step 'Projects'
  for ($i = 0; $i -lt $list.Count; $i++) {
    $p = $list[$i]
    $mark = if ($p.dirExists) { '' } else { '  [folder missing]' }
    Write-Host ("   {0}) {1}{2}" -f ($i + 1), $p.name, $mark) -ForegroundColor White
    Write-Info ("       id: {0}" -f $p.id)
  }
  $sel = Read-Host "Select a project number to $Action (0 to cancel)"
  $n = 0
  if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) { return $list[$n - 1] }
  return $null
}

function Select-SessionInteractive($conversations) {
  $list = @($conversations)
  if ($list.Count -eq 0) { Write-Warn 'This project has no sessions.'; return $null }
  Write-Step 'Sessions in this project'
  for ($i = 0; $i -lt $list.Count; $i++) {
    $c = $list[$i]
    $title = if ($c.title) { $c.title } else { '(untitled)' }
    Write-Host ("   {0}) {1}" -f ($i + 1), $title) -ForegroundColor White
    Write-Info ("       {0} message(s)  -  id: {1}" -f $c.messages, $c.id)
  }
  $sel = Read-Host 'Select a session number to delete (0 to cancel)'
  $n = 0
  if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) { return $list[$n - 1] }
  return $null
}

function Select-BackupInteractive($Root) {
  $items = @(Get-Backups $Root)
  if ($items.Count -eq 0) { Write-Warn 'No backups yet.'; return $null }
  Write-Step 'Available backups (newest first)'
  for ($i = 0; $i -lt $items.Count; $i++) {
    Write-Host ("   {0}) {1}" -f ($i + 1), $items[$i].Name) -ForegroundColor White
    Write-Info ("       {0}" -f (Format-Bytes (Get-DirSize $items[$i].FullName)))
  }
  $sel = Read-Host 'Select a backup number to restore (0 to cancel)'
  $n = 0
  if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { return $items[$n - 1].FullName }
  return $null
}

# -------------------------------------------------------------------- actions
function Clear-UiState($Root) {
  $session = Join-Path $Root.UserData 'session'
  $targets = @(
    'Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'GrShaderCache',
    'DawnGraphiteCache', 'DawnWebGPUCache', 'Shared Dictionary',
    'Local Storage', 'Session Storage', 'blob_storage'
  )
  Write-Step 'Clearing renderer cache and local state'
  foreach ($name in $targets) {
    $path = Join-Path $session $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if ($DryRun) { Write-Info "would remove $name"; continue }
    try {
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
      Write-Ok "cleared $name"
    } catch {
      Write-Bad "could not clear ${name}: $($_.Exception.Message)"
    }
  }
}

function Invoke-Doctor {
  $Install = Get-AppInstall
  if (-not $Install) { throw 'Open Design installation not found. Pass -AppPath "<install dir>".' }
  $Root = Get-PrimaryRoot

  Write-Step 'Environment'
  Write-Info "Tool      : OpenDesignRepair $script:ToolVersion"
  Write-Info "Install   : $($Install.Dir)"
  Write-Info "App ver   : $($Install.Version)"
  $nsPath = Join-Path $env:APPDATA 'Open Design\namespaces'
  $allNs = @(Get-ChildItem -LiteralPath $nsPath -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  Write-Info "Namespaces: $(if ($allNs.Count) { $allNs -join ', ' } else { '(none)' })"
  Write-Info "Selected  : $($Root.Name)"
  Write-Info "Data      : $($Root.Data)"
  Write-Info "User data : $($Root.UserData)"

  $running = @(Get-OdProcesses $Install.Exe)
  Write-Info "Running   : $(if ($running.Count) { "$($running.Count) process(es)" } else { 'no' })"

  Write-Step 'Database'
  $report = Invoke-OdHelper -Arguments @('doctor') -Install $Install -Root $Root
  if (-not $report.ok) { throw "Helper error: $($report.error)" }

  $dbColor = if ($report.database.integrity -eq 'ok') { 'Green' } else { 'Red' }
  Write-Host ("   integrity : {0}" -f $report.database.integrity) -ForegroundColor $dbColor
  Write-Info ("size      : {0} (+ wal {1})" -f (Format-Bytes $report.database.bytes), (Format-Bytes $report.database.walBytes))
  Write-Info ("projects  : {0}" -f @($report.projects).Count)
  foreach ($p in $report.projects) {
    $dirMark = if ($p.dirExists) { 'dir ok' } else { 'DIR MISSING' }
    $runMark = if ($p.latestRun) { "$($p.latestRun.status)" } else { 'no runs' }
    $color = if ($p.dirExists) { 'Gray' } else { 'Yellow' }
    Write-Host ("   - {0}  [{1}, {2}]" -f $p.name, $dirMark, $runMark) -ForegroundColor $color
  }

  Write-Step 'Problems'
  $problems = 0
  if (@($report.orphanProjects).Count -gt 0) {
    $problems++
    Write-Warn ("{0} orphan project row(s) (no folder on disk): {1}" -f @($report.orphanProjects).Count, (($report.orphanProjects | ForEach-Object { $_.name }) -join ', '))
  }
  if (@($report.orphanDirs).Count -gt 0) {
    $problems++
    Write-Warn ("{0} project folder(s) without a database row: {1}" -f @($report.orphanDirs).Count, ($report.orphanDirs -join ', '))
  }
  if (@($report.runs.staleForMissingProjects).Count -gt 0) {
    $problems++
    Write-Warn ("{0} run folder(s) for deleted projects." -f @($report.runs.staleForMissingProjects).Count)
  }
  if (@($report.runs.stuck).Count -gt 0) {
    $problems++
    Write-Warn ("{0} run(s) look stuck (running/queued with no update for 10+ min)." -f @($report.runs.stuck).Count)
  }
  if ($report.blobs.orphaned -gt 0) {
    $problems++
    Write-Warn ("{0} orphaned artifact blob(s) (unreferenced files)." -f $report.blobs.orphaned)
  }
  if (@($report.leftovers.staleTaskInputDirs).Count -gt 0) {
    $problems++
    Write-Warn ("{0} leftover task-input folder(s) from deleted work." -f @($report.leftovers.staleTaskInputDirs).Count)
  }

  $knownIds = @($report.projects | ForEach-Object { $_.id })
  $ghosts = Find-UiStateGhosts -Root $Root -KnownProjectIds $knownIds
  if ($ghosts.GhostIds.Count -gt 0) {
    $problems++
    Write-Warn ("{0} stale project reference(s) in the UI cache/local storage:" -f $ghosts.GhostIds.Count)
    foreach ($id in $ghosts.GhostIds) { Write-Info "      $id" }
    Write-Info '      This is what makes deleted projects reappear. Run: fix'
  }

  if ($problems -eq 0) { Write-Ok 'No problems detected.' }
  else { Write-Info ("`n{0} issue group(s). Run 'fix' to repair the safe ones." -f $problems) }

  Write-Step 'Disk'
  Write-Info ("data      : {0}" -f (Format-Bytes (Get-DirSize $Root.Data)))
  Write-Info ("user-data : {0}" -f (Format-Bytes (Get-DirSize $Root.UserData)))

  return $report
}

function Invoke-Fix {
  $Install = Get-AppInstall
  if (-not $Install) { throw 'Open Design installation not found. Pass -AppPath "<install dir>".' }
  $Root = Get-PrimaryRoot

  Write-Step 'Repair plan'
  Write-Info '1. stop the app'
  Write-Info '2. back up data + user-data'
  Write-Info '3. prune orphan projects, stale runs, orphan blobs, stale task inputs'
  Write-Info '4. clear renderer caches and stale UI state'
  if (-not (Confirm-Action 'Proceed with the repair?')) { Write-Warn 'Cancelled.'; return }

  Stop-OdApp $Install.Exe
  if (-not $NoBackup) { New-Backup $Root 'pre-fix' | Out-Null }

  Write-Step 'Pruning database + folders'
  $pruneArgs = @('prune')
  if ($DryRun) { $pruneArgs += '--dry-run' }
  $prune = Invoke-OdHelper -Arguments $pruneArgs -Install $Install -Root $Root
  if (-not $prune.ok) { Write-Bad "prune failed: $($prune.error)" }
  else {
    Write-Ok ("projects removed: {0}" -f @($prune.deletedProjects).Count)
    Write-Ok ("run folders removed: {0}" -f @($prune.deletedRuns).Count)
    Write-Ok ("artifact blobs removed: {0}" -f $prune.deletedBlobs)
    Write-Ok ("task inputs removed: {0}" -f @($prune.deletedTaskInputs).Count)
  }

  Clear-UiState $Root

  Write-Step 'Verification'
  $after = Invoke-OdHelper -Arguments @('doctor') -Install $Install -Root $Root
  $knownIds = @($after.projects | ForEach-Object { $_.id })
  $ghosts = Find-UiStateGhosts -Root $Root -KnownProjectIds $knownIds
  if ($ghosts.GhostIds.Count -eq 0) { Write-Ok 'No stale project references remain.' }
  else { Write-Warn ("{0} stale reference(s) still present (clear UI state again after closing the app)." -f $ghosts.GhostIds.Count) }
  Write-Ok ("database integrity: {0}" -f $after.database.integrity)

  if ($StartAfter) { Start-OdApp $Install }
}

function Invoke-DeleteProject {
  $Install = Get-AppInstall
  if (-not $Install) { throw 'Open Design installation not found. Pass -AppPath "<install dir>".' }
  $Root = Get-PrimaryRoot

  $doctorReport = Invoke-OdHelper -Arguments @('doctor') -Install $Install -Root $Root
  if (-not $doctorReport.ok) { throw "Helper error: $($doctorReport.error)" }
  $all = @($doctorReport.projects)

  $target = $null
  if ($ProjectId) {
    $target = $all | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1
    if (-not $target) { Write-Warn "No project with id '$ProjectId'." }
  } elseif ($ProjectName) {
    $matches = @($all | Where-Object { $_.name -eq $ProjectName })
    if ($matches.Count -eq 1) { $target = $matches[0] }
    elseif ($matches.Count -gt 1) {
      Write-Warn 'Name matches multiple projects; re-run with -ProjectId.'
      foreach ($p in $matches) { Write-Info ("  {0}  {1}" -f $p.id, $p.name) }
      return
    } else { Write-Warn "No project named '$ProjectName'." }
  } elseif ([Environment]::UserInteractive) {
    $target = Select-ProjectInteractive $all 'delete'
  } else {
    Write-Warn 'Specify -ProjectId or -ProjectName (or run interactively to pick).'
  }

  if (-not $target) {
    Write-Info 'Available projects:'
    foreach ($p in $all) { Write-Info ("  {0}  {1}" -f $p.id, $p.name) }
    return
  }
  Write-Step "Delete project: $($target.name)"
  Write-Info "id: $($target.id)"
  if (-not (Confirm-Action "Permanently delete '$($target.name)' (rows, folder, runs)?")) {
    Write-Warn 'Cancelled.'; return
  }

  Stop-OdApp $Install.Exe
  if (-not $NoBackup) { New-Backup $Root 'pre-delete' | Out-Null }

  $cliArgs = @('delete-project', '--id', $target.id)
  if ($DryRun) { $cliArgs += '--dry-run' }
  $result = Invoke-OdHelper -Arguments $cliArgs -Install $Install -Root $Root
  if (-not $result.ok) { Write-Bad "delete failed: $($result.error)"; return }
  if (-not $result.found) { Write-Warn 'Project no longer exists in the database.'; return }

  Write-Ok 'Rows deleted (conversations, messages, tabs cascade automatically).'
  Write-Ok ("project folder removed: {0}" -f $result.removedProjectDir)
  Write-Ok ("run folders removed: {0}" -f @($result.removedRuns).Count)

  Write-Step 'UI cache'
  Clear-UiState $Root

  if ($StartAfter) { Start-OdApp $Install }
}

function Invoke-DeleteSession {
  $Install = Get-AppInstall
  if (-not $Install) { throw 'Open Design installation not found. Pass -AppPath "<install dir>".' }
  $Root = Get-PrimaryRoot

  $report = Invoke-OdHelper -Arguments @('doctor') -Install $Install -Root $Root
  if (-not $report.ok) { throw "Helper error: $($report.error)" }
  $convs = @($report.conversations)
  $projects = @($report.projects)

  $target = $null
  if ($SessionId) {
    $target = $convs | Where-Object { $_.id -eq $SessionId } | Select-Object -First 1
    if (-not $target) { Write-Warn "No session with id '$SessionId'." }
  } else {
    $proj = $null
    if ($ProjectId) { $proj = $projects | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1 }
    elseif ($ProjectName) { $proj = $projects | Where-Object { $_.name -eq $ProjectName } | Select-Object -First 1 }
    elseif ([Environment]::UserInteractive) { $proj = Select-ProjectInteractive $projects 'open' }
    else { Write-Warn 'Specify -SessionId, or -ProjectId/-ProjectName (or run interactively).' }

    if ($proj) {
      $projConvs = @($convs | Where-Object { $_.projectId -eq $proj.id })
      if ($SessionTitle) {
        $target = $projConvs | Where-Object { $_.title -eq $SessionTitle } | Select-Object -First 1
        if (-not $target) { Write-Warn "No session titled '$SessionTitle' in '$($proj.name)'." }
      } elseif ([Environment]::UserInteractive) {
        $target = Select-SessionInteractive $projConvs
      } else {
        Write-Warn 'Specify -SessionTitle or -SessionId (or run interactively to pick).'
      }
    }
  }

  if (-not $target) {
    Write-Info 'Available sessions:'
    foreach ($c in $convs) { Write-Info ("  {0}  [{1}]  {2}" -f $c.id, $c.projectId, $c.title) }
    return
  }

  $projName = ($projects | Where-Object { $_.id -eq $target.projectId } | Select-Object -First 1).name
  Write-Step "Delete session: $(if ($target.title) { $target.title } else { '(untitled)' })"
  Write-Info "id      : $($target.id)"
  Write-Info "project : $projName ($($target.projectId))"
  Write-Info 'Note: the app UI normally auto-creates a replacement when you delete the last'
  Write-Info '      session. This command removes it for real (no replacement is created).'
  if (-not (Confirm-Action "Permanently delete this session and its messages?")) {
    Write-Warn 'Cancelled.'; return
  }

  Stop-OdApp $Install.Exe
  if (-not $NoBackup) { New-Backup $Root 'pre-delete-session' | Out-Null }

  $cliArgs = @('delete-session', '--id', $target.id, '--project', $target.projectId)
  if ($DryRun) { $cliArgs += '--dry-run' }
  $result = Invoke-OdHelper -Arguments $cliArgs -Install $Install -Root $Root
  if (-not $result.ok) { Write-Bad "delete failed: $($result.error)"; return }
  if (-not $result.found) { Write-Warn 'Session no longer exists in the database.'; return }

  Write-Ok 'Session deleted (messages and related rows cascade automatically).'
  Write-Ok ("run folders removed: {0}" -f @($result.removedRuns).Count)
  Write-Ok ("task inputs removed: {0}" -f @($result.removedTaskInputs).Count)

  Write-Step 'UI cache'
  Clear-UiState $Root

  if ($StartAfter) { Start-OdApp $Install }
}

function Invoke-FactoryReset {
  $Install = Get-AppInstall   # may be $null (e.g. wiping leftovers after uninstall)
  $Root = Get-PrimaryRoot

  Write-Step 'Factory reset'
  Write-Info 'This deletes:'
  Write-Info "  $($Root.Data)"
  Write-Info "  $($Root.UserData)"
  Write-Info "  $($Root.Logs)"
  Write-Info "  $($Root.Updates)"
  Write-Info 'The app itself stays installed. Next launch starts as first run.'

  if (-not (Confirm-Action 'Wipe ALL Open Design app data on this device?' 'RESET')) {
    Write-Warn 'Cancelled.'; return
  }

  Stop-OdApp $(if ($Install) { $Install.Exe } else { $null })
  if (-not $NoBackup) { New-Backup $Root 'pre-reset' | Out-Null }

  foreach ($path in @($Root.Data, $Root.UserData, $Root.Logs, $Root.Updates)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if ($DryRun) { Write-Info "would remove $path"; continue }
    try {
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
      Write-Ok "removed $path"
    } catch {
      Write-Bad "could not remove ${path}: $($_.Exception.Message)"
    }
  }

  # Launcher bookkeeping that would otherwise point at the wiped payload state.
  foreach ($file in @('installation.json', 'stability-launch.json')) {
    $path = Join-Path $env:APPDATA "Open Design\$file"
    if (Test-Path -LiteralPath $path) {
      if ($DryRun) { Write-Info "would remove $path" } else {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Ok "removed $file"
      }
    }
  }

  Write-Step 'Done'
  if ($NoBackup) { Write-Warn 'No backup was made (-NoBackup).' }
  else { Write-Info ("Backups: {0}" -f (Get-BackupRoot $Root.Name)) }
  if ($StartAfter) { Start-OdApp $Install }
}

function Invoke-ListBackups($Root) {
  $items = @(Get-Backups $Root)
  if ($items.Count -eq 0) { Write-Warn 'No backups yet.'; return }
  Write-Step "Backups for $($Root.Name)"
  foreach ($item in $items) {
    $size = Get-DirSize $item.FullName
    Write-Info ("{0}  {1}" -f $item.Name, (Format-Bytes $size))
  }
}

function Invoke-Uninstall($Install) {
  if (-not $Install) { throw 'Open Design installation not found; nothing to uninstall.' }
  $uninstaller = Join-Path $Install.Dir 'Uninstall Open Design.exe'
  if (-not (Test-Path -LiteralPath $uninstaller)) { throw "Uninstaller not found: $uninstaller" }
  if (-not (Confirm-Action 'Run the Open Design uninstaller?')) { Write-Warn 'Cancelled.'; return }
  if (-not $KeepAppDataOnUninstall) {
    Write-Warn 'Your app data can be removed separately after uninstall.'
    if (Confirm-Action 'Wipe app data too (factory reset)?' 'RESET') {
      Invoke-FactoryReset
    }
  }
  if (-not $DryRun) { Start-Process -FilePath $uninstaller -Wait }
  Write-Ok 'Uninstaller finished.'
}

function Show-Version {
  Write-Step 'OpenDesignRepair'
  Write-Info "Tool version : $script:ToolVersion"
  $Install = Get-AppInstall
  if ($Install) {
    Write-Info "App install  : $($Install.Dir)"
    Write-Info "App version  : $($Install.Version)"
  } else {
    Write-Warn 'App install  : not found (data-only commands still work)'
  }
  $roots = @(Get-RootCandidates)
  if ($roots.Count -eq 0) {
    Write-Warn 'App data     : none found'
  } else {
    foreach ($r in $roots) {
      Write-Info ("Namespace    : {0}  (db: {1})" -f $r.Name, $(if ($r.HasDb) { 'yes' } else { 'no' }))
      Write-Info "               $($r.Data)"
    }
  }
}

# --------------------------------------------------------------- entry point
function Show-Menu($Install) {
  Write-Host ''
  Write-Host " Open Design Repair v$script:ToolVersion" -ForegroundColor White
  Write-Host ' ------------------' -ForegroundColor DarkGray
  if ($Install) { Write-Host " App: $($Install.Version)  ($($Install.Dir))" -ForegroundColor DarkGray }
  else { Write-Host ' App: not detected (backup/restore/reset still available)' -ForegroundColor DarkGray }
  Write-Host ' 1  Doctor (diagnose problems)'
  Write-Host ' 2  Fix (safe repair + clear ghost UI state)'
  Write-Host ' 3  Clear UI cache only (deleted items reappear)'
  Write-Host ' 4  Delete a project'
  Write-Host ' 5  Delete a session (conversation)'
  Write-Host ' 6  Backup now'
  Write-Host ' 7  Restore a backup'
  Write-Host ' 8  Factory reset (wipe all app data)'
  Write-Host ' 9  Uninstall app'
  Write-Host ' 10 Version / locations'
  Write-Host ' 0  Exit'
  Write-Host ''
}

$install = Get-AppInstall   # may be $null; data-only commands do not require it

if (-not $Command) {
  if (-not [Environment]::UserInteractive) { $Command = 'doctor' }
  else {
    while ($true) {
      Show-Menu $install
      $choice = Read-Host 'Select'
      switch ($choice) {
        '1' { Invoke-Doctor | Out-Null }
        '2' { Invoke-Fix }
        '3' {
          $r = Get-PrimaryRoot
          if (Confirm-Action 'Clear renderer cache and local UI state? (projects stay in the database)') {
            Stop-OdApp $(if ($install) { $install.Exe } else { $null })
            Clear-UiState $r
            if ($StartAfter) { Start-OdApp $install }
          }
        }
        '4' { Invoke-DeleteProject }
        '5' { Invoke-DeleteSession }
        '6' { $r = Get-PrimaryRoot; New-Backup $r 'manual' | Out-Null }
        '7' {
          $r = Get-PrimaryRoot
          $src = $BackupPath
          if (-not $src) { $src = Select-BackupInteractive $r }
          if ($src) { Restore-Backup $r $src }
        }
        '8' { Invoke-FactoryReset }
        '9' { Invoke-Uninstall $install }
        '10' { Show-Version }
        '0' { return }
        default { Write-Warn 'Unknown choice.' }
      }
      Wait-MenuPause
    }
  }
}

switch ($Command) {
  'doctor' { Invoke-Doctor | Out-Null }
  'fix' { Invoke-Fix }
  'clear-ui-state' {
    $root = Get-PrimaryRoot
    if (-not (Confirm-Action 'Clear renderer cache and local UI state? (projects stay in the database)')) { break }
    Stop-OdApp $(if ($install) { $install.Exe } else { $null })
    Clear-UiState $root
    if ($StartAfter) { Start-OdApp $install }
  }
  'delete-project' { Invoke-DeleteProject }
  'delete-session' { Invoke-DeleteSession }
  'backup' { $root = Get-PrimaryRoot; New-Backup $root 'manual' | Out-Null }
  'restore' {
    $root = Get-PrimaryRoot
    $src = $BackupPath
    if (-not $src -and [Environment]::UserInteractive) { $src = Select-BackupInteractive $root }
    if ($src -or -not [Environment]::UserInteractive) { Restore-Backup $root $src }
  }
  'list-backups' { $root = Get-PrimaryRoot; Invoke-ListBackups $root }
  'factory-reset' { Invoke-FactoryReset }
  'uninstall' { Invoke-Uninstall $install }
  'version' { Show-Version }
}