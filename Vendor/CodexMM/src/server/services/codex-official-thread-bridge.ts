import type {
  OfficialRepairStats,
  SessionOfficialState,
  SessionRecord,
} from "../../shared/contracts";
import {
  CodexSessionIndexRepository,
  type CodexSessionIndexEntry,
} from "./codex-session-index-repository";
import {
  CodexThreadStateRepository,
  type CodexThreadRecord,
  type CodexThreadUpsert,
} from "./codex-thread-state-repository";
import { readSessionMetaSnapshot } from "./jsonl-session-parser";
import { pathExists } from "./session-manager-helpers";

const DEFAULT_SANDBOX_POLICY = JSON.stringify({ type: "danger-full-access" });
const DEFAULT_APPROVAL_MODE = "never";

export class CodexOfficialThreadBridge {
  private readonly threads: CodexThreadStateRepository;
  private readonly sessionIndex: CodexSessionIndexRepository;

  constructor(codexHome: string) {
    this.threads = new CodexThreadStateRepository(codexHome);
    this.sessionIndex = new CodexSessionIndexRepository(codexHome);
  }

  async inspectSession(record: SessionRecord): Promise<SessionOfficialState> {
    const thread = this.threads.getThread(record.id);
    const indexEntry = await this.sessionIndex.getEntry(record.id);
    const desired = buildDesiredProjection(record);

    if (!desired) {
      const issues = [
        thread ? "官方 threads 里仍然保留了这条仅剩备份的线程。" : null,
        indexEntry ? "官方 recent 列表里仍然保留了这条仅剩备份的线程。" : null,
      ].filter((issue): issue is string => Boolean(issue));

      return {
        status: issues.length > 0 ? "repair_needed" : "hidden",
        canAppearInCodex: false,
        threadRowPresent: Boolean(thread),
        sessionIndexPresent: Boolean(indexEntry),
        rolloutPathMatches: !thread,
        archivedFlagMatches: !thread,
        sessionIndexMatches: !indexEntry,
        summary:
          issues.length > 0
            ? "这条会话只剩 snapshot 备份，当前不应继续出现在官方 Codex 列表中。"
            : "这条会话只剩 snapshot 备份，当前已从官方 Codex 列表隐藏。",
        issues,
      };
    }

    const threadRowPresent = Boolean(thread);
    const sessionIndexPresent = Boolean(indexEntry);
    const rolloutPathMatches = thread?.rolloutPath === desired.rolloutPath;
    const archivedFlagMatches = thread?.archived === desired.archived;
    const sessionIndexMatches =
      indexEntry?.threadName === desired.threadName &&
      indexEntry.updatedAt === desired.updatedAt;
    const issues = [
      !threadRowPresent ? "官方 threads 缺少这条线程记录。" : null,
      threadRowPresent && !rolloutPathMatches ? "官方 rollout_path 指向了错误位置。" : null,
      threadRowPresent && !archivedFlagMatches ? "官方 archived 标记与当前状态不一致。" : null,
      !sessionIndexPresent ? "官方 recent conversations 缺少这条索引。" : null,
      sessionIndexPresent && !sessionIndexMatches ? "官方 recent conversations 的标题或更新时间过期了。" : null,
    ].filter((issue): issue is string => Boolean(issue));

    return {
      status: issues.length > 0 ? "repair_needed" : "synced",
      canAppearInCodex: true,
      threadRowPresent,
      sessionIndexPresent,
      rolloutPathMatches,
      archivedFlagMatches,
      sessionIndexMatches,
      summary:
        issues.length > 0
          ? "这条会话在官方 Codex 的本地线程状态还没有完全同步。"
          : "这条会话已经同步到官方 Codex 的 threads 和 recent conversations。",
      issues,
    };
  }

  async repairSessions(
    records: SessionRecord[],
    options: {
      sessionIds?: string[];
      cleanupBroken?: boolean;
    } = {},
  ): Promise<OfficialRepairStats> {
    const selectedIds = new Set(options.sessionIds ?? records.map((record) => record.id));
    const selectedRecords = records.filter((record) => selectedIds.has(record.id));
    const sessionIndexMap = new Map(
      (await this.sessionIndex.listEntries()).map((entry) => [entry.id, entry]),
    );
    const stats = createEmptyStats();

    for (const record of selectedRecords) {
      const desired = buildDesiredProjection(record);

      if (!desired) {
        const removedThread = this.threads.deleteThread(record.id);
        const removedIndex = sessionIndexMap.delete(record.id);

        if (removedThread || removedIndex) {
          stats.hiddenSnapshotOnlySessions += 1;
        }

        if (removedIndex) {
          stats.updatedSessionIndexEntries += 1;
        }

        continue;
      }

      const currentThread = this.threads.getThread(record.id);
      const nextThread = await this.buildThreadUpsert(record, desired, currentThread);
      const threadResult = this.threads.upsertThread(nextThread);
      const sessionIndexResult = upsertSessionIndexEntry(sessionIndexMap, {
        id: desired.id,
        threadName: desired.threadName,
        updatedAt: desired.updatedAt,
      });

      if (threadResult === "created") {
        stats.createdThreads += 1;
      } else if (threadResult === "updated") {
        stats.updatedThreads += 1;
      }

      if (sessionIndexResult === "created" || sessionIndexResult === "updated") {
        stats.updatedSessionIndexEntries += 1;
      }
    }

    if (options.cleanupBroken) {
      await this.cleanupBrokenOfficialThreads(records, sessionIndexMap, stats);
    }

    await this.sessionIndex.replaceEntries(sessionIndexMap.values());

    return stats;
  }

  async removeSession(sessionId: string) {
    const removedThread = this.threads.deleteThread(sessionId);
    const removedIndex = await this.sessionIndex.deleteEntry(sessionId);

    return {
      removedThread,
      removedIndex,
    };
  }

  private async buildThreadUpsert(
    record: SessionRecord,
    desired: DesiredProjection,
    existing: CodexThreadRecord | null,
  ): Promise<CodexThreadUpsert> {
    const meta = await readSessionMetaSnapshot(desired.rolloutPath);
    const createdAt = toUnixSeconds(record.startedAt);
    const updatedAt = toUnixSeconds(record.updatedAt);

    return {
      id: record.id,
      rolloutPath: desired.rolloutPath,
      createdAt: existing?.createdAt ?? createdAt,
      updatedAt,
      source: serializeThreadSource(meta?.source ?? existing?.source ?? record.source),
      modelProvider: meta?.modelProvider ?? existing?.modelProvider ?? record.modelProvider,
      cwd: record.cwd,
      title: desired.threadName,
      sandboxPolicy: meta?.sandboxPolicy ?? existing?.sandboxPolicy ?? DEFAULT_SANDBOX_POLICY,
      approvalMode: meta?.approvalMode ?? existing?.approvalMode ?? DEFAULT_APPROVAL_MODE,
      archived: desired.archived,
      archivedAt:
        desired.archived === 1
          ? existing?.archivedAt ?? updatedAt
          : null,
      cliVersion: meta?.cliVersion ?? existing?.cliVersion ?? record.cliVersion,
      firstUserMessage: resolveFirstUserMessage(record, existing, desired.threadName),
      memoryMode: meta?.memoryMode ?? existing?.memoryMode ?? "enabled",
      model: meta?.model ?? existing?.model ?? null,
      reasoningEffort: meta?.reasoningEffort ?? existing?.reasoningEffort ?? null,
      agentPath: meta?.agentPath ?? existing?.agentPath ?? null,
      hasUserEvent: existing?.hasUserEvent ?? true,
    };
  }

  private async cleanupBrokenOfficialThreads(
    records: SessionRecord[],
    sessionIndexMap: Map<string, CodexSessionIndexEntry>,
    stats: OfficialRepairStats,
  ) {
    const managedIds = new Set(records.map((record) => record.id));
    const officialThreads = this.threads.listThreads();

    for (const thread of officialThreads) {
      if (managedIds.has(thread.id)) {
        continue;
      }

      if (await pathExists(thread.rolloutPath)) {
        continue;
      }

      if (this.threads.deleteThread(thread.id)) {
        stats.removedBrokenThreads += 1;
      }

      if (sessionIndexMap.delete(thread.id)) {
        stats.updatedSessionIndexEntries += 1;
      }
    }

    const officialThreadIds = new Set(this.threads.listThreads().map((thread) => thread.id));

    for (const entry of sessionIndexMap.values()) {
      if (officialThreadIds.has(entry.id)) {
        continue;
      }

      const managed = records.find((record) => record.id === entry.id);

      if (managed && buildDesiredProjection(managed)) {
        continue;
      }

      if (sessionIndexMap.delete(entry.id)) {
        stats.updatedSessionIndexEntries += 1;
      }
    }
  }
}

type DesiredProjection = {
  id: string;
  rolloutPath: string;
  archived: 0 | 1;
  threadName: string;
  updatedAt: string;
};

function buildDesiredProjection(record: SessionRecord): DesiredProjection | null {
  if (record.status === "restorable") {
    return null;
  }

  const rolloutPath = record.activePath ?? record.archivePath;

  if (!rolloutPath) {
    return null;
  }

  return {
    id: record.id,
    rolloutPath,
    archived: record.status === "active" ? 0 : 1,
    threadName: buildThreadName(record),
    updatedAt: record.updatedAt,
  };
}

function buildThreadName(record: Pick<SessionRecord, "id" | "userPromptExcerpt" | "latestAgentMessageExcerpt">) {
  const preferred = record.userPromptExcerpt.trim();

  if (preferred.length > 0) {
    return preferred;
  }

  const fallback = record.latestAgentMessageExcerpt.trim();
  return fallback.length > 0 ? fallback : record.id;
}

function resolveFirstUserMessage(
  record: Pick<SessionRecord, "userPromptExcerpt">,
  existing: Pick<CodexThreadRecord, "firstUserMessage"> | null,
  fallback: string,
) {
  const preferred = record.userPromptExcerpt.trim();

  if (preferred.length > 0) {
    return preferred;
  }

  const existingValue = existing?.firstUserMessage.trim() ?? "";
  return existingValue.length > 0 ? existingValue : fallback;
}

function serializeThreadSource(value: unknown) {
  if (typeof value === "string" && value.length > 0) {
    return value;
  }

  if (value && typeof value === "object") {
    try {
      return JSON.stringify(value);
    } catch {
      return "vscode";
    }
  }

  return "vscode";
}

function createEmptyStats(): OfficialRepairStats {
  return {
    createdThreads: 0,
    updatedThreads: 0,
    updatedSessionIndexEntries: 0,
    removedBrokenThreads: 0,
    hiddenSnapshotOnlySessions: 0,
  };
}

function toUnixSeconds(value: string) {
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? Math.floor(timestamp / 1000) : Math.floor(Date.now() / 1000);
}

function upsertSessionIndexEntry(
  entries: Map<string, CodexSessionIndexEntry>,
  nextEntry: CodexSessionIndexEntry,
) {
  const existing = entries.get(nextEntry.id);

  if (
    existing &&
    existing.threadName === nextEntry.threadName &&
    existing.updatedAt === nextEntry.updatedAt
  ) {
    return "unchanged" as const;
  }

  entries.set(nextEntry.id, nextEntry);
  return existing ? ("updated" as const) : ("created" as const);
}
