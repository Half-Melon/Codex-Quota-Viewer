import { constants, mkdirSync } from "node:fs";
import {
  access,
  copyFile,
  mkdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import path from "node:path";

import type {
  AuditEntry,
  BatchSessionActionResponse,
  RestoreRequest,
  OfficialRepairResponse,
  SessionRecord,
  SessionDetail,
  SessionFilters,
  SessionTimelinePage,
} from "../../shared/contracts";
import { AppError } from "../lib/errors";
import {
  buildSessionRoots,
  ensureInsidePath,
  ensureInsideRealpath,
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
  resolveSessionRelativePath,
  uniqueSessionIds,
} from "./session-manager-helpers";
import { CodexOfficialThreadBridge } from "./codex-official-thread-bridge";
import {
  DEFAULT_TIMELINE_PAGE_SIZE,
  MAX_TIMELINE_PAGE_SIZE,
  parseSessionCatalog,
} from "./jsonl-session-parser";
import { SessionRepository } from "./session-repository";
import type { CatalogSessionEntry } from "./session-repository-model";

type ManagerConfig = {
  codexHome: string;
  managerHome: string;
};

type SessionSourceEntry = Awaited<ReturnType<typeof collectSessions>>[number];

export type SessionManager = ReturnType<typeof createSessionManager>;

export function createSessionManager(config: ManagerConfig) {
  const roots = buildSessionRoots(config.codexHome, config.managerHome);
  mkdirSync(config.managerHome, { recursive: true });
  mkdirSync(roots.archiveRoot, { recursive: true });
  mkdirSync(roots.snapshotRoot, { recursive: true });
  const repository = new SessionRepository(roots.databasePath);
  const officialThreads = new CodexOfficialThreadBridge(config.codexHome);
  let mutationQueue = Promise.resolve();

  async function rescan() {
    return enqueueMutation(async () => {
      await scanAndIndexSessions();
      return repository.listSessions();
    });
  }

  async function repairOfficialThreads(sessionIds?: string[]): Promise<OfficialRepairResponse> {
    return enqueueMutation(async () => {
      const targetIds = normalizeSessionIds(sessionIds);

      if (!targetIds) {
        const sessions = await scanAndIndexSessions();
        const stats = await officialThreads.repairSessions(sessions, {
          cleanupBroken: true,
        });

        return {
          sessions: repository.listSessions(),
          stats,
        };
      }

      const refreshed = await refreshIndexedSessions(targetIds);
      const stats =
        refreshed.records.length > 0
          ? await officialThreads.repairSessions(refreshed.records, {
              sessionIds: targetIds,
            })
          : createEmptyRepairStats();

      for (const removedId of refreshed.removedIds) {
        const removed = await officialThreads.removeSession(removedId);

        if (removed.removedThread) {
          stats.removedBrokenThreads += 1;
        }

        if (removed.removedIndex) {
          stats.updatedSessionIndexEntries += 1;
        }
      }

      return {
        sessions: repository.listSessions(),
        stats,
      };
    });
  }

  async function scanAndIndexSessions() {
    await ensureRoots();
    const [activeEntries, archivedEntries, snapshotEntries] = await Promise.all([
      collectSessions(roots.sessionsRoot),
      collectSessions(roots.archiveRoot),
      collectSessions(roots.snapshotRoot),
    ]);
    const latestAuditBySessionId = new Map(
      repository.listLatestAuditEntries().map((entry) => [entry.sessionId, entry]),
    );
    const activeById = new Map<string, SessionSourceEntry>();
    const archivedById = new Map<string, SessionSourceEntry>();
    const archivedRelativePaths = new Map<string, string>();
    const snapshotById = new Map<string, SessionSourceEntry>();

    for (const entry of activeEntries) {
      activeById.set(entry.parsed.summary.id, entry);
    }

    for (const entry of archivedEntries) {
      const { entry: normalizedEntry, originalRelativePath } = await canonicalizeArchivedEntry(
        entry,
        buildFallbackRelativePath(entry.parsed.summary.startedAt, entry.parsed.summary.id),
      );

      archivedById.set(normalizedEntry.parsed.summary.id, normalizedEntry);
      archivedRelativePaths.set(normalizedEntry.parsed.summary.id, originalRelativePath);
    }

    for (const entry of snapshotEntries) {
      snapshotById.set(entry.parsed.summary.id, entry);
    }

    const catalogEntries: CatalogSessionEntry[] = [];
    const sessionIds = new Set<string>([
      ...activeById.keys(),
      ...archivedById.keys(),
      ...snapshotById.keys(),
    ]);

    for (const sessionId of sessionIds) {
      const activeEntry = activeById.get(sessionId);
      const archivedEntry = archivedById.get(sessionId);
      const snapshotEntry = snapshotById.get(sessionId);
      const primaryEntry = activeEntry ?? archivedEntry ?? snapshotEntry;

      if (!primaryEntry) {
        continue;
      }

      const summary = primaryEntry.parsed.summary;
      const latestAudit = latestAuditBySessionId.get(sessionId);
      const activePath = activeEntry?.filePath ?? null;
      const archivePath = archivedEntry?.filePath ?? null;
      const snapshotPath = snapshotEntry?.filePath ?? null;
      const originalRelativePath =
        activeEntry
          ? path.relative(roots.sessionsRoot, activeEntry.filePath)
          : archivedRelativePaths.get(sessionId) ??
            readRelativePathFromAudit(latestAudit?.sourcePath, roots) ??
            readRelativePathFromAudit(latestAudit?.targetPath, roots) ??
            buildFallbackRelativePath(summary.startedAt, summary.id);

      catalogEntries.push({
        summary,
        timeline: primaryEntry.parsed.timeline,
        activePath,
        archivePath,
        snapshotPath,
        originalRelativePath,
        status: resolveCatalogStatus(activePath, archivePath, latestAudit?.action),
      });
    }

    return repository.replaceCatalog(catalogEntries);
  }

  async function refreshIndexedSessions(sessionIds: string[]) {
    await ensureRoots();
    const latestAuditBySessionId = new Map(
      repository.listLatestAuditEntries().map((entry) => [entry.sessionId, entry]),
    );
    const records: SessionRecord[] = [];
    const removedIds: string[] = [];

    for (const sessionId of sessionIds) {
      const existing = repository.getSession(sessionId);

      if (!existing) {
        continue;
      }

      const catalogEntry = await readCatalogEntryForSession(
        existing,
        latestAuditBySessionId.get(sessionId),
      );

      if (!catalogEntry) {
        repository.deleteSession(sessionId);
        removedIds.push(sessionId);
        continue;
      }

      records.push(repository.saveCatalogEntry(catalogEntry));
    }

    return {
      records,
      removedIds,
    };
  }

  async function readCatalogEntryForSession(
    existing: SessionRecord,
    latestAudit?: AuditEntry,
  ): Promise<CatalogSessionEntry | null> {
    const fallbackRelativePath =
      existing.originalRelativePath ??
      readRelativePathFromAudit(latestAudit?.sourcePath, roots) ??
      readRelativePathFromAudit(latestAudit?.targetPath, roots) ??
      buildFallbackRelativePath(existing.startedAt, existing.id);
    const activeEntry = await readCatalogSourceEntry(existing.id, roots.sessionsRoot, [
      existing.activePath,
      path.join(roots.sessionsRoot, fallbackRelativePath),
      latestAudit?.sourcePath,
      latestAudit?.targetPath,
    ]);
    const archived = await readArchivedCatalogSourceEntry(
      existing.id,
      fallbackRelativePath,
      [
        existing.archivePath,
        sessionArchivePath(roots.archiveRoot, fallbackRelativePath),
        latestAudit?.sourcePath,
        latestAudit?.targetPath,
      ],
    );
    const snapshotEntry = await readCatalogSourceEntry(existing.id, roots.snapshotRoot, [
      existing.snapshotPath,
      sessionSnapshotPath(roots.snapshotRoot, existing.id),
    ]);
    const primaryEntry = activeEntry ?? archived.entry ?? snapshotEntry;

    if (!primaryEntry) {
      return null;
    }

    return {
      summary: primaryEntry.parsed.summary,
      timeline: primaryEntry.parsed.timeline,
      activePath: activeEntry?.filePath ?? null,
      archivePath: archived.entry?.filePath ?? null,
      snapshotPath: snapshotEntry?.filePath ?? null,
      originalRelativePath:
        activeEntry
          ? path.relative(roots.sessionsRoot, activeEntry.filePath)
          : archived.originalRelativePath ??
            readRelativePathFromAudit(latestAudit?.sourcePath, roots) ??
            readRelativePathFromAudit(latestAudit?.targetPath, roots) ??
            buildFallbackRelativePath(
              primaryEntry.parsed.summary.startedAt,
              primaryEntry.parsed.summary.id,
            ),
      status: resolveCatalogStatus(
        activeEntry?.filePath ?? null,
        archived.entry?.filePath ?? null,
        latestAudit?.action,
      ),
    };
  }

  async function readCatalogSourceEntry(
    sessionId: string,
    root: string,
    candidates: Array<string | null | undefined>,
  ): Promise<SessionSourceEntry | null> {
    for (const candidate of uniquePaths(candidates)) {
      const filePath = await resolveManagedExistingPath(root, candidate);

      if (!filePath) {
        continue;
      }

      try {
        const parsed = await parseSessionCatalog(filePath);

        if (!parsed || parsed.summary.id !== sessionId) {
          continue;
        }

        return {
          filePath,
          parsed,
        };
      } catch {
        continue;
      }
    }

    return null;
  }

  async function readArchivedCatalogSourceEntry(
    sessionId: string,
    fallbackRelativePath: string,
    candidates: Array<string | null | undefined>,
  ): Promise<{
    entry: SessionSourceEntry | null;
    originalRelativePath: string | null;
  }> {
    for (const candidate of uniquePaths(candidates)) {
      const filePath = await resolveManagedExistingPath(roots.archiveRoot, candidate);

      if (!filePath) {
        continue;
      }

      try {
        const parsed = await parseSessionCatalog(filePath);

        if (!parsed || parsed.summary.id !== sessionId) {
          continue;
        }
        const normalized = await canonicalizeArchivedEntry(
          { filePath, parsed },
          fallbackRelativePath,
        );

        return {
          entry: normalized.entry,
          originalRelativePath: normalized.originalRelativePath,
        };
      } catch {
        continue;
      }
    }

    return {
      entry: null,
      originalRelativePath: null,
    };
  }

  async function canonicalizeArchivedEntry(
    entry: SessionSourceEntry,
    fallbackRelativePath: string,
  ): Promise<{
    entry: SessionSourceEntry;
    originalRelativePath: string;
  }> {
    const currentRelativePath = path.relative(roots.archiveRoot, entry.filePath);
    const originalRelativePath = looksCanonicalSessionRelativePath(
      currentRelativePath,
      entry.parsed.summary.id,
    )
      ? currentRelativePath
      : fallbackRelativePath;
    const archivePath = await ensureInsideRealpath(
      roots.archiveRoot,
      sessionArchivePath(roots.archiveRoot, originalRelativePath),
      { allowMissingTail: true },
    );

    if (entry.filePath !== archivePath) {
      await mkdir(path.dirname(archivePath), { recursive: true });
      await rename(entry.filePath, archivePath);
    }

    return {
      entry: {
        ...entry,
        filePath: archivePath,
      },
      originalRelativePath,
    };
  }

  async function resolveManagedExistingPath(root: string, candidate: string | null | undefined) {
    if (!candidate) {
      return null;
    }

    try {
      await ensureInsideRealpath(root, candidate);
      return path.resolve(candidate);
    } catch {
      return null;
    }
  }

  async function listSessions(filters: SessionFilters = {}) {
    return repository.listSessions(filters);
  }

  async function getSessionDetail(id: string): Promise<SessionDetail> {
    requireSession(id);
    const detail = repository.listDetails(id);
    const timelinePage = repository.listTimelinePage(id, {
      offset: 0,
      limit: DEFAULT_TIMELINE_PAGE_SIZE,
    });

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
    requireSession(id);
    return repository.listTimelinePage(id, {
      offset: options.offset,
      limit: clampTimelineLimit(options.limit),
    });
  }

  async function archiveSession(id: string): Promise<SessionRecord> {
    return enqueueMutation(() => archiveSessionUnsafe(id));
  }

  async function archiveSessionUnsafe(id: string): Promise<SessionRecord> {
    await ensureRoots();
    const record = requireSession(id);

    if (!record.activePath) {
      if (record.archivePath) {
        return record;
      }

      throw new AppError(
        409,
        "active_session_cannot_be_archived",
        "Session is not active and cannot be archived.",
      );
    }

    const sourcePath = await assertManagedPath("active", roots.sessionsRoot, record.activePath);
    const targetPath = await assertManagedPath(
      "archive",
      roots.archiveRoot,
      sessionArchivePath(roots.archiveRoot, resolveSessionRelativePath(record)),
      { allowMissingTail: true },
    );
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
    return enqueueMutation(() => deleteSessionUnsafe(id));
  }

  async function deleteSessionUnsafe(id: string): Promise<SessionRecord> {
    await ensureRoots();
    const record = requireSession(id);
    const sourcePath = await assertManagedCurrentPath(record);
    const archivePath = await assertManagedPath(
      "archive",
      roots.archiveRoot,
      sessionArchivePath(roots.archiveRoot, resolveSessionRelativePath(record)),
      { allowMissingTail: true },
    );
    const snapshotPath = record.snapshotPath
      ? await assertManagedPath("snapshot", roots.snapshotRoot, record.snapshotPath)
      : await assertManagedPath(
          "snapshot",
          roots.snapshotRoot,
          sessionSnapshotPath(roots.snapshotRoot, id),
          { allowMissingTail: true },
        );

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
    return enqueueMutation(() => restoreSessionUnsafe(request));
  }

  async function restoreSessionUnsafe(request: RestoreRequest) {
    await ensureRoots();
    const record = requireSession(request.sessionId);
    const restoreMode = normalizeRestoreMode(request.restoreMode);
    const isAlreadyActive = Boolean(record.activePath);
    const sourcePath = isAlreadyActive
      ? await assertManagedPath("active", roots.sessionsRoot, record.activePath!)
      : await assertManagedRestoreSource(record);
    const restorePath = isAlreadyActive
      ? await assertManagedPath("active", roots.sessionsRoot, record.activePath!)
      : await assertManagedPath(
          "active",
          roots.sessionsRoot,
          path.join(
            roots.sessionsRoot,
            record.originalRelativePath ??
              buildFallbackRelativePath(record.startedAt, record.id),
          ),
          { allowMissingTail: true },
        );

    if (request.targetCwd) {
      await validateRestoreTargetDirectory(request.targetCwd);
    }

    if (restoreMode === "rebind_cwd" && !request.targetCwd) {
      throw new AppError(
        400,
        "rebind_requires_target",
        "永久改目录时必须提供目标项目目录。",
      );
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

    if (restoreMode === "rebind_cwd") {
      await rewriteSessionMetaCwd(restorePath, request.targetCwd!);
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
          cwd: restoreMode === "rebind_cwd" ? request.targetCwd! : record.cwd,
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
    return enqueueMutation(() => purgeSessionUnsafe(id));
  }

  async function purgeSessionUnsafe(id: string): Promise<{ purgedId: string }> {
    await ensureRoots();
    const record = requireSession(id);

    if (record.activePath) {
      throw new AppError(
        409,
        "active_session_must_be_deleted_before_purge",
        "Active sessions must be deleted before purge.",
      );
    }

    if (record.archivePath) {
      await rm(await assertManagedPath("archive", roots.archiveRoot, record.archivePath), {
        force: true,
      });
    }

    if (record.snapshotPath) {
      await rm(await assertManagedPath("snapshot", roots.snapshotRoot, record.snapshotPath), {
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
    return enqueueMutation(() => runBatch(sessionIds, archiveSessionUnsafe));
  }

  async function batchTrashSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return enqueueMutation(() => runBatch(sessionIds, deleteSessionUnsafe));
  }

  async function batchRestoreSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return enqueueMutation(() =>
      runBatch(sessionIds, async (sessionId) => {
        const restored = await restoreSessionUnsafe({
          sessionId,
          restoreMode: "resume_only",
        });
        return restored.record;
      }),
    );
  }

  async function batchPurgeSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return enqueueMutation(async () => {
      const uniqueIds = uniqueSessionIds(sessionIds);
      const failures: BatchSessionActionResponse["failures"] = [];

      for (const sessionId of uniqueIds) {
        try {
          await purgeSessionUnsafe(sessionId);
        } catch (error) {
          failures.push(mapBatchFailure(sessionId, error));
        }
      }

      return { records: [], failures };
    });
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

  function enqueueMutation<T>(task: () => Promise<T>) {
    const next = mutationQueue.then(task, task);
    mutationQueue = next.then(
      () => undefined,
      () => undefined,
    );
    return next;
  }

  async function ensureRoots() {
    await mkdir(roots.sessionsRoot, { recursive: true });
    await mkdir(roots.archiveRoot, { recursive: true });
    await mkdir(roots.snapshotRoot, { recursive: true });
    await mkdir(config.managerHome, { recursive: true });
  }

  function requireSession(id: string) {
    const record = repository.getSession(id);
    if (!record) {
      throw new AppError(404, "unknown_session", `Unknown session: ${id}`, {
        sessionId: id,
      });
    }

    return record;
  }

  async function runBatch(
    sessionIds: string[],
    action: (sessionId: string) => Promise<SessionRecord>,
  ): Promise<BatchSessionActionResponse> {
    const uniqueIds = uniqueSessionIds(sessionIds);
    const records: SessionRecord[] = [];
    const failures: BatchSessionActionResponse["failures"] = [];

    for (const sessionId of uniqueIds) {
      try {
        records.push(await action(sessionId));
      } catch (error) {
        failures.push(mapBatchFailure(sessionId, error));
      }
    }

    return { records, failures };
  }

  async function validateRestoreTargetDirectory(targetCwd: string) {
    try {
      const targetStats = await stat(targetCwd);

      if (!targetStats.isDirectory()) {
        throw new AppError(
          400,
          "restore_target_not_directory",
          "目标项目目录不是文件夹，请重新选择目录。",
        );
      }

      if ((targetStats.mode & 0o555) === 0) {
        throw new AppError(
          400,
          "restore_target_permission_denied",
          "当前没有权限访问目标项目目录，请检查目录权限。",
        );
      }

      await access(targetCwd, constants.R_OK | constants.X_OK);
    } catch (error) {
      if (error instanceof AppError) {
        throw error;
      }

      if (isNodeErrorWithCode(error, "ENOENT")) {
        throw new AppError(
          400,
          "restore_target_missing_directory",
          "目标项目目录不存在，请先创建后再恢复。",
        );
      }

      if (isNodeErrorWithCode(error, "ENOTDIR")) {
        throw new AppError(
          400,
          "restore_target_not_directory",
          "目标项目目录不是文件夹，请重新选择目录。",
        );
      }

      if (isNodeErrorWithCode(error, "EACCES") || isNodeErrorWithCode(error, "EPERM")) {
        throw new AppError(
          400,
          "restore_target_permission_denied",
          "当前没有权限访问目标项目目录，请检查目录权限。",
        );
      }

      throw error;
    }
  }

  async function assertManagedCurrentPath(record: SessionRecord) {
    if (record.activePath) {
      return assertManagedPath("active", roots.sessionsRoot, record.activePath);
    }

    if (record.archivePath) {
      return assertManagedPath("archive", roots.archiveRoot, record.archivePath);
    }

    throw new AppError(
      409,
      "session_has_no_file_to_delete",
      "Session has no file available to delete.",
    );
  }

  async function assertManagedRestoreSource(record: SessionRecord) {
    if (record.archivePath) {
      return assertManagedPath("archive", roots.archiveRoot, record.archivePath);
    }

    if (record.snapshotPath) {
      return assertManagedPath("snapshot", roots.snapshotRoot, record.snapshotPath);
    }

    throw new AppError(
      409,
      "session_is_not_restorable",
      "Session is not restorable.",
    );
  }

  async function assertManagedPath(
    label: "active" | "archive" | "snapshot",
    root: string,
    candidate: string,
    options: {
      allowMissingTail?: boolean;
    } = {},
  ) {
    try {
      return await ensureInsideRealpath(root, candidate, options);
    } catch (error) {
      const pathDetails =
        error instanceof AppError &&
        error.details &&
        "managedRoot" in error.details &&
        typeof error.details.managedRoot === "string" &&
        "candidatePath" in error.details &&
        typeof error.details.candidatePath === "string" &&
        "resolvedCandidatePath" in error.details &&
        typeof error.details.resolvedCandidatePath === "string"
          ? {
              managedRoot: error.details.managedRoot,
              candidatePath: error.details.candidatePath,
              resolvedCandidatePath: error.details.resolvedCandidatePath,
            }
          : null;

      throw new AppError(
        400,
        "managed_session_path_outside",
        `会话 ${label} 文件路径超出了受管目录，已拒绝继续操作。`,
        {
          label,
          ...(pathDetails ?? {}),
        },
      );
    }
  }
}

function resolveCatalogStatus(
  activePath: string | null,
  archivePath: string | null,
  latestAuditAction?: string,
) {
  if (activePath) {
    return "active" as const;
  }

  if (archivePath) {
    return latestAuditAction === "delete"
      ? "deleted_pending_purge"
      : "archived";
  }

  return "restorable" as const;
}

function normalizeSessionIds(sessionIds?: string[]) {
  if (!sessionIds || sessionIds.length === 0) {
    return undefined;
  }

  const uniqueIds = uniqueSessionIds(sessionIds);
  return uniqueIds.length > 0 ? uniqueIds : undefined;
}

function uniquePaths(candidates: Array<string | null | undefined>) {
  return [...new Set(candidates.filter((candidate): candidate is string => Boolean(candidate)))];
}

function createEmptyRepairStats() {
  return {
    createdThreads: 0,
    updatedThreads: 0,
    updatedSessionIndexEntries: 0,
    removedBrokenThreads: 0,
    hiddenSnapshotOnlySessions: 0,
  };
}

function readRelativePathFromAudit(
  candidate: string | null | undefined,
  roots: ReturnType<typeof buildSessionRoots>,
) {
  if (!candidate) {
    return null;
  }

  try {
    return path.relative(
      candidate.startsWith(roots.archiveRoot) ? roots.archiveRoot : roots.sessionsRoot,
      ensureInsidePath(
        candidate.startsWith(roots.archiveRoot) ? roots.archiveRoot : roots.sessionsRoot,
        candidate,
      ),
    );
  } catch {
    return null;
  }
}

async function rewriteSessionMetaCwd(filePath: string, targetCwd: string) {
  const raw = await readFile(filePath, "utf8");
  const lines = raw.split("\n");
  let updated = false;

  const nextLines = lines.map((line) => {
    if (updated || !line.trim()) {
      return line;
    }

    try {
      const entry = JSON.parse(line) as {
        type?: unknown;
        payload?: {
          cwd?: unknown;
        };
      };

      if (entry.type !== "session_meta" || !entry.payload || typeof entry.payload !== "object") {
        return line;
      }

      entry.payload.cwd = targetCwd;
      updated = true;
      return JSON.stringify(entry);
    } catch {
      return line;
    }
  });

  if (!updated) {
    throw new Error(`Session metadata is missing from ${filePath}`);
  }

  await writeFile(filePath, nextLines.join("\n"));
}

function mapBatchFailure(sessionId: string, error: unknown) {
  if (error instanceof AppError) {
    return {
      sessionId,
      code: error.code,
      error: error.message,
      details: error.details,
    };
  }

  return {
    sessionId,
    error: error instanceof Error ? error.message : "Unknown error",
  };
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

  throw new AppError(
    400,
    "unsupported_restore_mode",
    "不支持的恢复模式，请刷新页面后重试。",
  );
}

function clampTimelineLimit(limit: number | undefined) {
  if (typeof limit !== "number" || !Number.isFinite(limit)) {
    return DEFAULT_TIMELINE_PAGE_SIZE;
  }

  return Math.min(Math.max(Math.trunc(limit), 1), MAX_TIMELINE_PAGE_SIZE);
}
