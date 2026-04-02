import Database from "better-sqlite3";

import type {
  AuditEntry,
  SessionFilters,
  SessionTimelinePage,
} from "../../shared/contracts";
import {
  mapAuditRow,
  mapSessionRow,
  mapTimelineItemRow,
  type AuditRow,
  type CatalogSessionEntry,
  type SessionMutation,
  type SessionRow,
  type TimelineItemRow,
} from "./session-repository-model";

const SESSION_SELECT_COLUMNS = `
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
`;

export class SessionRepository {
  private readonly db: Database.Database;

  constructor(databasePath: string) {
    this.db = new Database(databasePath);
    this.db.pragma("journal_mode = WAL");
    this.ensureSchema();
  }

  replaceCatalog(entries: CatalogSessionEntry[]) {
    const existingById = this.readAllSessionRows();
    const indexedAt = new Date().toISOString();
    const insertSession = this.db.prepare(`
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
    `);
    const insertTimelineItem = this.db.prepare(`
      insert into timeline_items (
        session_id, ordinal, item_id, type, timestamp, text,
        tool_name, summary, input_text, output_text, status
      ) values (
        @sessionId, @ordinal, @itemId, @type, @timestamp, @text,
        @toolName, @summary, @inputText, @outputText, @status
      )
    `);
    const insertSearch = this.db.prepare(`
      insert into session_search (
        session_id, id, cwd, user_prompt_excerpt, latest_agent_message_excerpt
      ) values (
        @sessionId, @id, @cwd, @userPromptExcerpt, @latestAgentMessageExcerpt
      )
    `);
    const rebuildCatalog = this.db.transaction((catalogEntries: CatalogSessionEntry[]) => {
      this.db.prepare("delete from timeline_items").run();
      this.db.prepare("delete from sessions").run();
      this.clearSessionSearch();

      for (const entry of catalogEntries) {
        const existing = existingById.get(entry.summary.id);
        const createdAt = existing?.created_at ?? indexedAt;
        const updatedAt =
          existing && !didCatalogEntryChange(existing, entry)
            ? existing.updated_at
            : indexedAt;

        insertSession.run({
          ...entry.summary,
          activePath: entry.activePath,
          archivePath: entry.archivePath,
          snapshotPath: entry.snapshotPath,
          originalRelativePath: entry.originalRelativePath,
          status: entry.status,
          createdAt,
          updatedAt,
          indexedAt,
        });
        insertSearch.run({
          sessionId: entry.summary.id,
          id: entry.summary.id,
          cwd: entry.summary.cwd,
          userPromptExcerpt: entry.summary.userPromptExcerpt,
          latestAgentMessageExcerpt: entry.summary.latestAgentMessageExcerpt,
        });

        entry.timeline.forEach((item, ordinal) => {
          insertTimelineItem.run(toTimelineRow(entry.summary.id, ordinal, item));
        });
      }
    });

    rebuildCatalog(entries);
    return this.listSessions();
  }

  saveCatalogEntry(entry: CatalogSessionEntry) {
    const now = new Date().toISOString();
    const existing = this.readSessionRowsByIds([entry.summary.id]).get(entry.summary.id);
    const upsertSession = this.db.prepare(`
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
        created_at = excluded.created_at,
        updated_at = excluded.updated_at,
        indexed_at = excluded.indexed_at
    `);
    const deleteTimelineItems = this.db.prepare(
      "delete from timeline_items where session_id = ?",
    );
    const deleteSearchEntry = this.db.prepare(
      "delete from session_search where session_id = ?",
    );
    const insertTimelineItem = this.db.prepare(`
      insert into timeline_items (
        session_id, ordinal, item_id, type, timestamp, text,
        tool_name, summary, input_text, output_text, status
      ) values (
        @sessionId, @ordinal, @itemId, @type, @timestamp, @text,
        @toolName, @summary, @inputText, @outputText, @status
      )
    `);
    const insertSearch = this.db.prepare(`
      insert into session_search (
        session_id, id, cwd, user_prompt_excerpt, latest_agent_message_excerpt
      ) values (
        @sessionId, @id, @cwd, @userPromptExcerpt, @latestAgentMessageExcerpt
      )
    `);
    const persistCatalogEntry = this.db.transaction((catalogEntry: CatalogSessionEntry) => {
      const createdAt = existing?.created_at ?? now;
      const updatedAt =
        existing && !didCatalogEntryChange(existing, catalogEntry)
          ? existing.updated_at
          : now;

      upsertSession.run({
        ...catalogEntry.summary,
        activePath: catalogEntry.activePath,
        archivePath: catalogEntry.archivePath,
        snapshotPath: catalogEntry.snapshotPath,
        originalRelativePath: catalogEntry.originalRelativePath,
        status: catalogEntry.status,
        createdAt,
        updatedAt,
        indexedAt: now,
      });

      deleteTimelineItems.run(catalogEntry.summary.id);
      deleteSearchEntry.run(catalogEntry.summary.id);
      insertSearch.run({
        sessionId: catalogEntry.summary.id,
        id: catalogEntry.summary.id,
        cwd: catalogEntry.summary.cwd,
        userPromptExcerpt: catalogEntry.summary.userPromptExcerpt,
        latestAgentMessageExcerpt: catalogEntry.summary.latestAgentMessageExcerpt,
      });

      catalogEntry.timeline.forEach((item, ordinal) => {
        insertTimelineItem.run(toTimelineRow(catalogEntry.summary.id, ordinal, item));
      });
    });

    persistCatalogEntry(entry);
    return this.requireSession(entry.summary.id);
  }

  updateSession(id: string, mutation: SessionMutation) {
    const existing = this.requireSession(id);
    const now = new Date().toISOString();
    const next = {
      ...existing,
      ...mutation,
    };

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

    this.db
      .prepare("delete from session_search where session_id = ?")
      .run(id);
    this.db
      .prepare(
        `
        insert into session_search (
          session_id, id, cwd, user_prompt_excerpt, latest_agent_message_excerpt
        ) values (?, ?, ?, ?, ?)
      `,
      )
      .run(
        id,
        id,
        next.cwd,
        next.userPromptExcerpt,
        next.latestAgentMessageExcerpt,
      );

    return this.requireSession(id);
  }

  deleteSession(id: string) {
    const existing = this.requireSession(id);

    this.db.prepare("delete from timeline_items where session_id = ?").run(id);
    this.db.prepare("delete from session_search where session_id = ?").run(id);
    this.db.prepare("delete from sessions where id = ?").run(id);

    return existing;
  }

  listSessions(filters: SessionFilters = {}) {
    if (filters.query) {
      try {
        return this.listSessionsWithFts(filters);
      } catch {
        return this.listSessionsWithLike(filters);
      }
    }

    return this.listSessionsWithoutQuery(filters);
  }

  getSession(id: string) {
    const row = this.db
      .prepare(
        `
        select
          ${SESSION_SELECT_COLUMNS}
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

  listTimelinePage(
    sessionId: string,
    options: {
      offset?: number;
      limit: number;
    },
  ): SessionTimelinePage {
    const offset = Math.max(options.offset ?? 0, 0);
    const totalRow = this.db
      .prepare(
        `
        select count(*) as count
        from timeline_items
        where session_id = ?
      `,
      )
      .get(sessionId) as { count: number };
    const rows = this.db
      .prepare(
        `
        select
          item_id,
          type,
          timestamp,
          text,
          tool_name,
          summary,
          input_text,
          output_text,
          status
        from timeline_items
        where session_id = ?
        order by ordinal asc
        limit ?
        offset ?
      `,
      )
      .all(sessionId, options.limit, offset) as TimelineItemRow[];
    const total = totalRow.count;

    return {
      items: rows.map(mapTimelineItemRow),
      total,
      nextOffset: offset + options.limit < total ? offset + options.limit : null,
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

  listLatestAuditEntries(): AuditEntry[] {
    const rows = this.db
      .prepare(
        `
        select a.id, a.action, a.session_id, a.source_path, a.target_path, a.details_json, a.created_at
        from audit_log a
        inner join (
          select session_id, max(id) as max_id
          from audit_log
          group by session_id
        ) latest
          on latest.session_id = a.session_id
         and latest.max_id = a.id
        order by a.id asc
      `,
      )
      .all() as AuditRow[];

    return rows.map(mapAuditRow);
  }

  private listSessionsWithoutQuery(filters: SessionFilters) {
    const { clause, params } = buildSessionFilterClause(filters);
    const rows = this.db
      .prepare(
        `
        select
          ${SESSION_SELECT_COLUMNS}
        from sessions
        where ${clause}
        order by started_at desc, id asc
      `,
      )
      .all(params) as SessionRow[];

    return rows.map(mapSessionRow);
  }

  private listSessionsWithLike(filters: SessionFilters) {
    const { clause, params } = buildSessionFilterClause(filters);
    const rows = this.db
      .prepare(
        `
        select
          ${SESSION_SELECT_COLUMNS}
        from sessions
        where ${clause}
          and (
            id like @query
            or cwd like @query
            or user_prompt_excerpt like @query
            or latest_agent_message_excerpt like @query
          )
        order by started_at desc, id asc
      `,
      )
      .all({
        ...params,
        query: `%${filters.query}%`,
      }) as SessionRow[];

    return rows.map(mapSessionRow);
  }

  private listSessionsWithFts(filters: SessionFilters) {
    const { clause, params } = buildSessionFilterClause(filters);
    const rows = this.db
      .prepare(
        `
        select
          ${SESSION_SELECT_COLUMNS}
        from sessions
        inner join session_search
          on session_search.session_id = sessions.id
        where ${clause}
          and session_search match @query
        order by started_at desc, id asc
      `,
      )
      .all({
        ...params,
        query: filters.query,
      }) as SessionRow[];

    return rows.map(mapSessionRow);
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

      create table if not exists timeline_items (
        session_id text not null,
        ordinal integer not null,
        item_id text not null,
        type text not null,
        timestamp text not null,
        text text,
        tool_name text,
        summary text,
        input_text text,
        output_text text,
        status text,
        primary key (session_id, ordinal)
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

      create virtual table if not exists session_search using fts5(
        session_id UNINDEXED,
        id,
        cwd,
        user_prompt_excerpt,
        latest_agent_message_excerpt
      );

      create index if not exists idx_sessions_status_started_at
        on sessions(status, started_at desc);
      create index if not exists idx_sessions_cwd_started_at
        on sessions(cwd, started_at desc);
      create index if not exists idx_sessions_started_at
        on sessions(started_at desc);
      create index if not exists idx_timeline_items_session_ordinal
        on timeline_items(session_id, ordinal asc);
    `);

    this.ensureLegacyColumns();
  }

  private ensureLegacyColumns() {
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

  private clearSessionSearch() {
    this.db.prepare("delete from session_search").run();
  }

  private readAllSessionRows() {
    const rows = this.db
      .prepare(
        `
        select
          ${SESSION_SELECT_COLUMNS}
        from sessions
      `,
      )
      .all() as SessionRow[];

    return new Map(rows.map((row) => [row.id, row]));
  }

  private readSessionRowsByIds(ids: string[]) {
    if (ids.length === 0) {
      return new Map<string, SessionRow>();
    }

    const placeholders = ids.map(() => "?").join(", ");
    const rows = this.db
      .prepare(
        `
        select
          ${SESSION_SELECT_COLUMNS}
        from sessions
        where id in (${placeholders})
      `,
      )
      .all(...ids) as SessionRow[];

    return new Map(rows.map((row) => [row.id, row]));
  }
}

function buildSessionFilterClause(filters: SessionFilters) {
  const clauses = ["1 = 1"];
  const params: Record<string, string> = {};

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

  return {
    clause: clauses.join(" and "),
    params,
  };
}

function didCatalogEntryChange(
  existing: SessionRow,
  entry: CatalogSessionEntry,
) {
  const summary = entry.summary;

  return (
    existing.activePath !== entry.activePath ||
    existing.archivePath !== entry.archivePath ||
    existing.snapshotPath !== entry.snapshotPath ||
    existing.originalRelativePath !== entry.originalRelativePath ||
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
    existing.status !== entry.status
  );
}

function toTimelineRow(
  sessionId: string,
  ordinal: number,
  item: CatalogSessionEntry["timeline"][number],
) {
  if (item.type === "tool_call") {
    return {
      sessionId,
      ordinal,
      itemId: item.id,
      type: item.type,
      timestamp: item.timestamp,
      text: null,
      toolName: item.toolName,
      summary: item.summary,
      inputText: item.input,
      outputText: item.output,
      status: item.status,
    };
  }

  return {
    sessionId,
    ordinal,
    itemId: item.id,
    type: item.type,
    timestamp: item.timestamp,
    text: item.text,
    toolName: null,
    summary: null,
    inputText: null,
    outputText: null,
    status: null,
  };
}
