#!/usr/bin/env node
/**
 * od-data.mjs — data-layer helper for OpenDesignRepair.
 *
 * Runs inside the Open Design Electron binary with ELECTRON_RUN_AS_NODE=1 so it
 * uses the app's own bundled better-sqlite3 build (matching native ABI). This
 * means no separate Node.js or native-module install is required.
 *
 * Usage:
 *   od-data.mjs <command> --app <resources/app dir> --data <data dir> [options]
 *
 * Commands:
 *   doctor                     Inspect DB + folders, print a JSON report.
 *   prune                      Remove orphaned rows/runs/blobs, then vacuum.
 *   delete-project --id <id>   Delete one project (rows + folder + runs).
 *                --name <name>
 *   delete-session --id <id>   Delete one conversation/session (rows + runs +
 *                --project <id> task inputs). Does NOT auto-create a replacement.
 *                --title <name>
 *
 * Options:
 *   --dry-run                  Report what would change; change nothing.
 *   --include-orphan-dirs      prune: also delete project folders with no DB row.
 *
 * Output: a single JSON object on stdout (diagnostics go to stderr).
 *
 * The helper is defensive about schema drift across app versions: it checks for
 * the existence of tables/columns before querying them and skips optional
 * cleanup steps when a table is absent or shaped differently.
 */

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        out[key] = next;
        i++;
      } else {
        out[key] = true;
      }
    } else {
      out._.push(a);
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const command = args._[0] ?? 'doctor';
const dryRun = Boolean(args['dry-run']);

function fail(message, code = 1) {
  console.log(JSON.stringify({ ok: false, error: message }));
  process.exit(code);
}

if (!args.app) fail('missing --app <resources/app directory>');
if (!args.data) fail('missing --data <data directory>');

const appRoot = path.resolve(args.app);
const appPkgPath = path.join(appRoot, 'package.json');
if (!fs.existsSync(appPkgPath)) {
  fail(`not an Open Design app directory (no package.json): ${appRoot}`);
}

const requireFromApp = createRequire(appPkgPath);
let Database;
try {
  Database = requireFromApp('better-sqlite3');
} catch (error) {
  fail(`cannot load better-sqlite3 from the app bundle: ${error.message}`);
}

const dataDir = path.resolve(args.data);
const dbPath = path.join(dataDir, 'app.sqlite');
if (!fs.existsSync(dbPath)) fail(`database not found: ${dbPath}`);

const projectsDir = path.join(dataDir, 'projects');
const runsDir = path.join(dataDir, 'runs');
const blobsDir = path.join(dataDir, 'chat-artifact-blobs', 'objects');
const taskInputsDir = path.join(dataDir, 'od-next-task-inputs');
const receiptsDir = path.join(dataDir, 'task-telemetry-receipts');

const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
};
const listDirs = (dir) => {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name);
  } catch {
    return [];
  }
};
const listFiles = (dir) => {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isFile())
      .map((e) => e.name);
  } catch {
    return [];
  }
};
const safeUnlink = (file) => {
  try {
    fs.rmSync(file, { force: true });
    return true;
  } catch {
    return false;
  }
};
const safeRmdir = (dir) => {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
    return true;
  } catch {
    return false;
  }
};

function open(readonly) {
  const db = new Database(dbPath, readonly ? { readonly: true, fileMustExist: true } : {});
  db.pragma('busy_timeout = 5000');
  if (!readonly) db.pragma('foreign_keys = ON');
  return db;
}

function tableExists(db, name) {
  return Boolean(db.prepare("select 1 from sqlite_master where type='table' and name=?").get(name));
}

function columnSet(db, table) {
  if (!tableExists(db, table)) return new Set();
  try {
    return new Set(db.pragma(`table_info("${table}")`).map((c) => c.name));
  } catch {
    return new Set();
  }
}

function requireProjectsTable(db) {
  if (!tableExists(db, 'projects')) {
    fail('database has no "projects" table — unsupported app version or wrong data directory');
  }
}

// The task-execution id column has been named differently across versions.
function taskExecIds(db) {
  const cols = columnSet(db, 'strategy_task_executions');
  const idCol = cols.has('task_execution_id') ? 'task_execution_id' : cols.has('id') ? 'id' : null;
  if (!idCol) return new Set();
  return new Set(
    db
      .prepare(`select "${idCol}" as id from strategy_task_executions`)
      .all()
      .map((r) => r.id),
  );
}

function runIndex() {
  const runs = [];
  for (const id of listDirs(runsDir)) {
    const state = readJson(path.join(runsDir, id, 'state.json'));
    if (!state) continue;
    runs.push({
      id,
      projectId: state.projectId ?? null,
      conversationId: state.conversationId ?? null,
      status: state.status ?? 'unknown',
      updatedAt: state.updatedAt ?? null,
      startedAt: state.startedAt ?? null,
    });
  }
  return runs;
}

function blobStoragePath(storageKey) {
  const key = String(storageKey ?? '').replace(/\\/g, '/');
  return path.join(blobsDir, ...key.split('/').filter(Boolean));
}

function doctor() {
  const db = open(true);
  requireProjectsTable(db);
  const integrity = String(db.pragma('integrity_check', { simple: true }));

  const projectRows = db
    .prepare('select id, name, created_at as createdAt, updated_at as updatedAt from projects order by created_at')
    .all();
  const projectIds = new Set(projectRows.map((p) => p.id));
  const dirs = new Set(listDirs(projectsDir));
  const runs = runIndex();

  const projects = projectRows.map((p) => ({
    id: p.id,
    name: p.name,
    createdAt: p.createdAt,
    dirExists: dirs.has(p.id),
    latestRun: runs
      .filter((r) => r.projectId === p.id)
      .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))[0] ?? null,
  }));

  const orphanProjects = projects.filter((p) => !p.dirExists).map((p) => ({ id: p.id, name: p.name }));
  const orphanDirs = [...dirs].filter((id) => !projectIds.has(id));

  const conversations = tableExists(db, 'conversations')
    ? db
        .prepare('select id, project_id as projectId, title, session_mode as sessionMode from conversations order by created_at')
        .all()
        .map((c) => ({
          ...c,
          messages: tableExists(db, 'messages')
            ? db.prepare('select count(*) c from messages where conversation_id = ?').get(c.id).c
            : 0,
        }))
    : [];

  const blobCols = columnSet(db, 'chat_artifact_blobs');
  const blobsUsable = blobCols.has('digest') && blobCols.has('storage_key');
  const blobRowCount = tableExists(db, 'chat_artifact_blobs')
    ? db.prepare('select count(*) c from chat_artifact_blobs').get().c
    : 0;
  const blobRows = blobsUsable
    ? db.prepare('select digest, storage_key as storageKey from chat_artifact_blobs').all()
    : [];

  const snapshotCount = tableExists(db, 'chat_artifact_snapshots')
    ? db.prepare('select count(*) c from chat_artifact_snapshots').get().c
    : 0;
  const snapCols = columnSet(db, 'chat_artifact_snapshots');
  const refCols = ['content_digest', 'thumbnail_digest'].filter((c) => snapCols.has(c));
  const referenced = new Set();
  if (snapshotCount > 0 && refCols.length > 0) {
    const rows = db
      .prepare(`select ${refCols.map((c) => `"${c}"`).join(', ')} from chat_artifact_snapshots`)
      .all();
    for (const row of rows) {
      for (const c of refCols) if (row[c]) referenced.add(row[c]);
    }
  }
  const orphanBlobs = blobRows.filter((b) => !referenced.has(b.digest));

  const counts = {};
  for (const t of ['conversations', 'messages', 'tabs', 'workspace_artifacts', 'strategy_task_executions']) {
    if (tableExists(db, t)) counts[t] = db.prepare(`select count(*) c from "${t}"`).get().c;
  }

  const staleRuns = runs.filter((r) => r.projectId && !projectIds.has(r.projectId));
  const now = Date.now();
  const stuckRuns = runs.filter(
    (r) =>
      ['running', 'queued', 'starting'].includes(String(r.status)) &&
      r.updatedAt &&
      now - Number(r.updatedAt) > 10 * 60 * 1000,
  );

  const execIds = taskExecIds(db);
  const staleTaskInputs = listDirs(taskInputsDir).filter((id) => execIds.size > 0 && !execIds.has(id));

  db.close();

  const stat = (p) => {
    try {
      return fs.statSync(p).size;
    } catch {
      return 0;
    }
  };

  return {
    ok: true,
    command: 'doctor',
    appVersion: readJson(appPkgPath)?.version ?? null,
    dataDir,
    database: {
      path: dbPath,
      bytes: stat(dbPath),
      walBytes: stat(`${dbPath}-wal`),
      integrity,
    },
    counts,
    projects,
    conversations,
    orphanProjects,
    orphanDirs,
    blobs: { rows: blobRowCount, orphaned: orphanBlobs.length },
    runs: {
      total: runs.length,
      staleForMissingProjects: staleRuns.map((r) => r.id),
      stuck: stuckRuns.map((r) => ({ id: r.id, status: r.status, updatedAt: r.updatedAt })),
    },
    leftovers: {
      taskInputDirs: listDirs(taskInputsDir).length,
      staleTaskInputDirs: staleTaskInputs,
      telemetryReceiptFiles: listFiles(receiptsDir).length,
    },
  };
}

function prune() {
  const db = open(false);
  requireProjectsTable(db);
  const result = {
    ok: true,
    command: 'prune',
    dryRun,
    deletedProjects: [],
    deletedProjectDirs: [],
    deletedRuns: [],
    deletedBlobs: 0,
    deletedTaskInputs: [],
    vacuumed: false,
  };

  const projectRows = db.prepare('select id, name from projects').all();
  const projectIds = new Set(projectRows.map((p) => p.id));
  const dirs = listDirs(projectsDir);

  const orphans = projectRows.filter((p) => !fs.existsSync(path.join(projectsDir, p.id)));
  for (const p of orphans) {
    result.deletedProjects.push({ id: p.id, name: p.name });
    if (!dryRun) db.prepare('delete from projects where id = ?').run(p.id);
  }

  if (args['include-orphan-dirs']) {
    for (const id of dirs) {
      if (!projectIds.has(id)) {
        result.deletedProjectDirs.push(id);
        if (!dryRun) safeRmdir(path.join(projectsDir, id));
      }
    }
  }

  const liveIds = new Set(projectRows.filter((p) => !orphans.some((o) => o.id === p.id)).map((p) => p.id));
  for (const run of runIndex()) {
    if (run.projectId && !liveIds.has(run.projectId)) {
      result.deletedRuns.push(run.id);
      if (!dryRun) safeRmdir(path.join(runsDir, run.id));
    }
  }

  const blobCols = columnSet(db, 'chat_artifact_blobs');
  if (blobCols.has('digest') && blobCols.has('storage_key')) {
    const snapshots = tableExists(db, 'chat_artifact_snapshots')
      ? db.prepare('select count(*) c from chat_artifact_snapshots').get().c
      : 0;
    if (snapshots === 0) {
      const rows = db.prepare('select digest, storage_key as storageKey from chat_artifact_blobs').all();
      result.deletedBlobs = rows.length;
      if (!dryRun) db.prepare('delete from chat_artifact_blobs').run();
      for (const row of rows) {
        if (!dryRun) {
          safeUnlink(blobStoragePath(row.storageKey ?? `${row.digest.slice(0, 2)}/${row.digest.slice(2)}`));
        }
      }
    }
  }

  const execIds = taskExecIds(db);
  if (execIds.size > 0 || tableExists(db, 'strategy_task_executions')) {
    for (const id of listDirs(taskInputsDir)) {
      if (!execIds.has(id)) {
        result.deletedTaskInputs.push(id);
        if (!dryRun) safeRmdir(path.join(taskInputsDir, id));
      }
    }
  }

  if (!dryRun) {
    db.exec('vacuum');
    result.vacuumed = true;
  }
  db.close();
  return result;
}

function deleteProject() {
  const id = args.id;
  const name = args.name;
  if (!id && !name) fail('delete-project needs --id <projectId> or --name "<exact name>"');

  const db = open(false);
  requireProjectsTable(db);
  const row = id
    ? db.prepare('select id, name from projects where id = ?').get(id)
    : db.prepare('select id, name from projects where name = ?').get(name);
  if (!row) {
    db.close();
    return { ok: true, command: 'delete-project', found: false, message: 'no matching project' };
  }

  const result = {
    ok: true,
    command: 'delete-project',
    dryRun,
    found: true,
    project: { id: row.id, name: row.name },
    removedProjectDir: false,
    removedRuns: [],
  };

  const dir = path.join(projectsDir, row.id);
  if (!dryRun) db.prepare('delete from projects where id = ?').run(row.id);
  if (fs.existsSync(dir)) {
    result.removedProjectDir = !dryRun ? safeRmdir(dir) : true;
  }
  for (const run of runIndex()) {
    if (run.projectId === row.id) {
      result.removedRuns.push(run.id);
      if (!dryRun) safeRmdir(path.join(runsDir, run.id));
    }
  }
  if (!dryRun) db.exec('vacuum');
  db.close();
  return result;
}

function deleteSession() {
  const id = args.id;
  const title = args.title;
  const projectId = args.project;
  if (!id && !(projectId && title)) {
    fail('delete-session needs --id <conversationId>, or --project <projectId> --title "<exact title>"');
  }

  const db = open(false);
  requireProjectsTable(db);
  if (!tableExists(db, 'conversations')) fail('database has no "conversations" table');

  let row;
  if (id) {
    row = db.prepare('select id, project_id as projectId, title from conversations where id = ?').get(id);
    if (row && projectId && row.projectId !== projectId) row = undefined;
  } else {
    row = db
      .prepare('select id, project_id as projectId, title from conversations where project_id = ? and title = ?')
      .get(projectId, title);
  }
  if (!row) {
    db.close();
    return { ok: true, command: 'delete-session', found: false, message: 'no matching session' };
  }

  // Collect task-execution ids tied to this session so their input snapshots can
  // be removed too (they would otherwise linger as orphans).
  const execCols = columnSet(db, 'strategy_task_executions');
  const execIdCol = execCols.has('task_execution_id') ? 'task_execution_id' : execCols.has('id') ? 'id' : null;
  const execIds = execIdCol
    ? db
        .prepare(`select "${execIdCol}" as id from strategy_task_executions where conversation_id = ?`)
        .all(row.id)
        .map((r) => r.id)
    : [];

  const result = {
    ok: true,
    command: 'delete-session',
    dryRun,
    found: true,
    session: { id: row.id, title: row.title, projectId: row.projectId },
    removedRuns: [],
    removedTaskInputs: [],
    // NOTE: unlike the app UI, this does NOT auto-create a replacement session.
    replacementCreated: false,
  };

  if (!dryRun) db.prepare('delete from conversations where id = ?').run(row.id);

  for (const run of runIndex()) {
    if (run.conversationId === row.id) {
      result.removedRuns.push(run.id);
      if (!dryRun) safeRmdir(path.join(runsDir, run.id));
    }
  }
  for (const execId of execIds) {
    const dir = path.join(taskInputsDir, execId);
    if (fs.existsSync(dir)) {
      result.removedTaskInputs.push(execId);
      if (!dryRun) safeRmdir(dir);
    }
  }

  if (!dryRun) db.exec('vacuum');
  db.close();
  return result;
}

try {
  if (command === 'doctor') console.log(JSON.stringify(doctor(), null, 2));
  else if (command === 'prune') console.log(JSON.stringify(prune(), null, 2));
  else if (command === 'delete-project') console.log(JSON.stringify(deleteProject(), null, 2));
  else if (command === 'delete-session') console.log(JSON.stringify(deleteSession(), null, 2));
  else fail(`unknown command: ${command}`);
} catch (error) {
  fail(`${command} failed: ${error && error.message ? error.message : String(error)}`);
}