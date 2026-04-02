import path from "node:path";

import { afterEach, describe, expect, test, vi } from "vitest";

describe("CodexSessionIndexRepository", () => {
  afterEach(() => {
    vi.resetModules();
    vi.doUnmock("node:fs/promises");
  });

  test("writes session_index.jsonl through a temp file before renaming it into place", async () => {
    const mkdir = vi.fn(async () => undefined);
    const readFile = vi.fn(async () => "");
    const writeFile = vi.fn(async () => undefined);
    const rename = vi.fn(async () => undefined);

    vi.doMock("node:fs/promises", () => ({
      mkdir,
      readFile,
      writeFile,
      rename,
    }));

    const { CodexSessionIndexRepository } = await import(
      "../../src/server/services/codex-session-index-repository"
    );
    const repository = new CodexSessionIndexRepository("/tmp/codex-home");
    const finalPath = path.join("/tmp/codex-home", "session_index.jsonl");

    await repository.replaceEntries([
      {
        id: "session-alpha",
        threadName: "Alpha",
        updatedAt: "2026-03-29T10:16:37.087Z",
      },
      {
        id: "session-beta",
        threadName: "Beta",
        updatedAt: "2026-03-30T10:16:37.087Z",
      },
    ]);

    expect(writeFile).toHaveBeenCalledTimes(1);
    const firstCall = writeFile.mock.calls[0] as unknown[] | undefined;

    if (!firstCall) {
      throw new Error("expected writeFile to be called");
    }

    const [tempPath, content] = firstCall;

    if (typeof tempPath !== "string" || typeof content !== "string") {
      throw new Error("expected writeFile to receive a path and string content");
    }

    expect(tempPath).not.toBe(finalPath);
    expect(path.dirname(tempPath)).toBe(path.dirname(finalPath));
    expect(path.basename(tempPath)).toContain("session_index.jsonl");
    expect(content).toBe(
      [
        JSON.stringify({
          id: "session-beta",
          thread_name: "Beta",
          updated_at: "2026-03-30T10:16:37.087Z",
        }),
        JSON.stringify({
          id: "session-alpha",
          thread_name: "Alpha",
          updated_at: "2026-03-29T10:16:37.087Z",
        }),
        "",
      ].join("\n"),
    );
    expect(rename).toHaveBeenCalledTimes(1);
    expect(rename).toHaveBeenCalledWith(tempPath, finalPath);
  });
});
