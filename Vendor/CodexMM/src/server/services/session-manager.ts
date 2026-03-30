import { constants, mkdirSync } from "node:fs";
import { access, copyFile, mkdir, rename, rm, stat } from "node:fs/promises";
import path from "node:path";

import type {
  BatchSessionActionResponse,
  OfficialRepairResponse,
  RestoreRequest,
  SessionDetail,
  SessionFilters,
  SessionRecord,
  SessionTimelinePage,
} from "../../shared/contracts";
import { AppError } from "../lib/errors";
import {
  buildSessionRoots,
  ensureInsidePath,
  sessionArchivePath,
  sessionSnapshotPath,
} from "../lib/paths";
import { launchResumeCommand } from "./launch-resume";
import {
  buildFallbackRelativePath,
  buildResumeCommand,
  collectSessions,
  copyIfMissing,
  looksCanonicalSessionRelativePath,
  pathExists,
  resolveSessionRelativePath,
} from "./session-manager-helpers";
import { CodexOfficialThreadBridge } from "./codex-official-thread-bridge";
import {
  DEFAULT_TIMELINE_PAGE_SIZE,
  MAX_TIMELINE_PAGE_SIZE,
  parseSessionTimelinePage,
} from "./jsonl-session-parser";
import { SessionRepository } from "./session-repository";

type ManagerConfig = {
  codexHome: string;
  managerHome: string;
};

export type SessionManager = ReturnType<typeof createSessionManager>;

export function createSessionManager(config: ManagerConfig) {
  const roots = buildSessionRoots(config.codexHome, config.managerHome);
  mkdirSync(config.managerHome, { recursive: true });
  mkdirSync(roots.archiveRoot, { recursive: true });
  mkdirSync(roots.snapshotRoot, { recursive: true });
  const repository = new SessionRepository(roots.databasePath);
  const officialThreads = new CodexOfficialThreadBridge(config.codexHome);

  async function rescan() {
    await scanAndIndexSessions();
    return repository.listSessions();
  }

  async function repairOfficialThreads(sessionIds?: string[]): Promise<OfficialRepairResponse> {
    const targetIds = sessionIds && sessionIds.length > 0 ? sessionIds : undefined;
    const sessions = await scanAndIndexSessions();
    const stats = await officialThreads.repairSessions(sessions, {
      sessionIds: targetIds,
      cleanupBroken: !targetIds,
    });

    return {
      sessions: repository.listSessions(),
      stats,
    };
  }

  async function scanAndIndexSessions() {
    await ensureRoots();
    const activeEntries = await collectSessions(roots.sessionsRoot);
    const archivedEntries = await collectSessions(roots.archiveRoot);
    const seenIds = new Set<string>();

    for (const entry of activeEntries) {
      seenIds.add(entry.summary.id);
      repository.upsertSession(entry.summary, {
        activePath: entry.filePath,
        archivePath: null,
        originalRelativePath: path.relative(roots.sessionsRoot, entry.filePath),
        status: "active",
      });
    }

    for (const entry of archivedEntries) {
      seenIds.add(entry.summary.id);
      const existing = repository.getSession(entry.summary.id);
      const currentRelativePath = path.relative(roots.archiveRoot, entry.filePath);
      const originalRelativePath =
        existing?.originalRelativePath ??
        (looksCanonicalSessionRelativePath(currentRelativePath, entry.summary.id)
          ? currentRelativePath
          : buildFallbackRelativePath(entry.summary.startedAt, entry.summary.id));
      const archivePath = sessionArchivePath(roots.archiveRoot, originalRelativePath);

      if (entry.filePath !== archivePath) {
        await mkdir(path.dirname(archivePath), { recursive: true });
        await rename(entry.filePath, archivePath);
      }

      repository.upsertSession(entry.summary, {
        activePath: null,
        archivePath,
        originalRelativePath,
        status:
          existing?.status === "deleted_pending_purge"
            ? "deleted_pending_purge"
            : "archived",
      });
    }

    for (const { id } of repository.listAllIds()) {
      if (!seenIds.has(id)) {
        await markMissingState(id);
      }
    }

    return repository.listSessions();
  }

  async function listSessions(filters: SessionFilters = {}) {
    return repository.listSessions(filters);
  }

  async function getSessionDetail(id: string): Promise<SessionDetail> {
    const detail = repository.listDetails(id);
    const filePath =
      detail.record.activePath ??
      detail.record.archivePath ??
      detail.record.snapshotPath;
    const timelinePage = filePath
      ? await parseSessionTimelinePage(filePath, {
          offset: 0,
          limit: DEFAULT_TIMELINE_PAGE_SIZE,
        })
      : { items: [], total: 0, nextOffset: null };

    return {
      ...detail,
      timeline: timelinePage.items,
      timelineTotal: timelinePage.total,
      timelineNextOffset: timelinePage.nextOffset,
      officialState: await officialThreads.inspectSession(detail.record),
    };
  }

  async function getSessionTimelinePage(
    id: string,
    options: {
      offset?: number;
      limit?: number;
    } = {},
  ): Promise<SessionTimelinePage> {
    const record = requireSession(id);
    const filePath = record.activePath ?? record.archivePath ?? record.snapshotPath;

    if (!filePath) {
      return {
        items: [],
        total: 0,
        nextOffset: null,
      };
    }

    return parseSessionTimelinePage(filePath, {
      offset: options.offset,
      limit: clampTimelineLimit(options.limit),
    });
  }

  async function archiveSession(id: string): Promise<SessionRecord> {
    await ensureRoots();
    const record = requireSession(id);

    if (!record.activePath) {
      if (record.archivePath) {
        return record;
      }
      throw new AppError(409, "Session is not active and cannot be archived.");
    }

    const sourcePath = ensureInsidePath(roots.sessionsRoot, record.activePath);
    const targetPath = sessionArchivePath(roots.archiveRoot, resolveSessionRelativePath(record));
    await mkdir(path.dirname(targetPath), { recursive: true });
    await rename(sourcePath, targetPath);

    const next = repository.updateSession(id, {
      activePath: null,
      archivePath: targetPath,
      status: "archived",
    });
    await officialThreads.repairSessions([next]);

    repository.insertAudit("archive", id, sourcePath, targetPath);
    return next;
  }

  async function deleteSession(id: string): Promise<SessionRecord> {
    await ensureRoots();
    const record = requireSession(id);
    const sourcePath = assertManagedCurrentPath(record);
    const archivePath = ensureInsidePath(
      roots.archiveRoot,
      sessionArchivePath(roots.archiveRoot, resolveSessionRelativePath(record)),
    );
    const snapshotPath =
      record.snapshotPath
        ? assertManagedPath("snapshot", roots.snapshotRoot, record.snapshotPath)
        : ensureInsidePath(roots.snapshotRoot, sessionSnapshotPath(roots.snapshotRoot, id));

    await mkdir(path.dirname(snapshotPath), { recursive: true });
    await copyIfMissing(sourcePath, snapshotPath);

    if (sourcePath !== archivePath) {
      await mkdir(path.dirname(archivePath), { recursive: true });
      await rename(sourcePath, archivePath);
    }

    const next = repository.updateSession(id, {
      activePath: null,
      archivePath,
      snapshotPath,
      status: "deleted_pending_purge",
    });
    await officialThreads.repairSessions([next]);

    repository.insertAudit("delete", id, sourcePath, archivePath, {
      snapshotPath,
    });
    return next;
  }

  async function restoreSession(request: RestoreRequest) {
    await ensureRoots();
    const record = requireSession(request.sessionId);
    const restoreMode = normalizeRestoreMode(request.restoreMode);
    const isAlreadyActive = Boolean(record.activePath);
    const sourcePath = isAlreadyActive
      ? assertManagedPath("active", roots.sessionsRoot, record.activePath!)
      : assertManagedRestoreSource(record);
    const restorePath = isAlreadyActive
      ? assertManagedPath("active", roots.sessionsRoot, record.activePath!)
      : ensureInsidePath(
          roots.sessionsRoot,
          path.join(
            roots.sessionsRoot,
            record.originalRelativePath ??
              buildFallbackRelativePath(record.startedAt, record.id),
          ),
        );

    if (request.targetCwd) {
      await validateRestoreTargetDirectory(request.targetCwd);
    }

    if (restoreMode === "rebind_cwd" && !request.targetCwd) {
      throw new AppError(400, "永久改目录时必须提供目标项目目录。");
    }

    if (!isAlreadyActive) {
      await mkdir(path.dirname(restorePath), { recursive: true });

      if (sourcePath !== restorePath) {
        if (sourcePath === record.archivePath) {
          await rename(sourcePath, restorePath);
        } else {
          await copyFile(sourcePath, restorePath);
        }
      }
    }

    const next = isAlreadyActive
      ? restoreMode === "rebind_cwd"
        ? repository.updateSession(record.id, {
            cwd: request.targetCwd!,
          })
        : record
      : repository.updateSession(record.id, {
          activePath: restorePath,
          archivePath: sourcePath === record.archivePath ? null : record.archivePath,
          cwd:
            restoreMode === "rebind_cwd"
              ? request.targetCwd!
              : record.cwd,
          status: "active",
        });
    await officialThreads.repairSessions([next]);

    const resumeCommand = buildResumeCommand(
      record.id,
      restoreMode === "resume_only" ? request.targetCwd : undefined,
    );
    let launched = false;

    if (request.launch) {
      launched = await launchResumeCommand(resumeCommand);
    }

    repository.insertAudit("restore", record.id, sourcePath, restorePath, {
      targetCwd: request.targetCwd ?? null,
      restoreMode,
      launched,
    });

    return { record: next, resumeCommand, launched };
  }

  async function purgeSession(id: string): Promise<{ purgedId: string }> {
    await ensureRoots();
    const record = requireSession(id);

    if (record.activePath) {
      throw new AppError(409, "Active sessions must be deleted before purge.");
    }

    if (record.archivePath) {
      await rm(assertManagedPath("archive", roots.archiveRoot, record.archivePath), {
        force: true,
      });
    }

    if (record.snapshotPath) {
      await rm(assertManagedPath("snapshot", roots.snapshotRoot, record.snapshotPath), {
        force: true,
      });
    }

    repository.insertAudit("purge", id, record.archivePath, null, {
      snapshotPath: record.snapshotPath,
    });
    await officialThreads.removeSession(id);
    repository.deleteSession(id);
    return { purgedId: id };
  }

  async function batchArchiveSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return runBatch(sessionIds, (sessionId) => archiveSession(sessionId));
  }

  async function batchTrashSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return runBatch(sessionIds, (sessionId) => deleteSession(sessionId));
  }

  async function batchRestoreSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return runBatch(sessionIds, async (sessionId) => {
      const restored = await restoreSession({
        sessionId,
        restoreMode: "resume_only",
      });
      return restored.record;
    });
  }

  async function batchPurgeSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    const uniqueIds = [...new Set(sessionIds.filter(Boolean))];
    const failures: BatchSessionActionResponse["failures"] = [];

    for (const sessionId of uniqueIds) {
      try {
        await purgeSession(sessionId);
      } catch (error) {
        failures.push({
          sessionId,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    }

    return { records: [], failures };
  }

  return {
    rescan,
    listSessions,
    getSessionDetail,
    getSessionTimelinePage,
    archiveSession,
    deleteSession,
    restoreSession,
    purgeSession,
    batchArchiveSessions,
    batchTrashSessions,
    batchRestoreSessions,
    batchPurgeSessions,
    repairOfficialThreads,
  };

  async function ensureRoots() {
    await mkdir(roots.sessionsRoot, { recursive: true });
    await mkdir(roots.archiveRoot, { recursive: true });
    await mkdir(roots.snapshotRoot, { recursive: true });
    await mkdir(config.managerHome, { recursive: true });
  }

  async function markMissingState(id: string) {
    const record = requireSession(id);
    const hasSnapshot = await pathExists(record.snapshotPath);

    if (hasSnapshot) {
      repository.updateSession(id, {
        activePath: null,
        archivePath: null,
        status: "restorable",
      });
      return;
    }

    repository.deleteSession(id);
  }

  function requireSession(id: string) {
    const record = repository.getSession(id);
    if (!record) {
      throw new AppError(404, `Unknown session: ${id}`);
    }

    return record;
  }

  async function runBatch(
    sessionIds: string[],
    action: (sessionId: string) => Promise<SessionRecord>,
  ): Promise<BatchSessionActionResponse> {
    const uniqueIds = [...new Set(sessionIds.filter(Boolean))];
    const records: SessionRecord[] = [];
    const failures: BatchSessionActionResponse["failures"] = [];

    for (const sessionId of uniqueIds) {
      try {
        records.push(await action(sessionId));
      } catch (error) {
        failures.push({
          sessionId,
          error: error instanceof Error ? error.message : "Unknown error",
        });
      }
    }

    return { records, failures };
  }

  async function validateRestoreTargetDirectory(targetCwd: string) {
    try {
      const targetStats = await stat(targetCwd);

      if (!targetStats.isDirectory()) {
        throw new AppError(400, "目标项目目录不是文件夹，请重新选择目录。");
      }

      if ((targetStats.mode & 0o555) === 0) {
        throw new AppError(400, "当前没有权限访问目标项目目录，请检查目录权限。");
      }

      await access(targetCwd, constants.R_OK | constants.X_OK);
    } catch (error) {
      if (error instanceof AppError) {
        throw error;
      }

      if (isNodeErrorWithCode(error, "ENOENT")) {
        throw new AppError(400, "目标项目目录不存在，请先创建后再恢复。");
      }

      if (isNodeErrorWithCode(error, "ENOTDIR")) {
        throw new AppError(400, "目标项目目录不是文件夹，请重新选择目录。");
      }

      if (isNodeErrorWithCode(error, "EACCES") || isNodeErrorWithCode(error, "EPERM")) {
        throw new AppError(400, "当前没有权限访问目标项目目录，请检查目录权限。");
      }

      throw error;
    }
  }

  function assertManagedCurrentPath(record: SessionRecord) {
    if (record.activePath) {
      return assertManagedPath("active", roots.sessionsRoot, record.activePath);
    }

    if (record.archivePath) {
      return assertManagedPath("archive", roots.archiveRoot, record.archivePath);
    }

    throw new AppError(409, "Session has no file available to delete.");
  }

  function assertManagedRestoreSource(record: SessionRecord) {
    if (record.archivePath) {
      return assertManagedPath("archive", roots.archiveRoot, record.archivePath);
    }

    if (record.snapshotPath) {
      return assertManagedPath("snapshot", roots.snapshotRoot, record.snapshotPath);
    }

    throw new AppError(409, "Session is not restorable.");
  }

  function assertManagedPath(
    label: "active" | "archive" | "snapshot",
    root: string,
    candidate: string,
  ) {
    try {
      return ensureInsidePath(root, candidate);
    } catch {
      throw new AppError(400, `会话 ${label} 文件路径超出了受管目录，已拒绝继续操作。`);
    }
  }
}

function isNodeErrorWithCode(error: unknown, code: string) {
  return (
    error instanceof Error &&
    "code" in error &&
    (error as Error & { code?: unknown }).code === code
  );
}

function normalizeRestoreMode(value: RestoreRequest["restoreMode"]) {
  if (value === "resume_only") {
    return "resume_only" as const;
  }

  if (value === "rebind_cwd") {
    return "rebind_cwd" as const;
  }

  throw new AppError(400, "不支持的恢复模式，请刷新页面后重试。");
}

function clampTimelineLimit(limit: number | undefined) {
  if (typeof limit !== "number" || !Number.isFinite(limit)) {
    return DEFAULT_TIMELINE_PAGE_SIZE;
  }

  return Math.min(Math.max(Math.trunc(limit), 1), MAX_TIMELINE_PAGE_SIZE);
}
