import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import express from "express";
import request from "supertest";
import { afterEach, beforeEach, describe, expect, test } from "vitest";

import { mountClientAssets } from "../../src/server/static-client";
import { createHarness, type TestHarness } from "./support";

describe("mountClientAssets", () => {
  let harness: TestHarness;

  beforeEach(async () => {
    harness = await createHarness();
  });

  afterEach(async () => {
    await harness.cleanup();
  });

  test("serves index.html for root requests without throwing on Express 5", async () => {
    const clientDistPath = path.join(harness.managerHome, "client-dist");
    await mkdir(clientDistPath, { recursive: true });
    await writeFile(path.join(clientDistPath, "index.html"), "<html>ok</html>");

    const app = express();
    mountClientAssets(app, clientDistPath);

    const response = await request(app).get("/").expect(200);

    expect(response.text).toContain("ok");
  });
});
