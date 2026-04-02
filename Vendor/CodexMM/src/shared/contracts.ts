export type SessionStatus =
  | "active"
  | "archived"
  | "deleted_pending_purge"
  | "restorable";

export type SessionRecord = {
  id: string;
  filePath: string | null;
  activePath: string | null;
  archivePath: string | null;
  snapshotPath: string | null;
  originalRelativePath: string | null;
  cwd: string;
  startedAt: string;
  originator: string;
  source: string;
  cliVersion: string;
  modelProvider: string;
  sizeBytes: number;
  lineCount: number;
  eventCount: number;
  toolCallCount: number;
  userPromptExcerpt: string;
  latestAgentMessageExcerpt: string;
  status: SessionStatus;
  createdAt: string;
  updatedAt: string;
  indexedAt: string;
};

export type AuditEntry = {
  id: number;
  action: string;
  sessionId: string;
  sourcePath: string | null;
  targetPath: string | null;
  details: Record<string, string | boolean | null>;
  createdAt: string;
};

export type SessionTimelineItem =
  | {
      id: string;
      type: "message:user" | "message:assistant";
      timestamp: string;
      text: string;
    }
  | {
      id: string;
      type: "tool_call";
      timestamp: string;
      toolName: string;
      summary: string;
      input: string;
      output: string;
      status: "pending" | "completed" | "errored";
    };

export type SessionOfficialState = {
  status: "synced" | "repair_needed" | "hidden";
  canAppearInCodex: boolean;
  threadRowPresent: boolean;
  sessionIndexPresent: boolean;
  rolloutPathMatches: boolean;
  archivedFlagMatches: boolean;
  sessionIndexMatches: boolean;
  summary: string;
  issues: string[];
};

export type SessionDetail = {
  record: SessionRecord;
  auditEntries: AuditEntry[];
  timeline: SessionTimelineItem[];
  timelineTotal: number;
  timelineNextOffset: number | null;
  officialState: SessionOfficialState;
};

export type SessionTimelinePage = {
  items: SessionTimelineItem[];
  total: number;
  nextOffset: number | null;
};

export type SessionFilters = {
  query?: string;
  status?: SessionStatus;
  cwd?: string;
};

export type RestoreMode = "resume_only" | "rebind_cwd";

export type ApiErrorCode =
  | "active_session_cannot_be_archived"
  | "active_session_must_be_deleted_before_purge"
  | "internal_server_error"
  | "managed_session_path_outside"
  | "path_outside_managed_root"
  | "rebind_requires_target"
  | "restore_target_missing_directory"
  | "restore_target_not_directory"
  | "restore_target_permission_denied"
  | "session_has_no_file_to_delete"
  | "session_is_not_restorable"
  | "unknown_server_error"
  | "unknown_session"
  | "unsupported_restore_mode";

export type ApiErrorResponse = {
  code: ApiErrorCode;
  error: string;
};

export type RestoreRequest = {
  sessionId: string;
  targetCwd?: string;
  restoreMode: RestoreMode;
  launch?: boolean;
};

export type BatchSessionActionRequest = {
  sessionIds: string[];
};

export type BatchSessionActionFailure = {
  sessionId: string;
  code?: ApiErrorCode;
  error: string;
};

export type BatchSessionActionResponse = {
  records: SessionRecord[];
  failures: BatchSessionActionFailure[];
};

export type OfficialRepairStats = {
  createdThreads: number;
  updatedThreads: number;
  updatedSessionIndexEntries: number;
  removedBrokenThreads: number;
  hiddenSnapshotOnlySessions: number;
};

export type OfficialRepairResponse = {
  sessions: SessionRecord[];
  stats: OfficialRepairStats;
};

export type UiConfigResponse = {
  language: "en" | "zh";
};
