import path from "node:path";
import { pathToFileURL } from "node:url";

import { describe, expect, test } from "vitest";

import { resolveClientDistPath } from "../../src/server/runtime-paths";

describe("resolveClientDistPath", () => {
  test("prefers explicit environment override", () => {
    const resolved = resolveClientDistPath(
      {
        CODEX_SESSION_MANAGER_CLIENT_DIST: "/tmp/custom-client",
      } as NodeJS.ProcessEnv,
      pathToFileURL("/tmp/project/dist/server/index.js").href,
      "/tmp/project",
    );

    expect(resolved).toBe("/tmp/custom-client");
  });

  test("resolves bundled dist/client relative to the built server entry", () => {
    const resolved = resolveClientDistPath(
      {} as NodeJS.ProcessEnv,
      pathToFileURL("/tmp/SessionManager/App/dist/server/index.js").href,
      "/tmp/project",
    );

    expect(resolved).toBe("/tmp/SessionManager/App/dist/client");
  });

  test("falls back to the project dist/client directory during source development", () => {
    const resolved = resolveClientDistPath(
      {} as NodeJS.ProcessEnv,
      pathToFileURL("/tmp/project/src/server/index.ts").href,
      "/tmp/project",
    );

    expect(resolved).toBe(path.join("/tmp/project", "dist", "client"));
  });
});
