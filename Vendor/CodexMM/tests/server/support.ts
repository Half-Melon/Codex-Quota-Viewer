import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import Database from "better-sqlite3";

type SessionSeed = {
  id: string;
  cwd: string;
  startedAt: string;
  firstUserMessage: string;
  latestAgentMessage: string;
  toolCalls?: number;
  timeline?: SessionTimelineSeed[];
  registerOfficialThread?: boolean;
  registerSessionIndex?: boolean;
};

type SessionTimelineSeed =
  | {
      type: "message:user" | "message:assistant";
      text: string;
      timestamp?: string;
    }
  | {
      type: "tool_call";
      toolName: string;
      input?: string;
      output?: string;
      timestamp?: string;
    };

export type TestHarness = {
  codexHome: string;
  managerHome: string;
  cleanup: () => Promise<void>;
};

export async function createHarness(): Promise<TestHarness> {
  const root = await mkdtemp(path.join(tmpdir(), "codex-session-manager-"));
  const codexHome = path.join(root, ".codex");
  const managerHome = path.join(root, ".codex-session-manager");

  await mkdir(path.join(codexHome, "sessions"), { recursive: true });
  await writeFile(path.join(codexHome, "session_index.jsonl"), "");
  await seedOfficialStateDatabase(codexHome);
  await mkdir(managerHome, { recursive: true });

  return {
    codexHome,
    managerHome,
    cleanup: async () => rm(root, { recursive: true, force: true }),
  };
}

export async function seedSession(
  codexHome: string,
  session: SessionSeed,
): Promise<string> {
  const started = new Date(session.startedAt);
  const year = `${started.getUTCFullYear()}`;
  const month = `${started.getUTCMonth() + 1}`.padStart(2, "0");
  const day = `${started.getUTCDate()}`.padStart(2, "0");
  const folder = path.join(codexHome, "sessions", year, month, day);
  const filePath = path.join(
    folder,
    `rollout-${session.startedAt.replaceAll(":", "-")}-${session.id}.jsonl`,
  );

  const lines = [
    JSON.stringify({
      timestamp: session.startedAt,
      type: "session_meta",
      payload: {
        id: session.id,
        timestamp: session.startedAt,
        cwd: session.cwd,
        originator: "Codex Desktop",
        source: "vscode",
        cli_version: "0.118.0-alpha.2",
        model_provider: "openai",
      },
    }),
    JSON.stringify({
      timestamp: session.startedAt,
      type: "event_msg",
      payload: {
        type: "user_message",
        message: session.firstUserMessage,
      },
    }),
    JSON.stringify({
      timestamp: session.startedAt,
      type: "event_msg",
      payload: {
        type: "agent_message",
        message: session.latestAgentMessage,
      },
    }),
    ...(session.timeline ?? []).flatMap((entry, index) =>
      buildTimelineEntries(session.startedAt, entry, index),
    ),
    ...Array.from({ length: session.toolCalls ?? 0 }, (_, index) =>
      JSON.stringify({
        timestamp: session.startedAt,
        type: "response_item",
        payload: {
          type: "function_call",
          name: `tool-${index + 1}`,
        },
      }),
    ),
  ];

  await mkdir(folder, { recursive: true });
  await writeFile(filePath, lines.join("\n"));

  if (session.registerOfficialThread !== false) {
    upsertOfficialThread(codexHome, {
      id: session.id,
      rolloutPath: filePath,
      cwd: session.cwd,
      startedAt: session.startedAt,
      title: session.firstUserMessage,
      firstUserMessage: session.firstUserMessage,
      cliVersion: "0.118.0-alpha.2",
      modelProvider: "openai",
    });
  }

  if (session.registerSessionIndex !== false) {
    await upsertSessionIndexEntry(codexHome, {
      id: session.id,
      threadName: session.firstUserMessage,
      updatedAt: session.startedAt,
    });
  }

  return filePath;
}

export function readOfficialThread(codexHome: string, sessionId: string) {
  const db = new Database(path.join(codexHome, "state_5.sqlite"));
  const row = db
    .prepare(
      `
        select
          id,
          cwd,
          rollout_path as rolloutPath,
          archived,
          archived_at as archivedAt,
          updated_at as updatedAt
        from threads
        where id = ?
      `,
    )
    .get(sessionId) as
    | {
        id: string;
        cwd: string | null;
        rolloutPath: string;
        archived: number;
        archivedAt: number | null;
        updatedAt: number;
      }
    | undefined;
  db.close();
  return row ?? null;
}

export async function readSessionIndexEntry(codexHome: string, sessionId: string) {
  const entries = await listSessionIndexEntries(codexHome);
  return entries.find((entry) => entry.id === sessionId) ?? null;
}

export async function upsertSessionIndexEntry(
  codexHome: string,
  entry: {
    id: string;
    threadName: string;
    updatedAt: string;
  },
) {
  const filePath = path.join(codexHome, "session_index.jsonl");
  const entries = await listSessionIndexEntries(codexHome);
  const next = entries.filter((item) => item.id !== entry.id);

  next.push({
    id: entry.id,
    thread_name: entry.threadName,
    updated_at: entry.updatedAt,
  });

  next.sort((left, right) => Date.parse(right.updated_at) - Date.parse(left.updated_at));

  await writeFile(
    filePath,
    next.map((item) => JSON.stringify(item)).join("\n") + (next.length > 0 ? "\n" : ""),
  );
}

function buildTimelineEntries(
  startedAt: string,
  entry: SessionTimelineSeed,
  index: number,
) {
  const timestamp = entry.timestamp ?? addOffset(startedAt, (index + 1) * 1000);

  if (entry.type === "message:user" || entry.type === "message:assistant") {
    return [
      JSON.stringify({
        timestamp,
        type: "response_item",
        payload: {
          type: "message",
          role: entry.type === "message:user" ? "user" : "assistant",
          content: [
            {
              type: entry.type === "message:user" ? "input_text" : "output_text",
              text: entry.text,
            },
          ],
        },
      }),
    ];
  }

  const toolEntry = entry as Extract<SessionTimelineSeed, { type: "tool_call" }>;
  const callId = `call-${index + 1}`;
  const records = [
    JSON.stringify({
      timestamp,
      type: "response_item",
      payload: {
        type: "function_call",
        call_id: callId,
        name: toolEntry.toolName,
        arguments: toolEntry.input ?? "",
      },
    }),
  ];

  if (toolEntry.output !== undefined) {
    records.push(
      JSON.stringify({
        timestamp: addOffset(timestamp, 300),
        type: "response_item",
        payload: {
          type: "function_call_output",
          call_id: callId,
          output: toolEntry.output,
        },
      }),
    );
  }

  return records;
}

function addOffset(timestamp: string, offsetMs: number) {
  return new Date(Date.parse(timestamp) + offsetMs).toISOString();
}

async function listSessionIndexEntries(codexHome: string) {
  const filePath = path.join(codexHome, "session_index.jsonl");

  try {
    const content = await readFile(filePath, "utf8");
    return content
      .split(/\r?\n/u)
      .map((line) => line.trim())
      .filter(Boolean)
      .flatMap((line) => {
        try {
          return [JSON.parse(line) as { id: string; thread_name: string; updated_at: string }];
        } catch {
          return [];
        }
      });
  } catch {
    return [];
  }
}

async function seedOfficialStateDatabase(codexHome: string) {
  const db = new Database(path.join(codexHome, "state_5.sqlite"));
  db.exec(`
    create table if not exists threads (
      id text primary key,
      rollout_path text not null,
      created_at integer not null,
      updated_at integer not null,
      source text not null,
      model_provider text not null,
      cwd text not null,
      title text not null,
      sandbox_policy text not null,
      approval_mode text not null,
      tokens_used integer not null default 0,
      has_user_event integer not null default 0,
      archived integer not null default 0,
      archived_at integer,
      git_sha text,
      git_branch text,
      git_origin_url text,
      cli_version text not null default '',
      first_user_message text not null default '',
      agent_nickname text,
      agent_role text,
      memory_mode text not null default 'enabled',
      model text,
      reasoning_effort text,
      agent_path text
    );

    create index if not exists idx_threads_archived on threads(archived);
  `);
  db.close();
}

function upsertOfficialThread(
  codexHome: string,
  thread: {
    id: string;
    rolloutPath: string;
    cwd: string;
    startedAt: string;
    title: string;
    firstUserMessage: string;
    cliVersion: string;
    modelProvider: string;
  },
) {
  const db = new Database(path.join(codexHome, "state_5.sqlite"));
  const timestamp = Math.floor(Date.parse(thread.startedAt) / 1000);
  db.prepare(
    `
      insert into threads (
        id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
        sandbox_policy, approval_mode, tokens_used, has_user_event, archived, archived_at,
        cli_version, first_user_message, memory_mode
      ) values (
        @id, @rolloutPath, @createdAt, @updatedAt, @source, @modelProvider, @cwd, @title,
        @sandboxPolicy, @approvalMode, 0, 1, 0, null,
        @cliVersion, @firstUserMessage, 'enabled'
      )
      on conflict(id) do update set
        rollout_path = excluded.rollout_path,
        updated_at = excluded.updated_at,
        cwd = excluded.cwd,
        title = excluded.title,
        cli_version = excluded.cli_version,
        first_user_message = excluded.first_user_message
    `,
  ).run({
    id: thread.id,
    rolloutPath: thread.rolloutPath,
    createdAt: timestamp,
    updatedAt: timestamp,
    source: "desktop",
    modelProvider: thread.modelProvider,
    cwd: thread.cwd,
    title: thread.title,
    sandboxPolicy: "workspace-write",
    approvalMode: "default",
    cliVersion: thread.cliVersion,
    firstUserMessage: thread.firstUserMessage,
  });
  db.close();
}
