import type {
  OfficialRepairStats,
  SessionFilters,
  SessionRecord,
  SessionStatus,
} from "../shared/contracts";
import type {
  RestoreTargetErrorKey,
  TranslationSet,
} from "./i18n";

const RESTORE_TARGET_ERROR_KEYS = new Map<string, RestoreTargetErrorKey>([
  ["目标项目目录不存在，请先创建后再恢复。", "missingDirectory"],
  ["The target project directory does not exist. Create it before restoring.", "missingDirectory"],
  ["目标项目目录不是文件夹，请重新选择目录。", "notDirectory"],
  ["The target project path is not a directory. Choose a directory instead.", "notDirectory"],
  ["当前没有权限访问目标项目目录，请检查目录权限。", "permissionDenied"],
  [
    "Permission denied for the target project directory. Check the directory permissions.",
    "permissionDenied",
  ],
]);

export function mergeSessionList(
  current: SessionRecord[],
  recordMap: Map<string, SessionRecord>,
) {
  return current.map((session) => recordMap.get(session.id) ?? session);
}

export function buildFilters(
  search: string,
  status: SessionStatus,
): SessionFilters {
  const query = search.trim();

  return {
    query: query.length > 0 ? query : undefined,
    status,
  };
}

export function filterVisibleSessions(
  sessions: SessionRecord[],
  search: string,
  status: SessionStatus,
) {
  const normalizedQuery = search.trim().toLowerCase();
  const visible = filterSessionsByStatus(sessions, status);

  if (!normalizedQuery) {
    return visible;
  }

  return visible.filter((session) =>
    [
      session.id,
      session.cwd,
      session.userPromptExcerpt,
      session.latestAgentMessageExcerpt,
    ].some((value) => value.toLowerCase().includes(normalizedQuery)),
  );
}

export function isArchivedViewStatus(status: SessionStatus) {
  return status === "archived" || status === "restorable";
}

export function isRestoreTargetError(message: string) {
  return RESTORE_TARGET_ERROR_KEYS.has(message);
}

export function buildOfficialRepairFeedback(
  stats: OfficialRepairStats,
  copy: TranslationSet,
) {
  const touchedCount =
    stats.createdThreads +
    stats.updatedThreads +
    stats.updatedSessionIndexEntries +
    stats.removedBrokenThreads +
    stats.hiddenSnapshotOnlySessions;

  if (touchedCount === 0) {
    return copy.repairFeedback.alreadySynced;
  }

  const parts = [
    stats.createdThreads > 0
      ? copy.repairFeedback.createdThreads(stats.createdThreads)
      : null,
    stats.updatedThreads > 0
      ? copy.repairFeedback.updatedThreads(stats.updatedThreads)
      : null,
    stats.updatedSessionIndexEntries > 0
      ? copy.repairFeedback.updatedSessionIndexEntries(stats.updatedSessionIndexEntries)
      : null,
    stats.removedBrokenThreads > 0
      ? copy.repairFeedback.removedBrokenThreads(stats.removedBrokenThreads)
      : null,
    stats.hiddenSnapshotOnlySessions > 0
      ? copy.repairFeedback.hiddenSnapshotOnlySessions(stats.hiddenSnapshotOnlySessions)
      : null,
  ].filter((part): part is string => Boolean(part));

  return copy.repairFeedback.summary(parts);
}

export function readError(error: unknown, copy: TranslationSet) {
  const message = error instanceof Error ? error.message : copy.errors.unknown;

  return localizeRestoreTargetError(message, copy);
}

export function readMediaQueryMatch(query: string) {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return false;
  }

  return window.matchMedia(query).matches;
}

function filterSessionsByStatus(
  sessions: SessionRecord[],
  status: SessionStatus,
) {
  return sessions.filter((session) =>
    status === "archived" ? isArchivedViewStatus(session.status) : session.status === status,
  );
}

function localizeRestoreTargetError(message: string, copy: TranslationSet) {
  const key = RESTORE_TARGET_ERROR_KEYS.get(message);
  return key ? copy.errors.restoreTarget[key] : message;
}
