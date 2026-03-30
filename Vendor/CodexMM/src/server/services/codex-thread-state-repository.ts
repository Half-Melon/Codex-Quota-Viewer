import { existsSync, readdirSync } from "node:fs";
import path from "node:path";

import Database from "better-sqlite3";

export type CodexThreadRecord = {
  id: string;
  rolloutPath: string;
  createdAt: number;
  updatedAt: number;
  source: string;
  modelProvider: string;
  cwd: string;
  title: string;
  sandboxPolicy: string;
  approvalMode: string;
  hasUserEvent: boolean;
  archived: 0 | 1;
  archivedAt: number | null;
  cliVersion: string;
  firstUserMessage: string;
  memoryMode: string;
  model: string | null;
  reasoningEffort: string | null;
  agentPath: string | null;
};

export type CodexThreadUpsert = Omit<CodexThreadRecord, "hasUserEvent"> & {
  hasUserEvent?: boolean;
};

export class CodexThreadStateRepository {
  private readonly db: Database.Database | null;

  constructor(codexHome: string) {
    const databasePath = resolveStateDatabasePath(codexHome);

    if (!databasePath) {
      this.db = null;
      return;
    }

    const db = new Database(databasePath);

    if (
      !db
        .prepare(
          `
            select 1
            from sqlite_master
            where type = 'table' and name = 'threads'
          `,
        )
        .get()
    ) {
      db.close();
      this.db = null;
      return;
    }

    this.db = db;
  }

  listThreads() {
    if (!this.db) {
      return [] as CodexThreadRecord[];
    }

    const rows = this.db
      .prepare(
        `
          select
            id,
            rollout_path as rolloutPath,
            created_at as createdAt,
            updated_at as updatedAt,
            source,
            model_provider as modelProvider,
            cwd,
            title,
            sandbox_policy as sandboxPolicy,
            approval_mode as approvalMode,
            has_user_event as hasUserEvent,
            archived,
            archived_at as archivedAt,
            cli_version as cliVersion,
            first_user_message as firstUserMessage,
            memory_mode as memoryMode,
            model,
            reasoning_effort as reasoningEffort,
            agent_path as agentPath
          from threads
          order by updated_at desc, id asc
        `,
      )
      .all() as ThreadRow[];

    return rows.map(mapThreadRow);
  }

  getThread(threadId: string) {
    if (!this.db) {
      return null;
    }

    const row = this.db
      .prepare(
        `
          select
            id,
            rollout_path as rolloutPath,
            created_at as createdAt,
            updated_at as updatedAt,
            source,
            model_provider as modelProvider,
            cwd,
            title,
            sandbox_policy as sandboxPolicy,
            approval_mode as approvalMode,
            has_user_event as hasUserEvent,
            archived,
            archived_at as archivedAt,
            cli_version as cliVersion,
            first_user_message as firstUserMessage,
            memory_mode as memoryMode,
            model,
            reasoning_effort as reasoningEffort,
            agent_path as agentPath
          from threads
          where id = ?
        `,
      )
      .get(threadId) as ThreadRow | undefined;

    return row ? mapThreadRow(row) : null;
  }

  upsertThread(input: CodexThreadUpsert) {
    if (!this.db) {
      return "skipped" as const;
    }

    const existing = this.getThread(input.id);
    const next = buildThreadRecord(input, existing);

    if (existing && areSameThread(existing, next)) {
      return "unchanged" as const;
    }

    if (existing) {
      this.db
        .prepare(
          `
            update threads
            set rollout_path = @rolloutPath,
                created_at = @createdAt,
                updated_at = @updatedAt,
                source = @source,
                model_provider = @modelProvider,
                cwd = @cwd,
                title = @title,
                sandbox_policy = @sandboxPolicy,
                approval_mode = @approvalMode,
                has_user_event = @hasUserEvent,
                archived = @archived,
                archived_at = @archivedAt,
                cli_version = @cliVersion,
                first_user_message = @firstUserMessage,
                memory_mode = @memoryMode,
                model = @model,
                reasoning_effort = @reasoningEffort,
                agent_path = @agentPath
            where id = @id
          `,
        )
        .run(toDatabaseParams(next));

      return "updated" as const;
    }

    this.db
      .prepare(
        `
          insert into threads (
            id,
            rollout_path,
            created_at,
            updated_at,
            source,
            model_provider,
            cwd,
            title,
            sandbox_policy,
            approval_mode,
            has_user_event,
            archived,
            archived_at,
            cli_version,
            first_user_message,
            memory_mode,
            model,
            reasoning_effort,
            agent_path
          ) values (
            @id,
            @rolloutPath,
            @createdAt,
            @updatedAt,
            @source,
            @modelProvider,
            @cwd,
            @title,
            @sandboxPolicy,
            @approvalMode,
            @hasUserEvent,
            @archived,
            @archivedAt,
            @cliVersion,
            @firstUserMessage,
            @memoryMode,
            @model,
            @reasoningEffort,
            @agentPath
          )
        `,
      )
      .run(toDatabaseParams(next));

    return "created" as const;
  }

  deleteThread(threadId: string) {
    if (!this.db) {
      return false;
    }

    const result = this.db.prepare("delete from threads where id = ?").run(threadId);
    return result.changes > 0;
  }
}

type ThreadRow = {
  id: string;
  rolloutPath: string;
  createdAt: number;
  updatedAt: number;
  source: string;
  modelProvider: string;
  cwd: string;
  title: string;
  sandboxPolicy: string;
  approvalMode: string;
  hasUserEvent: number;
  archived: number;
  archivedAt: number | null;
  cliVersion: string;
  firstUserMessage: string;
  memoryMode: string;
  model: string | null;
  reasoningEffort: string | null;
  agentPath: string | null;
};

function buildThreadRecord(input: CodexThreadUpsert, existing: CodexThreadRecord | null) {
  return {
    id: input.id,
    rolloutPath: input.rolloutPath,
    createdAt: input.createdAt,
    updatedAt: input.updatedAt,
    source: input.source,
    modelProvider: input.modelProvider,
    cwd: input.cwd,
    title: input.title,
    sandboxPolicy: input.sandboxPolicy,
    approvalMode: input.approvalMode,
    hasUserEvent: input.hasUserEvent ?? existing?.hasUserEvent ?? true,
    archived: input.archived,
    archivedAt: input.archived === 1 ? input.archivedAt ?? existing?.archivedAt ?? input.updatedAt : null,
    cliVersion: input.cliVersion,
    firstUserMessage: input.firstUserMessage,
    memoryMode: input.memoryMode,
    model: input.model,
    reasoningEffort: input.reasoningEffort,
    agentPath: input.agentPath,
  } satisfies CodexThreadRecord;
}

function areSameThread(left: CodexThreadRecord, right: CodexThreadRecord) {
  return (
    left.rolloutPath === right.rolloutPath &&
    left.createdAt === right.createdAt &&
    left.updatedAt === right.updatedAt &&
    left.source === right.source &&
    left.modelProvider === right.modelProvider &&
    left.cwd === right.cwd &&
    left.title === right.title &&
    left.sandboxPolicy === right.sandboxPolicy &&
    left.approvalMode === right.approvalMode &&
    left.hasUserEvent === right.hasUserEvent &&
    left.archived === right.archived &&
    left.archivedAt === right.archivedAt &&
    left.cliVersion === right.cliVersion &&
    left.firstUserMessage === right.firstUserMessage &&
    left.memoryMode === right.memoryMode &&
    left.model === right.model &&
    left.reasoningEffort === right.reasoningEffort &&
    left.agentPath === right.agentPath
  );
}

function toDatabaseParams(record: CodexThreadRecord) {
  return {
    ...record,
    hasUserEvent: record.hasUserEvent ? 1 : 0,
  };
}

function mapThreadRow(row: ThreadRow): CodexThreadRecord {
  return {
    ...row,
    archived: row.archived === 1 ? 1 : 0,
    hasUserEvent: row.hasUserEvent === 1,
  };
}


function resolveStateDatabasePath(codexHome: string) {
  const directCandidates = listStateDatabaseCandidates(codexHome);

  if (directCandidates.length > 0) {
    return directCandidates[0];
  }

  const sqliteStateDb = path.join(codexHome, "sqlite", "state.db");
  return existsSync(sqliteStateDb) ? sqliteStateDb : null;
}

function listStateDatabaseCandidates(codexHome: string) {
  try {
    return readdirSync(codexHome, { withFileTypes: true })
      .filter(
        (entry): entry is typeof entry & { name: string } =>
          entry.isFile() && /^state_(\d+)\.sqlite$/.test(entry.name),
      )
      .sort((left, right) => extractStateVersion(right.name) - extractStateVersion(left.name))
      .map((entry) => path.join(codexHome, entry.name));
  } catch {
    return [];
  }
}

function extractStateVersion(fileName: string) {
  const match = fileName.match(/^state_(\d+)\.sqlite$/);
  return match ? Number(match[1]) : -1;
}
