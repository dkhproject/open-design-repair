#!/usr/bin/env node
/**
 * OpenDesignRepair — cross-platform maintenance tool for Open Design desktop app.
 * Runs on Windows, macOS, and Linux.
 *
 * On Windows: uses the app's Electron binary to run the database helper (for better-sqlite3 ABI compatibility).
 * On macOS/Linux: uses system Node with better-sqlite3 (install via npm) or falls back to Electron.
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TOOL_VERSION = '1.0.0';
const HELPER_PATH = path.join(__dirname, 'lib', 'od-data.mjs');

const COLORS = {
  reset: '\x1b[0m',
  cyan: '\x1b[36m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  red: '\x1b[31m',
  gray: '\x1b[90m',
};

function logStep(text) { console.log(`${COLORS.cyan}\n== ${text}${COLORS.reset}`); }
function logOk(text) { console.log(`${COLORS.green}   [ok]   ${text}${COLORS.reset}`); }
function logWarn(text) { console.log(`${COLORS.yellow}   [warn] ${text}${COLORS.reset}`); }
function logBad(text) { console.log(`${COLORS.red}   [fail] ${text}${COLORS.reset}`); }
function logInfo(text) { console.log(`${COLORS.gray}   ${text}${COLORS.reset}`); }

function formatBytes(bytes) {
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(2)} GB`;
  if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} B`;
}

function getDirSize(dir) {
  try {
    if (!fs.existsSync(dir)) return 0;
    let total = 0;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true, recursive: true })) {
      if (entry.isFile()) {
        try { total += fs.statSync(path.join(entry.parentPath ?? dir, entry.name)).size; } catch {}
      }
    }
    return total;
  } catch { return 0; }
}

// ------------------------------------------------------------- Platform paths
function getPlatformPaths() {
  const platform = process.platform; // 'win32', 'darwin', 'linux'
  const home = os.homedir();

  if (platform === 'win32') {
    return {
      appCandidates: [
        path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Open Design'),
        'C:\\Program Files\\Open Design',
        path.join(process.env['ProgramFiles(x86)'] || '', 'Open Design'),
      ],
      dataRoot: path.join(process.env.APPDATA || '', 'Open Design', 'namespaces'),
      backupRoot: path.join(process.env.APPDATA || '', 'Open Design', 'od-repair-backups'),
      exeName: 'Open Design.exe',
    };
  } else if (platform === 'darwin') {
    return {
      appCandidates: [
        '/Applications/Open Design.app',
        path.join(home, 'Applications', 'Open Design.app'),
      ],
      dataRoot: path.join(home, 'Library', 'Application Support', 'Open Design', 'namespaces'),
      backupRoot: path.join(home, 'Library', 'Application Support', 'Open Design', 'od-repair-backups'),
      exeName: 'Open Design',
      appBundle: true,
    };
  } else {
    // Linux
    return {
      appCandidates: [
        '/opt/Open Design',
        '/usr/lib/open-design',
        path.join(home, '.local', 'share', 'applications', 'Open Design'),
      ],
      dataRoot: path.join(home, '.config', 'Open Design', 'namespaces'),
      backupRoot: path.join(home, '.config', 'Open Design', 'od-repair-backups'),
      exeName: 'open-design',
    };
  }
}

// ------------------------------------------------------------- Discovery
function findAppInstall(paths) {
  for (const dir of paths.appCandidates) {
    if (!dir || !fs.existsSync(dir)) continue;
    let exePath;
    if (paths.appBundle) {
      exePath = path.join(dir, 'Contents', 'MacOS', paths.exeName);
    } else {
      exePath = path.join(dir, paths.exeName);
    }
    if (fs.existsSync(exePath)) {
      const appRoot = paths.appBundle
        ? path.join(dir, 'Contents', 'Resources', 'app')
        : path.join(dir, 'resources', 'app');
      return { dir, exe: exePath, appRoot };
    }
  }
  return null;
}

function findPrimaryDataRoot(dataRoot) {
  if (!fs.existsSync(dataRoot)) return null;
  const namespaces = fs.readdirSync(dataRoot, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => {
      const nsPath = path.join(dataRoot, d.name);
      const dbPath = path.join(nsPath, 'data', 'app.sqlite');
      return {
        name: d.name,
        path: nsPath,
        data: path.join(nsPath, 'data'),
        userData: path.join(nsPath, 'user-data'),
        logs: path.join(nsPath, 'logs'),
        hasDb: fs.existsSync(dbPath),
        mtime: fs.existsSync(dbPath) ? fs.statSync(dbPath).mtimeMs : 0,
      };
    })
    .sort((a, b) => b.mtime - a.mtime);
  return namespaces[0] || null;
}

function getOdProcesses(exePath) {
  if (!exePath) return [];
  // Cross-platform process detection - simplified
  try {
    if (process.platform === 'win32') {
      const out = spawnSync('tasklist', ['/FI', `IMAGENAME eq ${path.basename(exePath)}`, '/FO', 'CSV'], { encoding: 'utf8' });
      return out.stdout.includes(path.basename(exePath)) ? [{ pid: 'unknown' }] : [];
    } else {
      const out = spawnSync('pgrep', ['-f', exePath], { encoding: 'utf8' });
      return out.stdout.trim() ? [{ pid: out.stdout.trim() }] : [];
    }
  } catch { return []; }
}

function stopOdApp(exePath) {
  if (!exePath) { logWarn('App executable not found; ensure Open Design is closed.'); return; }
  const procs = getOdProcesses(exePath);
  if (procs.length === 0) { logOk('Open Design is not running.'); return; }
  logInfo(`Stopping ${procs.length} process(es)...`);
  try {
    if (process.platform === 'win32') {
      spawnSync('taskkill', ['/F', '/IM', path.basename(exePath)], { stdio: 'ignore' });
    } else {
      spawnSync('pkill', ['-f', exePath], { stdio: 'ignore' });
    }
  } catch {}
  for (let i = 0; i < 10; i++) {
    if (getOdProcesses(exePath).length === 0) break;
    sleep(500);
  }
  if (getOdProcesses(exePath).length > 0) {
    logWarn('Some processes did not exit. Close manually, then re-run.');
  } else {
    logOk('Open Design stopped.');
  }
}

function startOdApp(install) {
  if (!install) { logWarn('App not found; cannot relaunch.'); return; }
  logInfo('Starting Open Design...');
  try {
    if (process.platform === 'win32') {
      spawnSync(install.exe, [], { detached: true, stdio: 'ignore' });
    } else if (install.appRoot) { // macOS .app bundle
      spawnSync('open', ['-a', install.dir], { stdio: 'ignore' });
    } else {
      spawnSync(install.exe, [], { detached: true, stdio: 'ignore' });
    }
    logOk('Launched.');
  } catch { logWarn('Could not start app.'); }
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ------------------------------------------------------------- Backup
function getBackupRoot(backupRoot, namespace) {
  const root = path.join(backupRoot, namespace);
  if (!fs.existsSync(root)) fs.mkdirSync(root, { recursive: true });
  return root;
}

function newBackup(dataRoot, userDataRoot, backupRoot, namespace, label = 'manual') {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const dest = path.join(getBackupRoot(backupRoot, namespace), `${stamp}-${label}`);
  logStep(`Backup -> ${dest}`);
  fs.mkdirSync(dest, { recursive: true });
  if (fs.existsSync(dataRoot)) fs.cpSync(dataRoot, path.join(dest, 'data'), { recursive: true });
  if (fs.existsSync(userDataRoot)) fs.cpSync(userDataRoot, path.join(dest, 'user-data'), { recursive: true });
  const size = getDirSize(path.join(dest, 'data')) + getDirSize(path.join(dest, 'user-data'));
  logOk(`Backup written (${formatBytes(size)}).`);
  return dest;
}

function listBackups(backupRoot, namespace) {
  const dir = getBackupRoot(backupRoot, namespace);
  return fs.existsSync(dir) ? fs.readdirSync(dir, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => ({ name: d.name, path: path.join(dir, d.name) }))
    .sort((a, b) => b.name.localeCompare(a.name)) : [];
}

function restoreBackup(dataRoot, userDataRoot, backupRoot, namespace, source) {
  const backups = listBackups(backupRoot, namespace);
  const target = source ? backups.find(b => b.path === source || b.name === source) : backups[0];
  if (!target) throw new Error('Backup not found.');
  if (!confirm(`Replace current app data with backup '${target.name}'?`)) return;
  newBackup(dataRoot, userDataRoot, backupRoot, namespace, 'pre-restore');
  if (fs.existsSync(dataRoot)) fs.rmSync(dataRoot, { recursive: true, force: true });
  if (fs.existsSync(userDataRoot)) fs.rmSync(userDataRoot, { recursive: true, force: true });
  fs.cpSync(path.join(target.path, 'data'), dataRoot, { recursive: true });
  fs.cpSync(path.join(target.path, 'user-data'), userDataRoot, { recursive: true });
  logOk('Restore complete.');
}

// ------------------------------------------------------------- DB helper
function invokeHelper(command, args, install, dataDir) {
  if (!fs.existsSync(HELPER_PATH)) throw new Error(`Helper missing: ${HELPER_PATH}`);

  const isWindows = process.platform === 'win32';
  const cmd = isWindows ? install.exe : 'node';
  const cmdArgs = isWindows
    ? [HELPER_PATH, command, ...args, '--app', install.appRoot, '--data', dataDir]
    : ['--experimental-sqlite', HELPER_PATH, command, ...args, '--data', dataDir];

  const env = { ...process.env };
  if (isWindows) env.ELECTRON_RUN_AS_NODE = '1';

  const result = spawnSync(cmd, cmdArgs, { env, encoding: 'utf8', timeout: 120000 });
  const text = result.stdout?.trim() || '';
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  const json = start >= 0 && end > start ? text.slice(start, end + 1) : '';
  if (!json) throw new Error(`Helper failed (exit ${result.status}): ${result.stderr || 'no output'}`);
  return JSON.parse(json);
}

// ------------------------------------------------------------- Actions
async function runDoctor(install, primary, paths) {
  logStep('Environment');
  if (install) {
    logInfo(`Tool      : OpenDesignRepair ${TOOL_VERSION}`);
    logInfo(`Install   : ${install.dir}`);
  } else {
    logWarn('App install: not found (data-only commands still work)');
  }
  logInfo(`Namespace : ${primary.name}`);
  logInfo(`Data      : ${primary.data}`);
  logInfo(`User data : ${primary.userData}`);

  const running = getOdProcesses(install?.exe);
  logInfo(`Running   : ${running.length ? `${running.length} process(es)` : 'no'}`);

  logStep('Database');
  const report = invokeHelper('doctor', [], install, primary.data);
  if (!report.ok) throw new Error(`Helper error: ${report.error}`);

  const dbColor = report.database.integrity === 'ok' ? COLORS.green : COLORS.red;
  console.log(`${dbColor}   integrity : ${report.database.integrity}${COLORS.reset}`);
  logInfo(`size      : ${formatBytes(report.database.bytes)} (+ wal ${formatBytes(report.database.walBytes)})`);
  logInfo(`projects  : ${report.projects.length}`);
  for (const p of report.projects) {
    const dirMark = p.dirExists ? 'dir ok' : 'DIR MISSING';
    const runMark = p.latestRun ? p.latestRun.status : 'no runs';
    const color = p.dirExists ? COLORS.gray : COLORS.yellow;
    console.log(`${color}   - ${p.name}  [${dirMark}, ${runMark}]${COLORS.reset}`);
  }

  logStep('Problems');
  let problems = 0;
  if (report.orphanProjects.length) { problems++; logWarn(`${report.orphanProjects.length} orphan project row(s) (no folder on disk): ${report.orphanProjects.map(p => p.name).join(', ')}`); }
  if (report.orphanDirs.length) { problems++; logWarn(`${report.orphanDirs.length} project folder(s) without a database row: ${report.orphanDirs.join(', ')}`); }
  if (report.runs.staleForMissingProjects.length) { problems++; logWarn(`${report.runs.staleForMissingProjects.length} run folder(s) for deleted projects.`); }
  if (report.runs.stuck.length) { problems++; logWarn(`${report.runs.stuck.length} run(s) look stuck (running/queued with no update for 10+ min).`); }
  if (report.blobs.orphaned) { problems++; logWarn(`${report.blobs.orphaned} orphaned artifact blob(s).`); }
  if (report.leftovers.staleTaskInputDirs.length) { problems++; logWarn(`${report.leftovers.staleTaskInputDirs.length} leftover task-input folder(s).`); }
  if (problems === 0) logOk('No problems detected.');
  else logInfo(`\n${problems} issue group(s). Run 'fix' to repair the safe ones.`);

  logStep('Disk');
  logInfo(`data      : ${formatBytes(getDirSize(primary.data))}`);
  logInfo(`user-data : ${formatBytes(getDirSize(primary.userData))}`);

  return report;
}

async function runFix(install, primary, paths, dryRun) {
  logStep('Repair plan');
  logInfo('1. stop the app');
  logInfo('2. back up data + user-data');
  logInfo('3. prune orphan projects, stale runs, orphan blobs, stale task inputs');
  logInfo('4. clear renderer caches and stale UI state');
  if (!dryRun && !confirm('Proceed with the repair?')) return;

  stopOdApp(install?.exe);
  if (!dryRun) newBackup(primary.data, primary.userData, paths.backupRoot, primary.name, 'pre-fix');

  logStep('Pruning database + folders');
  const prune = invokeHelper('prune', dryRun ? ['--dry-run'] : [], install, primary.data);
  if (!prune.ok) logBad(`prune failed: ${prune.error}`);
  else {
    logOk(`projects removed: ${prune.deletedProjects.length}`);
    logOk(`run folders removed: ${prune.deletedRuns.length}`);
    logOk(`artifact blobs removed: ${prune.deletedBlobs}`);
    logOk(`task inputs removed: ${prune.deletedTaskInputs.length}`);
  }

  logStep('Clearing renderer cache and local state');
  clearUiState(primary.userData, dryRun);

  logStep('Verification');
  const after = invokeHelper('doctor', [], install, primary.data);
  logOk(`database integrity: ${after.database.integrity}`);
}

function clearUiState(userDataRoot, dryRun) {
  const session = path.join(userDataRoot, 'session');
  const targets = [
    'Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'GrShaderCache',
    'DawnGraphiteCache', 'DawnWebGPUCache', 'Shared Dictionary',
    'Local Storage', 'Session Storage', 'blob_storage',
  ];
  for (const name of targets) {
    const p = path.join(session, name);
    if (!fs.existsSync(p)) continue;
    if (dryRun) { logInfo(`would remove ${name}`); continue; }
    try { fs.rmSync(p, { recursive: true, force: true }); logOk(`cleared ${name}`); }
    catch (e) { logBad(`could not clear ${name}: ${e.message}`); }
  }
}

async function runDeleteProject(install, primary, paths, projectId, projectName, dryRun) {
  const report = invokeHelper('doctor', [], install, primary.data);
  if (!report.ok) throw new Error(`Helper error: ${report.error}`);

  let target = null;
  if (projectId) target = report.projects.find(p => p.id === projectId);
  else if (projectName) target = report.projects.find(p => p.name === projectName);
  else if (!dryRun && process.stdin.isTTY) {
    // interactive picker
    console.log('\nProjects:');
    report.projects.forEach((p, i) => console.log(`  ${i + 1}) ${p.name}  [${p.dirExists ? 'dir ok' : 'DIR MISSING'}]  (id: ${p.id})`));
    const sel = prompt('Select a project number to delete (0 to cancel): ');
    const n = parseInt(sel);
    if (!isNaN(n) && n >= 1 && n <= report.projects.length) target = report.projects[n - 1];
  }

  if (!target) {
    logWarn('No matching project found.');
    report.projects.forEach(p => logInfo(`  ${p.id}  ${p.name}`));
    return;
  }

  logStep(`Delete project: ${target.name}`);
  logInfo(`id: ${target.id}`);
  if (!dryRun && !confirm(`Permanently delete '${target.name}' (rows, folder, runs)?`)) return;

  stopOdApp(install?.exe);
  if (!dryRun) newBackup(primary.data, primary.userData, paths.backupRoot, primary.name, 'pre-delete');

  const result = invokeHelper('delete-project', ['--id', target.id, ...(dryRun ? ['--dry-run'] : [])], install, primary.data);
  if (!result.ok) { logBad(`delete failed: ${result.error}`); return; }
  if (!result.found) { logWarn('Project no longer exists in the database.'); return; }

  logOk('Rows deleted (conversations, messages, tabs cascade automatically).');
  logOk(`project folder removed: ${result.removedProjectDir}`);
  logOk(`run folders removed: ${result.removedRuns.length}`);

  clearUiState(primary.userData, dryRun);
}

async function runClearUiState(primary, paths, dryRun) {
  if (!dryRun && !confirm('Clear renderer cache and local UI state? (projects stay in the database)')) return;
  stopOdApp(findAppInstall(paths)?.exe);
  clearUiState(primary.userData, dryRun);
}

async function runFactoryReset(install, primary, paths, dryRun) {
  logStep('Factory reset');
  logInfo('This deletes:');
  logInfo(`  ${primary.data}`);
  logInfo(`  ${primary.userData}`);
  logInfo(`  ${primary.logs}`);
  logInfo('The app itself stays installed. Next launch starts as first run.');
  if (!dryRun && !confirm('Wipe ALL Open Design app data on this device? Type RESET to confirm:', 'RESET')) return;

  stopOdApp(install?.exe);
  if (!dryRun) newBackup(primary.data, primary.userData, paths.backupRoot, primary.name, 'pre-reset');

  for (const p of [primary.data, primary.userData, primary.logs]) {
    if (!fs.existsSync(p)) continue;
    if (dryRun) logInfo(`would remove ${p}`);
    else { try { fs.rmSync(p, { recursive: true, force: true }); logOk(`removed ${p}`); } catch (e) { logBad(`could not remove ${p}: ${e.message}`); } }
  }

  logStep('Done');
  if (dryRun) return;
  if (!dryRun && !process.argv.includes('--no-backup')) logInfo(`Backups: ${getBackupRoot(paths.backupRoot, primary.name)}`);
}

function confirm(question, typedWord) {
  if (process.argv.includes('--yes')) return true;
  if (process.argv.includes('--dry-run')) return true;
  if (typedWord) {
    const readline = require('node:readline').createInterface({ input: process.stdin, output: process.stdout });
    return new Promise(r => readline.question(`${question}\nType '${typedWord}' to continue: `, ans => { readline.close(); r(ans === typedWord); }));
  }
  const readline = require('node:readline').createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(r => readline.question(`${question} [y/N] `, ans => { readline.close(); r(/^y(es)?$/i.test(ans)); }));
}

function prompt(question) {
  const readline = require('node:readline').createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(r => readline.question(question, ans => { readline.close(); r(ans); }));
}

function showVersion(install, primary, paths) {
  logStep('OpenDesignRepair');
  logInfo(`Tool version : ${TOOL_VERSION}`);
  if (install) { logInfo(`App install  : ${install.dir}`); }
  else { logWarn('App install  : not found (data-only commands still work)'); }
  if (primary) { logInfo(`Data dir     : ${primary.data}`); }
  else { logWarn('Data dir     : none found'); }
  const backups = listBackups(paths.backupRoot, primary?.name || 'default');
  logInfo(`Backups      : ${backups.length} available`);
}

function showMenu(install, primary) {
  console.log(`\n Open Design Repair v${TOOL_VERSION}`);
  console.log(' ------------------');
  if (install) console.log(` App: ${install.dir}`);
  else console.log(' App: not detected (data-only commands still available)');
  console.log(' 1  Doctor (diagnose problems)');
  console.log(' 2  Fix (safe repair + clear ghost UI state)');
  console.log(' 3  Clear UI cache only (deleted items reappear)');
  console.log(' 4  Delete a project');
  console.log(' 5  Backup now');
  console.log(' 6  Restore a backup');
  console.log(' 7  Factory reset (wipe all app data)');
  console.log(' 8  Version / locations');
  console.log(' 0  Exit\n');
}

async function main() {
  const paths = getPlatformPaths();
  const install = findAppInstall(paths);
  const primary = findPrimaryDataRoot(paths.dataRoot);

  const args = process.argv.slice(2);
  const command = args[0];
  const dryRun = args.includes('--dry-run');

  if (!command || !['doctor', 'fix', 'clear-ui-state', 'delete-project', 'backup', 'restore', 'list-backups', 'factory-reset', 'version'].includes(command)) {
    if (!process.stdin.isTTY) { await runDoctor(install, primary, paths); return; }
    while (true) {
      showMenu(install, primary);
      const choice = await prompt('Select: ');
      switch (choice) {
        case '1': await runDoctor(install, primary, paths); break;
        case '2': await runFix(install, primary, paths, false); break;
        case '3': await runClearUiState(primary, paths, false); break;
        case '4': await runDeleteProject(install, primary, paths, null, null, false); break;
        case '5': newBackup(primary.data, primary.userData, paths.backupRoot, primary.name, 'manual'); break;
        case '6': restoreBackup(primary.data, primary.userData, paths.backupRoot, primary.name, null); break;
        case '7': await runFactoryReset(install, primary, paths, false); break;
        case '8': showVersion(install, primary, paths); break;
        case '0': return;
        default: logWarn('Unknown choice.');
      }
      await prompt('\nPress Enter to continue...');
    }
    return;
  }

  const projectId = args.find(a => a === '--id') ? args[args.indexOf('--id') + 1] : null;
  const projectName = args.find(a => a === '--name') ? args[args.indexOf('--name') + 1] : null;
  const backupPath = args.find(a => a === '--backup-path') ? args[args.indexOf('--backup-path') + 1] : null;

  try {
    switch (command) {
      case 'doctor': await runDoctor(install, primary, paths); break;
      case 'fix': await runFix(install, primary, paths, dryRun); break;
      case 'clear-ui-state': await runClearUiState(primary, paths, dryRun); break;
      case 'delete-project': await runDeleteProject(install, primary, paths, projectId, projectName, dryRun); break;
      case 'backup': newBackup(primary.data, primary.userData, paths.backupRoot, primary.name, 'manual'); break;
      case 'restore': restoreBackup(primary.data, primary.userData, paths.backupRoot, primary.name, backupPath); break;
      case 'list-backups': listBackups(paths.backupRoot, primary.name).forEach(b => logInfo(`${b.name}  ${formatBytes(getDirSize(b.path))}`)); break;
      case 'factory-reset': await runFactoryReset(install, primary, paths, dryRun); break;
      case 'version': showVersion(install, primary, paths); break;
    }
  } catch (e) {
    logBad(e.message);
    process.exit(1);
  }
}

main();