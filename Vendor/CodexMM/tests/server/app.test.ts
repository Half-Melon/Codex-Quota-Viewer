import { chmod, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import request from "supertest";
import { afterEach, beforeEach, describe, expect, test } from "vitest";

import { createApp } from "../../src/server/app";
import {
  createHarness,
  readOfficialThread,
  readSessionIndexEntry,
  seedSession,
  type TestHarness,
} from "./support";

describe("createApp", () => {
  let harness: TestHarness;

  beforeEach(async () => {
    harness = await createHarness();
  });

  afterEach(async () => {
    await harness.cleanup();
  });

  test("lists indexed sessions over HTTP", async () => {
    await seedSession(harness.codexHome, {
      id: "http-list",
      cwd: "/work/http-list",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "通过接口列出会话",
      latestAgentMessage: "列表已经准备好。",
    });

    const app = createApp({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });

    await request(app).post("/api/sessions/rescan").send({}).expect(200);
    const response = await request(app).get("/api/sessions").expect(200);

    expect(response.body.sessions).toHaveLength(1);
    expect(response.body.sessions[0].id).toBe("http-list");
  });

  test("restores a session and returns a resume command", async () => {
    const projectDir = path.join(harness.managerHome, "resume-target");
    await seedSession(harness.codexHome, {
      id: "http-restore",
      cwd: "/work/http-restore",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "恢复它",
      latestAgentMessage: "已经恢复。",
    });

    const app = createApp({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });

    await mkdir(projectDir, { recursive: true });
    await request(app).post("/api/sessions/rescan").send({}).expect(200);
    await request(app).post("/api/sessions/http-restore/archive").send({}).expect(200);
    const response = await request(app)
      .post("/api/sessions/http-restore/restore")
      .send({
        targetCwd: projectDir,
        restoreMode: "resume_only",
      })
      .expect(200);

    expect(response.body.resumeCommand).toBe(
      `codex resume http-restore -C ${projectDir}`,
    );
    expect(response.body.record.status).toBe("active");
  });

  test("returns paginated timeline data over HTTP", async () => {
    await seedSession(harness.codexHome, {
      id: "http-timeline-page",
      cwd: "/work/http-timeline-page",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "分页加载时间线",
      latestAgentMessage: "首屏先返回 200 条。",
      timeline: Array.from({ length: 205 }, (_, index) => ({
        type: (index % 2 === 0 ? "message:user" : "message:assistant") as
          | "message:user"
          | "message:assistant",
        text: `timeline-${index + 1}`,
      })),
    });

    const app = createApp({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });

    await request(app).post("/api/sessions/rescan").send({}).expect(200);

    const detailResponse = await request(app)
      .get("/api/sessions/http-timeline-page")
      .expect(200);

    expect(detailResponse.body.timeline).toHaveLength(200);
    expect(detailResponse.body.timelineTotal).toBe(205);
    expect(detailResponse.body.timelineNextOffset).toBe(200);

    const nextPageResponse = await request(app)
      .get("/api/sessions/http-timeline-page/timeline")
      .query({ offset: 200, limit: 200 })
      .expect(200);

    expect(nextPageResponse.body.total).toBe(205);
    expect(nextPageResponse.body.items).toHaveLength(5);
    expect(nextPageResponse.body.items[0]).toMatchObject({
      text: "timeline-201",
    });
    expect(nextPageResponse.body.nextOffset).toBeNull();
  });

  test("creates manager storage automatically when it does not exist", async () => {
    const missingManagerHome = path.join(harness.codexHome, "..", "brand-new-manager-home");

    expect(() =>
      createApp({
        codexHome: harness.codexHome,
        managerHome: missingManagerHome,
      }),
    ).not.toThrow();
  });

  test("supports batch trash and batch purge over HTTP", async () => {
    await seedSession(harness.codexHome, {
      id: "http-batch-a",
      cwd: "/work/http-batch",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "批量操作 A",
      latestAgentMessage: "A 已经准备好了。",
    });
    await seedSession(harness.codexHome, {
      id: "http-batch-b",
      cwd: "/work/http-batch",
      startedAt: "2026-03-29T10:17:37.087Z",
      firstUserMessage: "批量操作 B",
      latestAgentMessage: "B 已经准备好了。",
    });

    const app = createApp({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });

    await request(app).post("/api/sessions/rescan").send({}).expect(200);
    const trashResponse = await request(app)
      .post("/api/sessions/batch/trash")
      .send({
        sessionIds: ["http-batch-a", "http-batch-b"],
      })
      .expect(200);

    expect(trashResponse.body.records).toHaveLength(2);
    expect(trashResponse.body.failures).toEqual([]);
    expect(trashResponse.body.records[0].status).toBe("deleted_pending_purge");

    const purgeResponse = await request(app)
      .post("/api/sessions/batch/purge")
      .send({
        sessionIds: ["http-batch-a", "http-batch-b"],
      })
      .expect(200);

    expect(purgeResponse.body.records).toEqual([]);
    expect(purgeResponse.body.failures).toEqual([]);
    const listResponse = await request(app).get("/api/sessions").expect(200);
    expect(listResponse.body.sessions).toEqual([]);
  });

  test("repairs official Codex thread stores over HTTP", async () => {
    const rolloutPath = await seedSession(harness.codexHome, {
      id: "http-repair-official",
      cwd: "/work/http-repair-official",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "把这条线程重新同步到官方 Codex",
      latestAgentMessage: "我会补齐 threads 和 recent conversations。",
      registerOfficialThread: false,
      registerSessionIndex: false,
    });

    const app = createApp({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });

    const response = await request(app).post("/api/codex/repair").send({}).expect(200);

    expect(response.body.stats).toMatchObject({
      createdThreads: 1,
      updatedThreads: 0,
      updatedSessionIndexEntries: 1,
    });
    expect(readOfficialThread(harness.codexHome, "http-repair-official")).toMatchObject({
      id: "http-repair-official",
      archived: 0,
      rolloutPath,
    });
    await expect(readSessionIndexEntry(harness.codexHome, "http-repair-official")).resolves.toMatchObject({
      id: "http-repair-official",
      thread_name: "把这条线程重新同步到官方 Codex",
    });
  });

  test("returns a readable 400 error when restore target directory does not exist", async () => {
    await seedSession(harness.codexHome, {
      id: "http-restore-missing-target",
      cwd: "/work/http-restore-missing-target",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "恢复到不存在的目录",
      latestAgentMessage: "我会检查目录。",
    });

    const app = createApp({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });

    await request(app).post("/api/sessions/rescan").send({}).expect(200);

    const response = await request(app)
      .post("/api/sessions/http-restore-missing-target/restore")
      .send({
        targetCwd: path.join(harness.managerHome, "missing-target"),
        restoreMode: "resume_only",
      })
      .expect(400);

    expect(response.body).toEqual({
      error: "目标项目目录不存在，请先创建后再恢复。",
    });
  });

  test("returns a readable 400 error when restore target is a file instead of a directory", async () => {
    const targetFile = path.join(harness.managerHome, "restore-target.txt");
    await writeFile(targetFile, "not-a-directory");
    await seedSession(harness.codexHome, {
      id: "http-restore-file-target",
      cwd: "/work/http-restore-file-target",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "恢复到文件路径",
      latestAgentMessage: "我会检查目标。",
    });

    const app = createApp({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });

    await request(app).post("/api/sessions/rescan").send({}).expect(200);

    const response = await request(app)
      .post("/api/sessions/http-restore-file-target/restore")
      .send({
        targetCwd: targetFile,
        restoreMode: "resume_only",
      })
      .expect(400);

    expect(response.body).toEqual({
      error: "目标项目目录不是文件夹，请重新选择目录。",
    });
  });

  test("returns a readable 400 error when restore target directory is not accessible", async () => {
    const lockedDir = path.join(harness.managerHome, "locked-target");
    await mkdir(lockedDir, { recursive: true });
    await seedSession(harness.codexHome, {
      id: "http-restore-locked-target",
      cwd: "/work/http-restore-locked-target",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "恢复到不可访问目录",
      latestAgentMessage: "我会检查权限。",
    });

    const app = createApp({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });

    await request(app).post("/api/sessions/rescan").send({}).expect(200);
    await chmod(lockedDir, 0o000);

    try {
      const response = await request(app)
        .post("/api/sessions/http-restore-locked-target/restore")
        .send({
          targetCwd: lockedDir,
          restoreMode: "resume_only",
        })
        .expect(400);

      expect(response.body).toEqual({
        error: "当前没有权限访问目标项目目录，请检查目录权限。",
      });
    } finally {
      await chmod(lockedDir, 0o755);
    }
  });

  test("returns a readable 400 error when restore mode is unsupported", async () => {
    await seedSession(harness.codexHome, {
      id: "http-restore-invalid-mode",
      cwd: "/work/http-restore-invalid-mode",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "恢复模式要校验",
      latestAgentMessage: "非法值不应该被吞掉。",
    });

    const app = createApp({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });

    await request(app).post("/api/sessions/rescan").send({}).expect(200);

    const response = await request(app)
      .post("/api/sessions/http-restore-invalid-mode/restore")
      .send({
        restoreMode: "resumeable",
      })
      .expect(400);

    expect(response.body).toEqual({
      error: "不支持的恢复模式，请刷新页面后重试。",
    });
  });
});
