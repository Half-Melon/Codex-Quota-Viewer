import Database from "better-sqlite3";

import type {
  AuditEntry,
  SessionFilters,
} from "../../shared/contracts";

import type { SessionFileSummary } from "./jsonl-session-parser";
import {
  mapAuditRow,
  mapSessionRow,
  type AuditRow,
  type SessionMutation,
  type SessionRow,
} from "./session-repository-model";

export class SessionRepository {
  private readonly db: Database.Database;
  constructor(databasePath: string) {
    this.db = new Database(databasePath);
    this.db.pragma("journal_mode = WAL");
    this.db.exec(`
      create table if not exists sessions (
        id text primary key,
        active_path text,
        archive_path text,
        snapshot_path text,
        original_relative_path text,
        cwd text not null,
        started_at text not null,
        originator text not null,
        source text not null,
        cli_version text not null,
        model_provider text not null,
        size_bytes integer not null default 0,
        line_count integer not null default 0,
        event_count integer not null default 0,
        tool_call_count integer not null default 0,
        user_prompt_excerpt text not null default '',
        latest_agent_message_excerpt text not null default '',
        status text not null,
        created_at text not null,
        updated_at text not null,
        indexed_at text not null
      );

      create table if not exists audit_log (
        id integer primary key autoincrement,
        action text not null,
        session_id text not null,
        source_path text,
        target_path text,
        details_json text not null default '{}',
        created_at text not null
      );

      create index if not exists idx_sessions_status_started_at
        on sessions(status, started_at desc);
      create index if not exists idx_sessions_cwd_started_at
        on sessions(cwd, started_at desc);
      create index if not exists idx_sessions_started_at
        on sessions(started_at desc);
    `);

    this.ensureSchema();
  }
  upsertSession(
    summary: SessionFileSummary,
    mutation: Pick<
      SessionMutation,
      "activePath" | "archivePath" | "originalRelativePath" | "status"
    >,
  ) {
    const now = new Date().toISOString();
    const existing = this.getSession(summary.id);
    const createdAt = existing?.createdAt ?? now;
    const updatedAt =
      existing && !didSessionSummaryChange(existing, summary, mutation)
        ? existing.updatedAt
        : now;

    this.db
      .prepare(
        `
        insert into sessions (
          id, active_path, archive_path, snapshot_path, original_relative_path,
          cwd, started_at, originator, source, cli_version, model_provider,
          size_bytes, line_count, event_count, tool_call_count,
          user_prompt_excerpt, latest_agent_message_excerpt, status,
          created_at, updated_at, indexed_at
        ) values (
          @id, @activePath, @archivePath, @snapshotPath, @originalRelativePath,
          @cwd, @startedAt, @originator, @source, @cliVersion, @modelProvider,
          @sizeBytes, @lineCount, @eventCount, @toolCallCount,
          @userPromptExcerpt, @latestAgentMessageExcerpt, @status,
          @createdAt, @updatedAt, @indexedAt
        )
        on conflict(id) do update set
          active_path = excluded.active_path,
          archive_path = excluded.archive_path,
          snapshot_path = excluded.snapshot_path,
          original_relative_path = excluded.original_relative_path,
          cwd = excluded.cwd,
          started_at = excluded.started_at,
          originator = excluded.originator,
          source = excluded.source,
          cli_version = excluded.cli_version,
          model_provider = excluded.model_provider,
          size_bytes = excluded.size_bytes,
          line_count = excluded.line_count,
          event_count = excluded.event_count,
          tool_call_count = excluded.tool_call_count,
          user_prompt_excerpt = excluded.user_prompt_excerpt,
          latest_agent_message_excerpt = excluded.latest_agent_message_excerpt,
          status = excluded.status,
          updated_at = excluded.updated_at,
          indexed_at = excluded.indexed_at
      `,
      )
      .run({
        ...summary,
        ...mutation,
        snapshotPath: existing?.snapshotPath ?? null,
        createdAt,
        updatedAt,
        indexedAt: now,
      });

    return this.requireSession(summary.id);
  }
  updateSession(id: string, mutation: SessionMutation) {
    const existing = this.requireSession(id);
    const now = new Date().toISOString();
    const next = { ...existing, ...mutation };

    this.db
      .prepare(
        `
        update sessions
        set active_path = @activePath,
            archive_path = @archivePath,
            snapshot_path = @snapshotPath,
            original_relative_path = @originalRelativePath,
            cwd = @cwd,
            started_at = @startedAt,
            originator = @originator,
            source = @source,
            cli_version = @cliVersion,
            model_provider = @modelProvider,
            size_bytes = @sizeBytes,
            line_count = @lineCount,
            event_count = @eventCount,
            tool_call_count = @toolCallCount,
            user_prompt_excerpt = @userPromptExcerpt,
            latest_agent_message_excerpt = @latestAgentMessageExcerpt,
            status = @status,
            updated_at = @updatedAt,
            indexed_at = @indexedAt
        where id = @id
      `,
      )
      .run({
        ...next,
        updatedAt: now,
        indexedAt: now,
      });

    return this.requireSession(id);
  }
  deleteSession(id: string) {
    const existing = this.requireSession(id);

    this.db.prepare("delete from sessions where id = ?").run(id);

    return existing;
  }
  listSessions(filters: SessionFilters = {}) {
    const clauses = ["1 = 1"];
    const params: Record<string, string> = {};

    if (filters.query) {
      clauses.push(
        "(id like @query or cwd like @query or user_prompt_excerpt like @query or latest_agent_message_excerpt like @query)",
      );
      params.query = `%${filters.query}%`;
    }

    if (filters.status) {
      if (filters.status === "archived") {
        clauses.push("(status = @status or status = 'restorable')");
        params.status = filters.status;
      } else {
        clauses.push("status = @status");
        params.status = filters.status;
      }
    }

    if (filters.cwd) {
      clauses.push("cwd = @cwd");
      params.cwd = filters.cwd;
    }

    const rows = this.db
      .prepare(
        `
        select
          id,
          coalesce(active_path, archive_path, snapshot_path) as filePath,
          active_path as activePath,
          archive_path as archivePath,
          snapshot_path as snapshotPath,
          original_relative_path as originalRelativePath,
          cwd,
          started_at as startedAt,
          originator,
          source,
          cli_version as cliVersion,
          model_provider as modelProvider,
          size_bytes as sizeBytes,
          line_count as lineCount,
          event_count as eventCount,
          tool_call_count as toolCallCount,
          user_prompt_excerpt as userPromptExcerpt,
          latest_agent_message_excerpt as latestAgentMessageExcerpt,
          status,
          created_at,
          updated_at,
          indexed_at
        from sessions
        where ${clauses.join(" and ")}
        order by started_at desc, id asc
      `,
      )
      .all(params) as SessionRow[];

    return rows.map(mapSessionRow);
  }
  getSession(id: string) {
    const row = this.db
      .prepare(
        `
        select
          id,
          coalesce(active_path, archive_path, snapshot_path) as filePath,
          active_path as activePath,
          archive_path as archivePath,
          snapshot_path as snapshotPath,
          original_relative_path as originalRelativePath,
          cwd,
          started_at as startedAt,
          originator,
          source,
          cli_version as cliVersion,
          model_provider as modelProvider,
          size_bytes as sizeBytes,
          line_count as lineCount,
          event_count as eventCount,
          tool_call_count as toolCallCount,
          user_prompt_excerpt as userPromptExcerpt,
          latest_agent_message_excerpt as latestAgentMessageExcerpt,
          status,
          created_at,
          updated_at,
          indexed_at
        from sessions
        where id = ?
      `,
      )
      .get(id) as SessionRow | undefined;

    return row ? mapSessionRow(row) : null;
  }
  requireSession(id: string) {
    const session = this.getSession(id);
    if (!session) {
      throw new Error(`Session not found: ${id}`);
    }

    return session;
  }
  listDetails(id: string) {
    return {
      record: this.requireSession(id),
      auditEntries: this.listAuditEntries(id),
      timeline: [],
      timelineTotal: 0,
      timelineNextOffset: null,
    };
  }
  listAllIds() {
    return this.db.prepare("select id from sessions").all() as Array<{ id: string }>;
  }
  insertAudit(
    action: string,
    sessionId: string,
    sourcePath: string | null,
    targetPath: string | null,
    details: Record<string, string | boolean | null> = {},
  ) {
    this.db
      .prepare(
        `
        insert into audit_log (action, session_id, source_path, target_path, details_json, created_at)
        values (?, ?, ?, ?, ?, ?)
      `,
      )
      .run(
        action,
        sessionId,
        sourcePath,
        targetPath,
        JSON.stringify(details),
        new Date().toISOString(),
      );
  }
  private listAuditEntries(sessionId: string): AuditEntry[] {
    const rows = this.db
      .prepare(
        `
        select id, action, session_id, source_path, target_path, details_json, created_at
        from audit_log
        where session_id = ?
        order by id desc
      `,
      )
      .all(sessionId) as AuditRow[];

    return rows.map(mapAuditRow);
  }

  private ensureSchema() {
    const columns = this.db
      .prepare("pragma table_info(sessions)")
      .all() as Array<{ name?: unknown }>;
    const columnNames = new Set(
      columns
        .map((column) => (typeof column.name === "string" ? column.name : ""))
        .filter(Boolean),
    );

    if (!columnNames.has("indexed_at")) {
      this.db.exec(`
        alter table sessions add column indexed_at text;
        update sessions
        set indexed_at = coalesce(indexed_at, updated_at, created_at, CURRENT_TIMESTAMP);
      `);
    }
  }
}

function didSessionSummaryChange(
  existing: {
    activePath: string | null;
    archivePath: string | null;
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
    status: string;
  },
  summary: SessionFileSummary,
  mutation: Pick<
    SessionMutation,
    "activePath" | "archivePath" | "originalRelativePath" | "status"
  >,
) {
  return (
    existing.activePath !== mutation.activePath ||
    existing.archivePath !== mutation.archivePath ||
    existing.originalRelativePath !== mutation.originalRelativePath ||
    existing.cwd !== summary.cwd ||
    existing.startedAt !== summary.startedAt ||
    existing.originator !== summary.originator ||
    existing.source !== summary.source ||
    existing.cliVersion !== summary.cliVersion ||
    existing.modelProvider !== summary.modelProvider ||
    existing.sizeBytes !== summary.sizeBytes ||
    existing.lineCount !== summary.lineCount ||
    existing.eventCount !== summary.eventCount ||
    existing.toolCallCount !== summary.toolCallCount ||
    existing.userPromptExcerpt !== summary.userPromptExcerpt ||
    existing.latestAgentMessageExcerpt !== summary.latestAgentMessageExcerpt ||
    existing.status !== mutation.status
  );
}
