import type {
  ApiErrorCode,
  ApiErrorDetails,
  OfficialRepairStats,
  SessionFilters,
  SessionOfficialIssueCode,
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

const STATIC_ERROR_LOCALIZERS: Partial<Record<ApiErrorCode, (copy: TranslationSet) => string>> = {
  active_session_cannot_be_archived: (copy) => copy.errors.activeSessionCannotBeArchived,
  rebind_requires_target: (copy) => copy.errors.rebindRequiresTarget,
  active_session_must_be_deleted_before_purge: (copy) =>
    copy.errors.activeSessionMustBeDeletedBeforePurge,
  session_has_no_file_to_delete: (copy) => copy.errors.sessionHasNoFileToDelete,
  session_is_not_restorable: (copy) => copy.errors.sessionIsNotRestorable,
  unsupported_restore_mode: (copy) => copy.errors.unsupportedRestoreMode,
  internal_server_error: (copy) => copy.errors.unknown,
  unknown_server_error: (copy) => copy.errors.unknown,
};

const STATIC_LEGACY_MESSAGE_LOCALIZERS = new Map<string, (copy: TranslationSet) => string>([
  ["Session is not active and cannot be archived.", (copy) => copy.errors.activeSessionCannotBeArchived],
  ["永久改目录时必须提供目标项目目录。", (copy) => copy.errors.rebindRequiresTarget],
  ["Active sessions must be deleted before purge.", (copy) => copy.errors.activeSessionMustBeDeletedBeforePurge],
  ["Session has no file available to delete.", (copy) => copy.errors.sessionHasNoFileToDelete],
  ["Session is not restorable.", (copy) => copy.errors.sessionIsNotRestorable],
  ["不支持的恢复模式，请刷新页面后重试。", (copy) => copy.errors.unsupportedRestoreMode],
  ["Unknown server error", (copy) => copy.errors.unknown],
]);

const UNKNOWN_SESSION_PATTERN = /^Unknown session: (.+)$/;
const MANAGED_SESSION_PATH_PATTERN =
  /^会话 (active|archive|snapshot) 文件路径超出了受管目录，已拒绝继续操作。$/;
const OUTSIDE_MANAGED_ROOT_PATTERN = /^Path is outside managed root: (.+)$/;
export const NARROW_VIEWPORT_MEDIA_QUERY = "(max-width: 767px)";
const TRASHABLE_SESSION_STATUSES = new Set<SessionStatus>(["active", "archived"]);
const RESTORABLE_SESSION_STATUSES = new Set<SessionStatus>([
  "archived",
  "deleted_pending_purge",
  "restorable",
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

export function canTrashSessionStatus(status: SessionStatus) {
  return TRASHABLE_SESSION_STATUSES.has(status);
}

export function canRestoreSessionStatus(status: SessionStatus) {
  return RESTORABLE_SESSION_STATUSES.has(status);
}

export function canResumeSessionStatus(status: SessionStatus) {
  return status === "active" || canRestoreSessionStatus(status);
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
  return localizeKnownMessage(
    readErrorMessage(error),
    copy,
    readErrorCode(error),
    readErrorDetails(error),
  );
}

export function readMediaQueryMatch(query: string) {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return false;
  }

  return window.matchMedia(query).matches;
}

export function subscribeMediaQuery(
  query: string,
  onMatchChange: (matches: boolean) => void,
) {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    onMatchChange(false);
    return () => {};
  }

  const mediaQuery = window.matchMedia(query);
  const handleChange = () => {
    onMatchChange(mediaQuery.matches);
  };

  handleChange();
  mediaQuery.addEventListener("change", handleChange);

  return () => {
    mediaQuery.removeEventListener("change", handleChange);
  };
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
  details?: ApiErrorDetails,
) {
  const localizedByCode = localizeKnownMessageByCode(code, details, message, copy);
  if (localizedByCode) {
    return localizedByCode;
  }

  const localizedRestoreTarget = localizeRestoreTargetError(message, copy);
  if (localizedRestoreTarget !== message) {
    return localizedRestoreTarget;
  }

  const localizedStatic = STATIC_LEGACY_MESSAGE_LOCALIZERS.get(message);
  if (localizedStatic) {
    return localizedStatic(copy);
  }

  const localizedDynamic = localizeDynamicErrorFromLegacyMessage(message, copy);
  return localizedDynamic ?? message;
}

function localizeKnownMessageByCode(
  code: ApiErrorCode | undefined,
  details: ApiErrorDetails | undefined,
  message: string,
  copy: TranslationSet,
) {
  switch (code) {
    case "restore_target_missing_directory":
      return copy.errors.restoreTarget.missingDirectory;
    case "restore_target_not_directory":
      return copy.errors.restoreTarget.notDirectory;
    case "restore_target_permission_denied":
      return copy.errors.restoreTarget.permissionDenied;
    case "unknown_session":
      return localizeUnknownSession(details, message, copy);
    case "managed_session_path_outside":
      return localizeManagedSessionPathOutside(details, message, copy);
    case "path_outside_managed_root":
      return localizePathOutsideManagedRoot(details, message, copy);
    default:
      return code ? (STATIC_ERROR_LOCALIZERS[code]?.(copy) ?? null) : null;
  }
}

function localizeDynamicErrorFromLegacyMessage(
  message: string,
  copy: TranslationSet,
) {
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

  return null;
}

function localizeUnknownSession(
  details: ApiErrorDetails | undefined,
  message: string,
  copy: TranslationSet,
) {
  const sessionIdFromDetails =
    typeof details?.sessionId === "string" ? details.sessionId : null;
  const sessionId = sessionIdFromDetails ?? message.match(UNKNOWN_SESSION_PATTERN)?.[1] ?? null;

  return sessionId ? copy.errors.unknownSession(sessionId) : null;
}

function localizeManagedSessionPathOutside(
  details: ApiErrorDetails | undefined,
  message: string,
  copy: TranslationSet,
) {
  const labelFromDetails =
    details?.label === "active" || details?.label === "archive" || details?.label === "snapshot"
      ? details.label
      : null;
  const label = labelFromDetails ?? message.match(MANAGED_SESSION_PATH_PATTERN)?.[1] ?? null;

  return label ? copy.errors.managedSessionPathOutside(label) : null;
}

function localizePathOutsideManagedRoot(
  details: ApiErrorDetails | undefined,
  message: string,
  copy: TranslationSet,
) {
  const candidateFromDetails =
    typeof details?.candidatePath === "string" ? details.candidatePath : null;
  const candidate = candidateFromDetails ?? message.match(OUTSIDE_MANAGED_ROOT_PATTERN)?.[1] ?? null;

  return candidate ? copy.errors.pathOutsideManagedRoot(candidate) : null;
}

function readErrorCode(error: unknown) {
  return error instanceof Error &&
    "code" in error &&
    typeof (error as Error & { code?: unknown }).code === "string"
    ? ((error as Error & { code: ApiErrorCode }).code)
    : undefined;
}

function readErrorDetails(error: unknown): ApiErrorDetails | undefined {
  if (!(error instanceof Error) || !("details" in error)) {
    return undefined;
  }

  const details = (error as Error & { details?: unknown }).details;
  if (!details || typeof details !== "object") {
    return undefined;
  }

  const normalized: ApiErrorDetails = {};

  if (typeof (details as { sessionId?: unknown }).sessionId === "string") {
    normalized.sessionId = (details as { sessionId: string }).sessionId;
  }

  const label = (details as { label?: unknown }).label;
  if (label === "active" || label === "archive" || label === "snapshot") {
    normalized.label = label;
  }

  if (typeof (details as { managedRoot?: unknown }).managedRoot === "string") {
    normalized.managedRoot = (details as { managedRoot: string }).managedRoot;
  }

  if (typeof (details as { candidatePath?: unknown }).candidatePath === "string") {
    normalized.candidatePath = (details as { candidatePath: string }).candidatePath;
  }

  if (typeof (details as { resolvedCandidatePath?: unknown }).resolvedCandidatePath === "string") {
    normalized.resolvedCandidatePath = (
      details as { resolvedCandidatePath: string }
    ).resolvedCandidatePath;
  }

  return Object.keys(normalized).length > 0 ? normalized : undefined;
}

function readErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Unknown server error";
}

export function describeOfficialState(
  officialState: SessionOfficialState,
  copy: TranslationSet,
) {
  const issues = officialState.issueCodes.map((issueCode) =>
    localizeOfficialIssue(issueCode, copy),
  );

  const summary = localizeOfficialSummary(officialState, copy);

  return { summary, issues };
}

export function localizeAuditAction(
  action: string,
  copy: TranslationSet,
) {
  return copy.detail.auditActions[action as AuditActionKey] ?? action;
}

function localizeOfficialSummary(
  officialState: SessionOfficialState,
  copy: TranslationSet,
) {
  if (!officialState.canAppearInCodex) {
    return officialState.status === "repair_needed"
      ? copy.detail.officialSummaryHiddenRepairNeeded
      : copy.detail.officialSummaryHidden;
  }

  return officialState.status === "repair_needed"
    ? copy.detail.officialSummaryRepairNeeded
    : copy.detail.officialSummarySynced;
}

function localizeOfficialIssue(
  issueCode: SessionOfficialIssueCode,
  copy: TranslationSet,
) {
  switch (issueCode) {
    case "missing_thread":
      return copy.detail.officialIssueMissingThread;
    case "wrong_rollout_path":
      return copy.detail.officialIssueWrongRolloutPath;
    case "archived_flag_mismatch":
      return copy.detail.officialIssueArchivedFlagMismatch;
    case "missing_recent_conversation":
      return copy.detail.officialIssueMissingRecentConversation;
    case "stale_recent_conversation":
      return copy.detail.officialIssueStaleRecentConversation;
    case "snapshot_thread_still_present":
      return copy.detail.officialIssueSnapshotThreadStillPresent;
    case "snapshot_recent_conversation_still_present":
      return copy.detail.officialIssueSnapshotRecentConversationStillPresent;
  }
}
