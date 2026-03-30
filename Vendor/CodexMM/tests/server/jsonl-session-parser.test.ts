import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import { afterEach, beforeEach, describe, expect, test } from "vitest";

import {
  parseSessionFile,
  parseSessionTimeline,
} from "../../src/server/services/jsonl-session-parser";
import { createHarness, seedSession, type TestHarness } from "./support";

describe("parseSessionFile", () => {
  let harness: TestHarness;

  beforeEach(async () => {
    harness = await createHarness();
  });

  afterEach(async () => {
    await harness.cleanup();
  });

  test("normalizes structured session metadata into SQLite-safe strings", async () => {
    const filePath = path.join(harness.codexHome, "sessions", "2026", "03", "29", "subagent.jsonl");
    await mkdir(path.dirname(filePath), { recursive: true });
    await writeFile(
      filePath,
      [
        JSON.stringify({
          timestamp: "2026-03-29T10:16:37.087Z",
          type: "session_meta",
          payload: {
            id: "subagent-session",
            timestamp: "2026-03-29T10:16:37.087Z",
            cwd: "/work/subagent",
            originator: "Codex Desktop",
            source: {
              subagent: {
                thread_spawn: {
                  agent_role: "explorer",
                },
              },
            },
            cli_version: "0.118.0-alpha.2",
            model_provider: "openai",
          },
        }),
        JSON.stringify({
          timestamp: "2026-03-29T10:16:38.000Z",
          type: "event_msg",
          payload: {
            type: "user_message",
            message: "查看子代理来源",
          },
        }),
      ].join("\n"),
    );

    const summary = await parseSessionFile(filePath);

    expect(summary?.source).toBe("subagent:explorer");
  });

  test("parses a full timeline with chat messages and collapsible tool calls", async () => {
    const filePath = await seedSession(harness.codexHome, {
      id: "timeline-session",
      cwd: "/work/timeline",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "帮我列出项目文件",
      latestAgentMessage: "已经整理完成。",
      timeline: [
        {
          type: "message:user",
          text: "帮我列出项目文件",
        },
        {
          type: "tool_call",
          toolName: "shell",
          input: "rg --files",
          output: "README.md\nsrc/app.ts",
        },
        {
          type: "message:assistant",
          text: "我找到了两个文件：README.md 和 src/app.ts。",
        },
      ],
    });

    const timeline = await parseSessionTimeline(filePath);

    expect(timeline).toHaveLength(3);
    expect(timeline[0]).toMatchObject({
      type: "message:user",
      text: "帮我列出项目文件",
    });
    expect(timeline[1]).toMatchObject({
      type: "tool_call",
      toolName: "shell",
      input: "rg --files",
      output: "README.md\nsrc/app.ts",
      status: "completed",
    });
    expect(timeline[2]).toMatchObject({
      type: "message:assistant",
      text: "我找到了两个文件：README.md 和 src/app.ts。",
    });
  });

  test("falls back to event messages when the session has no response-item messages", async () => {
    const filePath = await seedSession(harness.codexHome, {
      id: "timeline-fallback",
      cwd: "/work/timeline-fallback",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "只看 event_msg",
      latestAgentMessage: "这里没有 response_item 消息。",
    });

    const timeline = await parseSessionTimeline(filePath);

    expect(timeline).toHaveLength(2);
    expect(timeline.map((entry) => entry.type)).toEqual([
      "message:user",
      "message:assistant",
    ]);
  });

  test("merges event messages with response-item messages instead of dropping the fallback entries", async () => {
    const filePath = path.join(
      harness.codexHome,
      "sessions",
      "2026",
      "03",
      "29",
      "timeline-mixed.jsonl",
    );
    await mkdir(path.dirname(filePath), { recursive: true });
    await writeFile(
      filePath,
      [
        JSON.stringify({
          timestamp: "2026-03-29T10:16:37.087Z",
          type: "session_meta",
          payload: {
            id: "timeline-mixed",
            timestamp: "2026-03-29T10:16:37.087Z",
            cwd: "/work/timeline-mixed",
          },
        }),
        JSON.stringify({
          timestamp: "2026-03-29T10:16:38.000Z",
          type: "event_msg",
          payload: {
            type: "user_message",
            message: "先保留 event_msg 里的用户消息",
          },
        }),
        JSON.stringify({
          timestamp: "2026-03-29T10:16:39.000Z",
          type: "response_item",
          payload: {
            type: "message",
            role: "assistant",
            content: [{ text: "再追加 response_item 里的助手消息" }],
          },
        }),
      ].join("\n"),
    );

    const timeline = await parseSessionTimeline(filePath);

    expect(timeline).toHaveLength(2);
    expect(timeline[0]).toMatchObject({
      type: "message:user",
      text: "先保留 event_msg 里的用户消息",
    });
    expect(timeline[1]).toMatchObject({
      type: "message:assistant",
      text: "再追加 response_item 里的助手消息",
    });
  });
});
