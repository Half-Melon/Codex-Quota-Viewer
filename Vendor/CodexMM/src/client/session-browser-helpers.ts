import type {
  ApiErrorCode,
  OfficialRepairStats,
  SessionFilters,
  SessionOfficialState,
  SessionRecord,
  SessionStatus,
} from "../shared/contracts";
import type { AuditActionKey, RestoreTargetErrorKey, TranslationSet } from "./i18n";

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

const RESTORE_TARGET_ERROR_CODES = new Set<ApiErrorCode>([
  "restore_target_missing_directory",
  "restore_target_not_directory",
  "restore_target_permission_denied",
]);

const STATIC_ERROR_LOCALIZERS: Array<{
  codes?: ApiErrorCode[];
  messages?: string[];
  localize: (copy: TranslationSet) => string;
}> = [
  {
    codes: ["active_session_cannot_be_archived"],
    messages: ["Session is not active and cannot be archived."],
    localize: (copy: TranslationSet) => copy.errors.activeSessionCannotBeArchived,
  },
  {
    codes: ["rebind_requires_target"],
    messages: ["永久改目录时必须提供目标项目目录。"],
    localize: (copy: TranslationSet) => copy.errors.rebindRequiresTarget,
  },
  {
    codes: ["active_session_must_be_deleted_before_purge"],
    messages: ["Active sessions must be deleted before purge."],
    localize: (copy: TranslationSet) => copy.errors.activeSessionMustBeDeletedBeforePurge,
  },
  {
    codes: ["session_has_no_file_to_delete"],
    messages: ["Session has no file available to delete."],
    localize: (copy: TranslationSet) => copy.errors.sessionHasNoFileToDelete,
  },
  {
    codes: ["session_is_not_restorable"],
    messages: ["Session is not restorable."],
    localize: (copy: TranslationSet) => copy.errors.sessionIsNotRestorable,
  },
  {
    codes: ["unsupported_restore_mode"],
    messages: ["不支持的恢复模式，请刷新页面后重试。"],
    localize: (copy: TranslationSet) => copy.errors.unsupportedRestoreMode,
  },
  {
    codes: ["internal_server_error", "unknown_server_error"],
    messages: ["Unknown server error"],
    localize: (copy: TranslationSet) => copy.errors.unknown,
  },
];

const UNKNOWN_SESSION_PATTERN = /^Unknown session: (.+)$/;
const MANAGED_SESSION_PATH_PATTERN =
  /^会话 (active|archive|snapshot) 文件路径超出了受管目录，已拒绝继续操作。$/;
const OUTSIDE_MANAGED_ROOT_PATTERN = /^Path is outside managed root: (.+)$/;

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

export function isRestoreTargetError(error: unknown) {
  const code = readErrorCode(error);
  if (code && RESTORE_TARGET_ERROR_CODES.has(code)) {
    return true;
  }

  const message = readErrorMessage(error);
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
  return localizeKnownMessage(readErrorMessage(error), copy, readErrorCode(error));
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

export function localizeKnownMessage(
  message: string,
  copy: TranslationSet,
  code?: ApiErrorCode,
) {
  const localizedRestoreTargetByCode = localizeRestoreTargetErrorByCode(code, copy);

  if (localizedRestoreTargetByCode) {
    return localizedRestoreTargetByCode;
  }

  const localizedRestoreTarget = localizeRestoreTargetError(message, copy);

  if (localizedRestoreTarget !== message) {
    return localizedRestoreTarget;
  }

  for (const entry of STATIC_ERROR_LOCALIZERS) {
    if ((code && entry.codes?.includes(code)) || entry.messages?.includes(message)) {
      return entry.localize(copy);
    }
  }

  const unknownSessionMatch = message.match(UNKNOWN_SESSION_PATTERN);

  if (unknownSessionMatch) {
    return copy.errors.unknownSession(unknownSessionMatch[1]!);
  }

  const managedSessionPathMatch = message.match(MANAGED_SESSION_PATH_PATTERN);

  if (managedSessionPathMatch) {
    return copy.errors.managedSessionPathOutside(managedSessionPathMatch[1]!);
  }

  const outsideManagedRootMatch = message.match(OUTSIDE_MANAGED_ROOT_PATTERN);

  if (outsideManagedRootMatch) {
    return copy.errors.pathOutsideManagedRoot(outsideManagedRootMatch[1]!);
  }

  return message;
}

function localizeRestoreTargetErrorByCode(
  code: ApiErrorCode | undefined,
  copy: TranslationSet,
) {
  switch (code) {
    case "restore_target_missing_directory":
      return copy.errors.restoreTarget.missingDirectory;
    case "restore_target_not_directory":
      return copy.errors.restoreTarget.notDirectory;
    case "restore_target_permission_denied":
      return copy.errors.restoreTarget.permissionDenied;
    default:
      return null;
  }
}

function readErrorCode(error: unknown) {
  return error instanceof Error &&
    "code" in error &&
    typeof (error as Error & { code?: unknown }).code === "string"
    ? ((error as Error & { code: ApiErrorCode }).code)
    : undefined;
}

function readErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Unknown server error";
}

export function describeOfficialState(
  officialState: SessionOfficialState,
  copy: TranslationSet,
) {
  const issues = officialState.canAppearInCodex
    ? buildVisibleOfficialIssues(officialState, copy)
    : buildHiddenOfficialIssues(officialState, copy);

  const summary = officialState.canAppearInCodex
    ? issues.length > 0
      ? copy.detail.officialSummaryRepairNeeded
      : copy.detail.officialSummarySynced
    : issues.length > 0
      ? copy.detail.officialSummaryHiddenRepairNeeded
      : copy.detail.officialSummaryHidden;

  return { summary, issues };
}

export function localizeAuditAction(
  action: string,
  copy: TranslationSet,
) {
  return copy.detail.auditActions[action as AuditActionKey] ?? action;
}

function buildVisibleOfficialIssues(
  officialState: SessionOfficialState,
  copy: TranslationSet,
) {
  return [
    !officialState.threadRowPresent ? copy.detail.officialIssueMissingThread : null,
    officialState.threadRowPresent && !officialState.rolloutPathMatches
      ? copy.detail.officialIssueWrongRolloutPath
      : null,
    officialState.threadRowPresent && !officialState.archivedFlagMatches
      ? copy.detail.officialIssueArchivedFlagMismatch
      : null,
    !officialState.sessionIndexPresent
      ? copy.detail.officialIssueMissingRecentConversation
      : null,
    officialState.sessionIndexPresent && !officialState.sessionIndexMatches
      ? copy.detail.officialIssueStaleRecentConversation
      : null,
  ].filter((issue): issue is string => Boolean(issue));
}

function buildHiddenOfficialIssues(
  officialState: SessionOfficialState,
  copy: TranslationSet,
) {
  return [
    officialState.threadRowPresent
      ? copy.detail.officialIssueSnapshotThreadStillPresent
      : null,
    officialState.sessionIndexPresent
      ? copy.detail.officialIssueSnapshotRecentConversationStillPresent
      : null,
  ].filter((issue): issue is string => Boolean(issue));
}
