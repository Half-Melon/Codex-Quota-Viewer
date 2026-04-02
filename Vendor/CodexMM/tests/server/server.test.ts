import { afterEach, describe, expect, test } from "vitest";

import { startServer } from "../../src/server/server";

describe("startServer", () => {
  const servers: Array<{ close: () => void }> = [];

  afterEach(() => {
    while (servers.length > 0) {
      const server = servers.pop();
      server?.close();
    }
  });

  test("binds the HTTP server to 127.0.0.1 by default", async () => {
    const server = await startServer({
      port: 0,
      codexHome: "/tmp/codex-home",
      managerHome: "/tmp/codex-manager-home",
      clientDistPath: "/tmp/codex-client-dist",
    });
    servers.push(server);

    const address = server.address();
    expect(address && typeof address === "object" ? address.address : null).toBe("127.0.0.1");
  });
});
