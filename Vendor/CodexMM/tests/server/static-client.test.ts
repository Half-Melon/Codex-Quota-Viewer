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

  test("serves localized index.html for root requests without throwing on Express 5", async () => {
    const clientDistPath = path.join(harness.managerHome, "client-dist");
    await mkdir(clientDistPath, { recursive: true });
    await writeFile(
      path.join(clientDistPath, "index.html"),
      '<!doctype html><html lang="en-US"><head><title>ok</title></head><body>ok</body></html>',
    );

    const app = express();
    mountClientAssets(app, clientDistPath, () => ({ language: "zh" }));

    const response = await request(app).get("/").expect(200);

    expect(response.text).toContain("ok");
    expect(response.text).toContain('window.__CODEX_VIEWER_UI_CONFIG__={"language":"zh"}');
    expect(response.text).toContain('<html lang="zh-CN">');
  });
});
