import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import readline from "node:readline";

import type {
  SessionTimelineItem,
  SessionTimelinePage,
} from "../../shared/contracts";

export const DEFAULT_TIMELINE_PAGE_SIZE = 200;
export const MAX_TIMELINE_PAGE_SIZE = 500;
const PARSER_CACHE_LIMIT = 128;

type SessionMetaPayload = {
  id?: unknown;
  timestamp?: unknown;
  cwd?: unknown;
  originator?: unknown;
  source?: unknown;
  cli_version?: unknown;
  cliVersion?: unknown;
  model_provider?: unknown;
  modelProvider?: unknown;
  model?: unknown;
  reasoning_effort?: unknown;
  reasoningEffort?: unknown;
  approval_mode?: unknown;
  approvalMode?: unknown;
  sandbox_policy?: unknown;
  sandboxPolicy?: unknown;
  memory_mode?: unknown;
  memoryMode?: unknown;
  agent_path?: unknown;
  agentPath?: unknown;
};

export type SessionMetaSnapshot = {
  id: string;
  startedAt: string;
  cwd: string;
  source: unknown;
  cliVersion: string;
  modelProvider: string;
  model: string | null;
  reasoningEffort: string | null;
  approvalMode: string | null;
  sandboxPolicy: string | null;
  memoryMode: string | null;
  agentPath: string | null;
};

export type SessionFileSummary = {
  id: string;
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
};

type CachedFileValue<T> = {
  sizeBytes: number;
  mtimeMs: number;
  value: T;
};

const sessionSummaryCache = new Map<
  string,
  CachedFileValue<SessionFileSummary | null>
>();
const sessionTimelineCache = new Map<
  string,
  CachedFileValue<SessionTimelineItem[]>
>();

export async function parseSessionFile(
  filePath: string,
): Promise<SessionFileSummary | null> {
  const fileStats = await stat(filePath);
  const cachedSummary = readCachedFileValue(
    sessionSummaryCache,
    filePath,
    fileStats.size,
    fileStats.mtimeMs,
  );

  if (cachedSummary !== undefined) {
    return cachedSummary;
  }

  const input = createReadStream(filePath, { encoding: "utf8" });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });

  let meta: SessionMetaPayload | null = null;
  let lineCount = 0;
  let eventCount = 0;
  let toolCallCount = 0;
  let userPromptExcerpt = "";
  let latestAgentMessageExcerpt = "";
  let responseUserExcerpt = "";
  let responseAssistantExcerpt = "";

  try {
    for await (const line of lines) {
      if (!line.trim()) {
        continue;
      }

      lineCount += 1;

      let entry: Record<string, unknown>;

      try {
        entry = JSON.parse(line) as Record<string, unknown>;
      } catch {
        continue;
      }

      if (entry.type === "session_meta" && !meta) {
        meta = (entry.payload ?? {}) as SessionMetaPayload;
        continue;
      }

      if (entry.type === "event_msg") {
        eventCount += 1;
        const payload = (entry.payload ?? {}) as Record<string, unknown>;

        if (payload.type === "user_message" && !userPromptExcerpt) {
          userPromptExcerpt = truncateMessage(readMessage(payload.message));
        }

        if (payload.type === "agent_message") {
          latestAgentMessageExcerpt = truncateMessage(readMessage(payload.message));
        }
      }

      if (entry.type === "response_item") {
        const payload = (entry.payload ?? {}) as Record<string, unknown>;
        if (payload.type === "function_call") {
          toolCallCount += 1;
        }

        if (payload.type === "message") {
          const message = truncateMessage(readResponseMessageText(payload));

          if (!message) {
            continue;
          }

          if (payload.role === "user" && !responseUserExcerpt) {
            responseUserExcerpt = message;
          }

          if (payload.role === "assistant") {
            responseAssistantExcerpt = message;
          }
        }
      }
    }
  } finally {
    lines.close();
  }

  const metaPayload = meta ?? {};
  const sessionId = normalizeRequiredString(metaPayload.id);
  const startedAt = normalizeRequiredString(metaPayload.timestamp);
  const cwd = normalizeRequiredString(metaPayload.cwd);

  if (!sessionId || !startedAt || !cwd) {
    writeCachedFileValue(sessionSummaryCache, filePath, fileStats, null);
    return null;
  }

  const summary = {
    id: sessionId,
    cwd,
    startedAt,
    originator: normalizeOptionalString(metaPayload.originator, "Unknown"),
    source: normalizeSource(metaPayload.source),
    cliVersion: normalizeOptionalString(
      metaPayload.cli_version ?? metaPayload.cliVersion,
      "unknown",
    ),
    modelProvider: normalizeOptionalString(
      metaPayload.model_provider ?? metaPayload.modelProvider,
      "unknown",
    ),
    sizeBytes: fileStats.size,
    lineCount,
    eventCount,
    toolCallCount,
    userPromptExcerpt: userPromptExcerpt || responseUserExcerpt,
    latestAgentMessageExcerpt:
      latestAgentMessageExcerpt || responseAssistantExcerpt,
  };

  writeCachedFileValue(sessionSummaryCache, filePath, fileStats, summary);
  return summary;
}

export async function parseSessionTimeline(
  filePath: string,
): Promise<SessionTimelineItem[]> {
  const page = await parseSessionTimelinePage(filePath, {
    offset: 0,
    limit: Number.MAX_SAFE_INTEGER,
  });

  return page.items;
}

export async function parseSessionTimelinePage(
  filePath: string,
  options: {
    offset?: number;
    limit?: number;
  } = {},
): Promise<SessionTimelinePage> {
  const offset = Math.max(options.offset ?? 0, 0);
  const limit = clampTimelinePageSize(options.limit);
  const items = await readTimelineItems(filePath);

  const total = items.length;
  const pageItems = items.slice(offset, offset + limit);
  const nextOffset = offset + limit < total ? offset + limit : null;

  return {
    items: pageItems,
    total,
    nextOffset,
  };
}

async function readTimelineItems(filePath: string) {
  const fileStats = await stat(filePath);
  const cachedTimeline = readCachedFileValue(
    sessionTimelineCache,
    filePath,
    fileStats.size,
    fileStats.mtimeMs,
  );

  if (cachedTimeline !== undefined) {
    return cachedTimeline;
  }

  const input = createReadStream(filePath, { encoding: "utf8" });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });
  const responseMessages: TimelineDraft[] = [];
  const fallbackMessages: TimelineDraft[] = [];
  const toolCalls: ToolTimelineDraft[] = [];
  const toolCallIndex = new Map<string, number>();
  let sequence = 0;

  try {
    for await (const line of lines) {
      if (!line.trim()) {
        continue;
      }

      let entry: Record<string, unknown>;

      try {
        entry = JSON.parse(line) as Record<string, unknown>;
      } catch {
        continue;
      }

      const timestamp = normalizeOptionalString(entry.timestamp, new Date(0).toISOString());

      if (entry.type === "event_msg") {
        const payload = (entry.payload ?? {}) as Record<string, unknown>;
        const message = normalizeMessage(readMessage(payload.message));

        if (!message) {
          continue;
        }

        if (payload.type === "user_message" || payload.type === "agent_message") {
          fallbackMessages.push({
            id: `event-${sequence + 1}`,
            order: sequence,
            timestamp,
            type: payload.type === "user_message" ? "message:user" : "message:assistant",
            text: message,
          });
          sequence += 1;
        }

        continue;
      }

      if (entry.type !== "response_item") {
        continue;
      }

      const payload = (entry.payload ?? {}) as Record<string, unknown>;

      if (payload.type === "message") {
        const message = normalizeMessage(readResponseMessageText(payload));

        if (!message || (payload.role !== "user" && payload.role !== "assistant")) {
          continue;
        }

        responseMessages.push({
          id: `message-${sequence + 1}`,
          order: sequence,
          timestamp,
          type: payload.role === "user" ? "message:user" : "message:assistant",
          text: message,
        });
        sequence += 1;
        continue;
      }

      if (payload.type === "function_call") {
        const callId = normalizeOptionalString(payload.call_id, `tool-${sequence + 1}`);
        const inputText = normalizeMessage(normalizeOptionalString(payload.arguments, ""));
        const toolName = normalizeOptionalString(payload.name, "unknown_tool");
        toolCallIndex.set(callId, toolCalls.length);
        toolCalls.push({
          id: `tool-${sequence + 1}`,
          order: sequence,
          timestamp,
          type: "tool_call",
          toolName,
          summary: buildToolSummary(toolName, inputText, ""),
          input: inputText,
          output: "",
          status: "pending",
        });
        sequence += 1;
        continue;
      }

      if (payload.type === "function_call_output") {
        const callId = normalizeOptionalString(payload.call_id, "");
        const toolIndex = toolCallIndex.get(callId);

        if (toolIndex === undefined) {
          continue;
        }

        const normalizedOutput = normalizeMessage(normalizeOptionalString(payload.output, ""));
        const existing = toolCalls[toolIndex];

        if (!existing) {
          continue;
        }

        toolCalls[toolIndex] = {
          ...existing,
          output: normalizedOutput,
          summary: buildToolSummary(existing.toolName, existing.input, normalizedOutput),
          status: readToolStatus(payload.output),
        };
      }
    }
  } finally {
    lines.close();
  }

  const responseMessageTypes = new Set(responseMessages.map((item) => item.type));
  const mergedMessages =
    responseMessages.length === 0
      ? fallbackMessages
      : [
          ...fallbackMessages.filter((item) => !responseMessageTypes.has(item.type)),
          ...responseMessages,
        ];
  const items = [...mergedMessages, ...toolCalls]
    .sort(sortTimelineDrafts)
    .map(stripTimelineDraft);

  writeCachedFileValue(sessionTimelineCache, filePath, fileStats, items);
  return items;
}

export async function readSessionMetaSnapshot(
  filePath: string,
): Promise<SessionMetaSnapshot | null> {
  const input = createReadStream(filePath, { encoding: "utf8" });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });

  try {
    for await (const line of lines) {
      if (!line.trim()) {
        continue;
      }

      let entry: Record<string, unknown>;

      try {
        entry = JSON.parse(line) as Record<string, unknown>;
      } catch {
        continue;
      }

      if (entry.type !== "session_meta") {
        continue;
      }

      const payload = (entry.payload ?? {}) as SessionMetaPayload;
      const id = normalizeRequiredString(payload.id);
      const startedAt = normalizeRequiredString(payload.timestamp);
      const cwd = normalizeRequiredString(payload.cwd);

      if (!id || !startedAt || !cwd) {
        return null;
      }

      return {
        id,
        startedAt,
        cwd,
        source: payload.source ?? "vscode",
        cliVersion: normalizeOptionalString(
          payload.cli_version ?? payload.cliVersion,
          "unknown",
        ),
        modelProvider: normalizeOptionalString(
          payload.model_provider ?? payload.modelProvider,
          "unknown",
        ),
        model: normalizeNullableString(payload.model),
        reasoningEffort: normalizeNullableString(
          payload.reasoning_effort ?? payload.reasoningEffort,
        ),
        approvalMode: normalizeNullableString(
          payload.approval_mode ?? payload.approvalMode,
        ),
        sandboxPolicy: normalizeNullableString(
          payload.sandbox_policy ?? payload.sandboxPolicy,
        ),
        memoryMode: normalizeNullableString(
          payload.memory_mode ?? payload.memoryMode,
        ),
        agentPath: normalizeNullableString(payload.agent_path ?? payload.agentPath),
      };
    }

    return null;
  } finally {
    lines.close();
  }
}

type TimelineDraft = {
  id: string;
  type: "message:user" | "message:assistant";
  timestamp: string;
  text: string;
  order: number;
};

type ToolTimelineDraft = {
  id: string;
  type: "tool_call";
  timestamp: string;
  toolName: string;
  summary: string;
  input: string;
  output: string;
  status: "pending" | "completed" | "errored";
  order: number;
};

function readMessage(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }

  return "";
}

function readResponseMessageText(payload: Record<string, unknown>) {
  const content = Array.isArray(payload.content) ? payload.content : [];
  const segments = content
    .map((part) => {
      if (!part || typeof part !== "object") {
        return "";
      }

      const candidate = part as {
        text?: unknown;
        content?: unknown;
      };

      if (typeof candidate.text === "string") {
        return candidate.text;
      }

      return typeof candidate.content === "string" ? candidate.content : "";
    })
    .filter(Boolean);

  return segments.join("\n").trim();
}

function truncateMessage(message: string): string {
  const trimmed = normalizeMessage(message);

  if (trimmed.length <= 180) {
    return trimmed;
  }

  return `${trimmed.slice(0, 177)}...`;
}

function normalizeMessage(message: string) {
  return message.trim();
}

function normalizeRequiredString(value: unknown) {
  const normalized = normalizeOptionalString(value, "");
  return normalized.length > 0 ? normalized : null;
}

function normalizeOptionalString(value: unknown, fallback: string) {
  if (typeof value === "string") {
    return value;
  }

  if (
    typeof value === "number" ||
    typeof value === "boolean" ||
    typeof value === "bigint"
  ) {
    return String(value);
  }

  if (value && typeof value === "object") {
    try {
      return JSON.stringify(value);
    } catch {
      return fallback;
    }
  }

  return fallback;
}

function normalizeNullableString(value: unknown) {
  const normalized = normalizeOptionalString(value, "");
  return normalized.length > 0 ? normalized : null;
}

function buildToolSummary(toolName: string, input: string, output: string) {
  const detail = input || output;
  return detail ? `${toolName} · ${truncateMessage(detail)}` : toolName;
}

function readToolStatus(value: unknown): "completed" | "errored" {
  const normalized = normalizeOptionalString(value, "").toLowerCase();

  if (
    normalized.includes("error") ||
    normalized.includes("failed") ||
    normalized.includes("exception")
  ) {
    return "errored";
  }

  return "completed";
}

function sortTimelineDrafts(left: { timestamp: string; order: number }, right: { timestamp: string; order: number }) {
  const leftTimestamp = Date.parse(left.timestamp);
  const rightTimestamp = Date.parse(right.timestamp);
  const leftIsValid = Number.isFinite(leftTimestamp);
  const rightIsValid = Number.isFinite(rightTimestamp);

  if (leftIsValid && rightIsValid && leftTimestamp !== rightTimestamp) {
    return leftTimestamp - rightTimestamp;
  }

  if (leftIsValid !== rightIsValid) {
    return leftIsValid ? -1 : 1;
  }

  return left.order - right.order;
}

function stripTimelineDraft(item: TimelineDraft | ToolTimelineDraft): SessionTimelineItem {
  const { order: _order, ...timelineItem } = item;
  return timelineItem;
}

function normalizeSource(value: unknown) {
  if (typeof value === "string") {
    return value;
  }

  if (value && typeof value === "object") {
    const role = readSubagentRole(value);
    if (role) {
      return `subagent:${role}`;
    }
  }

  return normalizeOptionalString(value, "unknown");
}

function readSubagentRole(value: unknown) {
  if (!value || typeof value !== "object") {
    return null;
  }

  const candidate = value as {
    subagent?: {
      thread_spawn?: {
        agent_role?: unknown;
      };
    };
  };

  return typeof candidate.subagent?.thread_spawn?.agent_role === "string"
    ? candidate.subagent.thread_spawn.agent_role
    : null;
}

function clampTimelinePageSize(limit: number | undefined) {
  if (typeof limit !== "number" || !Number.isFinite(limit)) {
    return DEFAULT_TIMELINE_PAGE_SIZE;
  }

  if (limit >= Number.MAX_SAFE_INTEGER) {
    return Number.MAX_SAFE_INTEGER;
  }

  return Math.min(Math.max(Math.trunc(limit), 1), MAX_TIMELINE_PAGE_SIZE);
}

function readCachedFileValue<T>(
  cache: Map<string, CachedFileValue<T>>,
  filePath: string,
  sizeBytes: number,
  mtimeMs: number,
) {
  const cachedValue = cache.get(filePath);

  if (
    cachedValue &&
    cachedValue.sizeBytes === sizeBytes &&
    cachedValue.mtimeMs === mtimeMs
  ) {
    cache.delete(filePath);
    cache.set(filePath, cachedValue);
    return cachedValue.value;
  }

  return undefined;
}

function writeCachedFileValue<T>(
  cache: Map<string, CachedFileValue<T>>,
  filePath: string,
  fileStats: { size: number; mtimeMs: number },
  value: T,
) {
  cache.delete(filePath);
  cache.set(filePath, {
    sizeBytes: fileStats.size,
    mtimeMs: fileStats.mtimeMs,
    value,
  });

  while (cache.size > PARSER_CACHE_LIMIT) {
    const oldestKey = cache.keys().next().value;

    if (!oldestKey) {
      return;
    }

    cache.delete(oldestKey);
  }
}
