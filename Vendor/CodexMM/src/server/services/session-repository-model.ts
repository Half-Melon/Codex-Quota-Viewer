import type {
  AuditEntry,
  SessionRecord,
  SessionStatus,
  SessionTimelineItem,
} from "../../shared/contracts";
import type { SessionFileSummary } from "./jsonl-session-parser";

export type SessionRow = Omit<SessionRecord, "createdAt" | "updatedAt" | "indexedAt"> & {
  created_at: string;
  updated_at: string;
  indexed_at: string;
};

export type AuditRow = {
  id: number;
  action: string;
  session_id: string;
  source_path: string | null;
  target_path: string | null;
  details_json: string;
  created_at: string;
};

export type TimelineItemRow = {
  item_id: string;
  type: string;
  timestamp: string;
  text: string | null;
  tool_name: string | null;
  summary: string | null;
  input_text: string | null;
  output_text: string | null;
  status: string | null;
};

export type CatalogSessionEntry = {
  summary: SessionFileSummary;
  timeline: SessionTimelineItem[];
  activePath: string | null;
  archivePath: string | null;
  snapshotPath: string | null;
  originalRelativePath: string | null;
  status: SessionStatus;
};

export type SessionMutation = Partial<
  Pick<
    SessionRecord,
    | "activePath"
    | "archivePath"
    | "snapshotPath"
    | "originalRelativePath"
    | "cwd"
    | "startedAt"
    | "originator"
    | "source"
    | "cliVersion"
    | "modelProvider"
    | "sizeBytes"
    | "lineCount"
    | "eventCount"
    | "toolCallCount"
    | "userPromptExcerpt"
    | "latestAgentMessageExcerpt"
    | "status"
  >
>;

export function mapSessionRow(row: SessionRow): SessionRecord {
  return {
    id: row.id,
    filePath: row.filePath,
    activePath: row.activePath,
    archivePath: row.archivePath,
    snapshotPath: row.snapshotPath,
    originalRelativePath: row.originalRelativePath,
    cwd: row.cwd,
    startedAt: row.startedAt,
    originator: row.originator,
    source: row.source,
    cliVersion: row.cliVersion,
    modelProvider: row.modelProvider,
    sizeBytes: row.sizeBytes,
    lineCount: row.lineCount,
    eventCount: row.eventCount,
    toolCallCount: row.toolCallCount,
    userPromptExcerpt: row.userPromptExcerpt,
    latestAgentMessageExcerpt: row.latestAgentMessageExcerpt,
    status: row.status as SessionStatus,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    indexedAt: row.indexed_at,
  };
}

export function mapAuditRow(row: AuditRow): AuditEntry {
  return {
    id: row.id,
    action: row.action,
    sessionId: row.session_id,
    sourcePath: row.source_path,
    targetPath: row.target_path,
    details: JSON.parse(row.details_json) as Record<string, string | boolean | null>,
    createdAt: row.created_at,
  };
}

export function mapTimelineItemRow(row: TimelineItemRow): SessionTimelineItem {
  if (row.type === "tool_call") {
    return {
      id: row.item_id,
      type: "tool_call",
      timestamp: row.timestamp,
      toolName: row.tool_name ?? "unknown_tool",
      summary: row.summary ?? row.tool_name ?? "unknown_tool",
      input: row.input_text ?? "",
      output: row.output_text ?? "",
      status:
        row.status === "errored" || row.status === "completed"
          ? row.status
          : "pending",
    };
  }

  return {
    id: row.item_id,
    type:
      row.type === "message:assistant"
        ? "message:assistant"
        : "message:user",
    timestamp: row.timestamp,
    text: row.text ?? "",
  };
}
