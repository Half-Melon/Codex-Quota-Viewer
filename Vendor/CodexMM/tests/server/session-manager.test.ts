import { access, mkdir, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import path from "node:path";

import Database from "better-sqlite3";
import { afterEach, beforeEach, describe, expect, test } from "vitest";

import { AppError } from "../../src/server/lib/errors";
import {
  createSessionManager,
  type SessionManager,
} from "../../src/server/services/session-manager";
import { ensureInsidePath } from "../../src/server/lib/paths";
import {
  createHarness,
  readOfficialThread,
  readSessionIndexEntry,
  seedSession,
  type TestHarness,
} from "./support";

describe("SessionManager", () => {
  let harness: TestHarness;
  let manager: SessionManager;

  beforeEach(async () => {
    harness = await createHarness();
    manager = createSessionManager({
      codexHome: harness.codexHome,
      managerHome: harness.managerHome,
    });
  });

  afterEach(async () => {
    await harness.cleanup();
  });

  test("rescans session files and builds searchable summaries", async () => {
    await seedSession(harness.codexHome, {
      id: "session-alpha",
      cwd: "/work/project-alpha",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "请帮我恢复这个项目的会话",
      latestAgentMessage: "我已经完成扫描并准备恢复。",
      toolCalls: 2,
    });
    await seedSession(harness.codexHome, {
      id: "session-beta",
      cwd: "/work/project-beta",
      startedAt: "2026-03-28T09:00:00.000Z",
      firstUserMessage: "解释一下现有会话结构",
      latestAgentMessage: "这是当前结构摘要。",
    });

    await manager.rescan();
    const sessions = await manager.listSessions({ query: "恢复" });

    expect(sessions).toHaveLength(1);
    expect(sessions[0]).toMatchObject({
      id: "session-alpha",
      cwd: "/work/project-alpha",
      indexedAt: expect.any(String),
      status: "active",
      userPromptExcerpt: "请帮我恢复这个项目的会话",
      latestAgentMessageExcerpt: "我已经完成扫描并准备恢复。",
      toolCallCount: 2,
    });
  });

  test("rescans keep updatedAt stable, refresh indexedAt, and do not repair official stores", async () => {
    await seedSession(harness.codexHome, {
      id: "session-rescan-idempotent",
      cwd: "/work/rescan-idempotent",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "只刷新索引，不要改官方线程",
      latestAgentMessage: "我会保持更新时间稳定。",
      registerOfficialThread: false,
      registerSessionIndex: false,
    });

    await manager.rescan();
    const firstPass = await manager.getSessionDetail("session-rescan-idempotent");

    expect(firstPass.record.indexedAt).toEqual(expect.any(String));
    expect(readOfficialThread(harness.codexHome, "session-rescan-idempotent")).toBeNull();
    await expect(readSessionIndexEntry(harness.codexHome, "session-rescan-idempotent")).resolves.toBeNull();

    await new Promise((resolve) => setTimeout(resolve, 20));

    await manager.rescan();
    const secondPass = await manager.getSessionDetail("session-rescan-idempotent");

    expect(secondPass.record.updatedAt).toBe(firstPass.record.updatedAt);
    expect(secondPass.record.indexedAt).not.toBe(firstPass.record.indexedAt);
    expect(readOfficialThread(harness.codexHome, "session-rescan-idempotent")).toBeNull();
    await expect(readSessionIndexEntry(harness.codexHome, "session-rescan-idempotent")).resolves.toBeNull();
  });

  test("reports canonical official-state issue codes without localized prose", async () => {
    await seedSession(harness.codexHome, {
      id: "session-official-state-codes",
      cwd: "/work/official-state-codes",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "只返回 canonical official state",
      latestAgentMessage: "不要把中文文案塞进 shared contract。",
      registerOfficialThread: false,
      registerSessionIndex: false,
    });

    await manager.rescan();
    const detail = await manager.getSessionDetail("session-official-state-codes");

    expect(detail.officialState).toEqual({
      status: "repair_needed",
      canAppearInCodex: true,
      issueCodes: ["missing_thread", "missing_recent_conversation"],
    });
  });

  test("reports unknown session errors with structured details", async () => {
    await expect(manager.getSessionDetail("session-missing-detail")).rejects.toMatchObject({
      code: "unknown_session",
      message: "Unknown session: session-missing-detail",
      details: {
        sessionId: "session-missing-detail",
      },
    });
  });

  test("archives an active session and marks it archived", async () => {
    const filePath = await seedSession(harness.codexHome, {
      id: "session-archive",
      cwd: "/work/archive-me",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "把它归档",
      latestAgentMessage: "马上归档。",
    });

    await manager.rescan();
    const record = await manager.archiveSession("session-archive");
    const expectedArchivePath = path.join(
      harness.codexHome,
      "archived_sessions",
      "2026",
      "03",
      "29",
      "rollout-2026-03-29T10-16-37.087Z-session-archive.jsonl",
    );

    await expect(access(filePath)).rejects.toThrow();
    await expect(access(record.archivePath!)).resolves.toBeUndefined();
    expect(record.archivePath).toBe(await realpath(expectedArchivePath));
    expect(record.status).toBe("archived");
    expect(readOfficialThread(harness.codexHome, "session-archive")).toMatchObject({
      id: "session-archive",
      archived: 1,
      rolloutPath: await realpath(expectedArchivePath),
    });
    await expect(readSessionIndexEntry(harness.codexHome, "session-archive")).resolves.toMatchObject({
      id: "session-archive",
      thread_name: "把它归档",
    });
  });

  test("rejects archive targets that escape the managed archive root", async () => {
    await seedSession(harness.codexHome, {
      id: "session-archive-escape",
      cwd: "/work/archive-escape",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "不要归档到外面",
      latestAgentMessage: "需要拒绝越界路径。",
    });

    await manager.rescan();

    const db = new Database(path.join(harness.managerHome, "index.db"));
    db.prepare(
      `
        update sessions
        set original_relative_path = ?
        where id = ?
      `,
    ).run("../../escape.jsonl", "session-archive-escape");
    db.close();

    const managedRoot = path.join(harness.codexHome, "archived_sessions");
    const candidatePath = path.join(managedRoot, "../../escape.jsonl");
    const resolvedManagedRoot = await realpath(managedRoot);
    const resolvedCandidatePath = path.join(
      await realpath(path.dirname(candidatePath)),
      path.basename(candidatePath),
    );

    await expect(manager.archiveSession("session-archive-escape")).rejects.toMatchObject({
      code: "managed_session_path_outside",
      message: "会话 archive 文件路径超出了受管目录，已拒绝继续操作。",
      details: {
        label: "archive",
        managedRoot: resolvedManagedRoot,
        candidatePath,
        resolvedCandidatePath,
      },
    });
    await expect(access(path.join(harness.codexHome, "..", "escape.jsonl"))).rejects.toThrow();
  });

  test("safe deletes by snapshotting and marking session deleted_pending_purge", async () => {
    const filePath = await seedSession(harness.codexHome, {
      id: "session-delete",
      cwd: "/work/delete-me",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "删掉这个会话",
      latestAgentMessage: "会先安全删除。",
    });

    await manager.rescan();
    const record = await manager.deleteSession("session-delete");
    const expectedArchivePath = path.join(
      harness.codexHome,
      "archived_sessions",
      "2026",
      "03",
      "29",
      "rollout-2026-03-29T10-16-37.087Z-session-delete.jsonl",
    );

    await expect(access(filePath)).rejects.toThrow();
    await expect(access(record.archivePath!)).resolves.toBeUndefined();
    await expect(access(record.snapshotPath!)).resolves.toBeUndefined();
    expect(record.archivePath).toBe(await realpath(expectedArchivePath));
    expect(record.status).toBe("deleted_pending_purge");
    expect(readOfficialThread(harness.codexHome, "session-delete")).toMatchObject({
      id: "session-delete",
      archived: 1,
      rolloutPath: await realpath(expectedArchivePath),
    });
  });

  test("rejects deleting an indexed session when its active path resolves outside the managed root", async () => {
    const filePath = await seedSession(harness.codexHome, {
      id: "session-delete-symlink",
      cwd: "/work/delete-symlink",
      startedAt: "2026-03-29T10:18:37.087Z",
      firstUserMessage: "不要越界删除",
      latestAgentMessage: "symlink 目标必须被拒绝。",
    });

    await manager.rescan();

    const outsideDirectory = path.join(harness.managerHome, "outside");
    const outsideFile = path.join(outsideDirectory, "secret.jsonl");
    await mkdir(outsideDirectory, { recursive: true });
    await writeFile(outsideFile, "secret-data");
    await rm(filePath, { force: true });
    await symlink(outsideFile, filePath);

    await expect(manager.deleteSession("session-delete-symlink")).rejects.toThrow("受管目录");
    await expect(readFile(outsideFile, "utf8")).resolves.toBe("secret-data");
  });

  test("reports raw path escape errors with structured details", () => {
    const managedRoot = path.join(harness.codexHome, "sessions");
    const candidatePath = path.join(harness.codexHome, "..", "escaped.jsonl");

    let thrown: unknown;

    try {
      ensureInsidePath(managedRoot, candidatePath);
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toMatchObject({
      code: "path_outside_managed_root",
      message: `Path is outside managed root: ${candidatePath}`,
      details: {
        managedRoot,
        candidatePath,
        resolvedCandidatePath: candidatePath,
      },
    });
  });

  test("restores an archived session and prepares a resume command", async () => {
    const projectDir = path.join(harness.managerHome, "target-project");
    const filePath = await seedSession(harness.codexHome, {
      id: "session-restore",
      cwd: "/work/original",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "恢复这个会话",
      latestAgentMessage: "恢复完成。",
    });

    await manager.rescan();
    await manager.archiveSession("session-restore");
    await mkdir(projectDir, { recursive: true });
    const restored = await manager.restoreSession({
      sessionId: "session-restore",
      targetCwd: projectDir,
      restoreMode: "resume_only",
    });

    await expect(access(filePath)).resolves.toBeUndefined();
    expect(restored.record.status).toBe("active");
    expect(restored.resumeCommand).toBe(
      `codex resume session-restore -C ${projectDir}`,
    );
    expect(readOfficialThread(harness.codexHome, "session-restore")).toMatchObject({
      id: "session-restore",
      archived: 0,
      archivedAt: null,
      rolloutPath: await realpath(filePath),
    });
    await expect(readSessionIndexEntry(harness.codexHome, "session-restore")).resolves.toMatchObject({
      id: "session-restore",
      thread_name: "恢复这个会话",
    });
  });

  test("rescans backfill missing official thread rows and recent session index entries", async () => {
    const filePath = await seedSession(harness.codexHome, {
      id: "session-backfill-official",
      cwd: "/work/backfill-official",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "把这条线程重新接回官方索引",
      latestAgentMessage: "我会补齐官方需要的数据。",
      registerOfficialThread: false,
      registerSessionIndex: false,
    });

    expect(readOfficialThread(harness.codexHome, "session-backfill-official")).toBeNull();
    await expect(readSessionIndexEntry(harness.codexHome, "session-backfill-official")).resolves.toBeNull();

    await manager.rescan();

    expect(readOfficialThread(harness.codexHome, "session-backfill-official")).toBeNull();
    await expect(readSessionIndexEntry(harness.codexHome, "session-backfill-official")).resolves.toBeNull();

    const repair = await manager.repairOfficialThreads(["session-backfill-official"]);

    expect(repair.stats).toMatchObject({
      createdThreads: 1,
      updatedThreads: 0,
      updatedSessionIndexEntries: 1,
    });
    expect(readOfficialThread(harness.codexHome, "session-backfill-official")).toMatchObject({
      id: "session-backfill-official",
      archived: 0,
      rolloutPath: filePath,
    });
    await expect(readSessionIndexEntry(harness.codexHome, "session-backfill-official")).resolves.toMatchObject({
      id: "session-backfill-official",
      thread_name: "把这条线程重新接回官方索引",
    });
  });

  test("repairs official threads idempotently when nothing changed", async () => {
    const filePath = await seedSession(harness.codexHome, {
      id: "session-repair-idempotent",
      cwd: "/work/repair-idempotent",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "显式修复官方线程",
      latestAgentMessage: "第二次不应该重复写入。",
      registerOfficialThread: false,
      registerSessionIndex: false,
    });

    await manager.rescan();

    const firstRepair = await manager.repairOfficialThreads([
      "session-repair-idempotent",
    ]);

    expect(firstRepair.stats).toMatchObject({
      createdThreads: 1,
      updatedThreads: 0,
      updatedSessionIndexEntries: 1,
    });
    expect(readOfficialThread(harness.codexHome, "session-repair-idempotent")).toMatchObject({
      id: "session-repair-idempotent",
      archived: 0,
      rolloutPath: filePath,
    });

    const secondRepair = await manager.repairOfficialThreads([
      "session-repair-idempotent",
    ]);

    expect(secondRepair.stats).toMatchObject({
      createdThreads: 0,
      updatedThreads: 0,
      updatedSessionIndexEntries: 0,
    });
  });

  test("repairs targeted sessions incrementally without rebuilding unrelated catalog rows", async () => {
    const targetFilePath = await seedSession(harness.codexHome, {
      id: "session-targeted-repair",
      cwd: "/work/targeted-repair",
      startedAt: "2026-03-29T11:16:37.087Z",
      firstUserMessage: "修复前标题",
      latestAgentMessage: "目标会话需要被定向修复。",
    });
    await seedSession(harness.codexHome, {
      id: "session-targeted-untouched",
      cwd: "/work/targeted-untouched",
      startedAt: "2026-03-29T11:17:37.087Z",
      firstUserMessage: "不要重建这条会话",
      latestAgentMessage: "无关会话不该被重新索引。",
    });

    await manager.rescan();
    const untouchedBefore = await manager.getSessionDetail("session-targeted-untouched");

    await rewriteFirstUserMessage(targetFilePath, "修复后标题");
    await new Promise((resolve) => setTimeout(resolve, 20));

    await manager.repairOfficialThreads(["session-targeted-repair"]);

    const targetAfter = await manager.getSessionDetail("session-targeted-repair");
    const untouchedAfter = await manager.getSessionDetail("session-targeted-untouched");

    expect(targetAfter.record.userPromptExcerpt).toBe("修复后标题");
    expect(targetAfter.record.indexedAt).not.toBe(untouchedBefore.record.indexedAt);
    expect(readOfficialThreadTitle(harness.codexHome, "session-targeted-repair")).toBe(
      "修复后标题",
    );
    await expect(readSessionIndexEntry(harness.codexHome, "session-targeted-repair")).resolves.toMatchObject({
      id: "session-targeted-repair",
      thread_name: "修复后标题",
    });
    expect(untouchedAfter.record.updatedAt).toBe(untouchedBefore.record.updatedAt);
    expect(untouchedAfter.record.indexedAt).toBe(untouchedBefore.record.indexedAt);
  });

  test("repairs remove broken official thread rows when rollout files are gone", async () => {
    const filePath = await seedSession(harness.codexHome, {
      id: "session-broken-official",
      cwd: "/work/broken-official",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "坏掉的官方线程需要清理",
      latestAgentMessage: "我会把坏索引移除。",
    });

    await rm(filePath, { force: true });
    expect(readOfficialThread(harness.codexHome, "session-broken-official")).toMatchObject({
      id: "session-broken-official",
      rolloutPath: filePath,
    });

    await manager.rescan();

    expect(readOfficialThread(harness.codexHome, "session-broken-official")).toMatchObject({
      id: "session-broken-official",
      rolloutPath: filePath,
    });
    await expect(readSessionIndexEntry(harness.codexHome, "session-broken-official")).resolves.toMatchObject({
      id: "session-broken-official",
    });

    await manager.repairOfficialThreads();

    expect(readOfficialThread(harness.codexHome, "session-broken-official")).toBeNull();
    await expect(readSessionIndexEntry(harness.codexHome, "session-broken-official")).resolves.toBeNull();
  });

  test("includes restorable sessions in archived filter while preserving restorable status", async () => {
    await seedSession(harness.codexHome, {
      id: "session-restorable-filter",
      cwd: "/work/restorable-filter",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "这条会话只剩备份",
      latestAgentMessage: "可以从备份恢复。",
    });

    await manager.rescan();
    const trashed = await manager.deleteSession("session-restorable-filter");
    await rm(trashed.archivePath!, { force: true });

    await manager.rescan();

    await expect(manager.listSessions({ status: "restorable" })).resolves.toEqual([
      expect.objectContaining({
        id: "session-restorable-filter",
        status: "restorable",
        archivePath: null,
      }),
    ]);

    await expect(manager.listSessions({ status: "archived" })).resolves.toEqual([
      expect.objectContaining({
        id: "session-restorable-filter",
        status: "restorable",
        archivePath: null,
      }),
    ]);
  });

  test("migrates flat archived files into canonical archived_sessions paths on rescan", async () => {
    await seedSession(harness.codexHome, {
      id: "session-flat-archive",
      cwd: "/work/flat-archive",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "把旧归档迁回官方路径",
      latestAgentMessage: "会迁移到标准目录结构。",
    });

    await manager.rescan();
    const archived = await manager.archiveSession("session-flat-archive");
    const canonicalArchivePath = path.join(
      harness.codexHome,
      "archived_sessions",
      "2026",
      "03",
      "29",
      "rollout-2026-03-29T10-16-37.087Z-session-flat-archive.jsonl",
    );
    const flatArchivePath = path.join(
      harness.codexHome,
      "archived_sessions",
      "session-flat-archive.jsonl",
    );

    await rename(archived.archivePath!, flatArchivePath);
    await manager.rescan();

    const rescanned = await manager.getSessionDetail("session-flat-archive");

    expect(rescanned.record.archivePath).toBe(await realpath(canonicalArchivePath));
    await expect(access(canonicalArchivePath)).resolves.toBeUndefined();
    await expect(access(flatArchivePath)).rejects.toThrow();
    expect(readOfficialThread(harness.codexHome, "session-flat-archive")).toMatchObject({
      id: "session-flat-archive",
      archived: 1,
      rolloutPath: await realpath(canonicalArchivePath),
    });
  });

  test("keeps active sessions resumable when only retargeting to another directory", async () => {
    const projectDir = path.join(harness.managerHome, "active-target");

    await seedSession(harness.codexHome, {
      id: "session-active-resume",
      cwd: "/work/active",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "继续这个活动会话",
      latestAgentMessage: "可以直接换目录继续。",
    });

    await mkdir(projectDir, { recursive: true });
    await manager.rescan();
    const restored = await manager.restoreSession({
      sessionId: "session-active-resume",
      targetCwd: projectDir,
      restoreMode: "resume_only",
    });

    expect(restored.record.status).toBe("active");
    expect(restored.record.cwd).toBe("/work/active");
    expect(restored.resumeCommand).toBe(
      `codex resume session-active-resume -C ${projectDir}`,
    );
  });

  test("rebinds cwd when restoring with the permanent directory mode", async () => {
    const projectDir = path.join(harness.managerHome, "rebind-target");
    const filePath = await seedSession(harness.codexHome, {
      id: "session-rebind-cwd",
      cwd: "/work/original-rebind",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "把目录永久改掉",
      latestAgentMessage: "恢复后应该记住新目录。",
    });

    await manager.rescan();
    await manager.archiveSession("session-rebind-cwd");
    await mkdir(projectDir, { recursive: true });

    const restored = await manager.restoreSession({
      sessionId: "session-rebind-cwd",
      targetCwd: projectDir,
      restoreMode: "rebind_cwd",
    });

    await expect(access(filePath)).resolves.toBeUndefined();
    expect(restored.record.status).toBe("active");
    expect(restored.record.cwd).toBe(projectDir);
    expect(restored.resumeCommand).toBe("codex resume session-rebind-cwd");
    expect(readOfficialThread(harness.codexHome, "session-rebind-cwd")).toMatchObject({
      id: "session-rebind-cwd",
      cwd: projectDir,
      archived: 0,
      rolloutPath: await realpath(filePath),
    });

    await manager.rescan();

    await expect(manager.getSessionDetail("session-rebind-cwd")).resolves.toMatchObject({
      record: expect.objectContaining({
        cwd: projectDir,
      }),
    });
  });

  test("keeps snapshot metadata unchanged when rebinding cwd during restore", async () => {
    const projectDir = path.join(harness.managerHome, "snapshot-rebind-target");
    const filePath = await seedSession(harness.codexHome, {
      id: "session-snapshot-rebind",
      cwd: "/work/original-snapshot",
      startedAt: "2026-03-29T12:16:37.087Z",
      firstUserMessage: "从 snapshot 永久改目录",
      latestAgentMessage: "只该改恢复后的活动文件。",
    });

    await manager.rescan();
    const deleted = await manager.deleteSession("session-snapshot-rebind");
    await rm(deleted.archivePath!, { force: true });
    await mkdir(projectDir, { recursive: true });

    await manager.rescan();

    await manager.restoreSession({
      sessionId: "session-snapshot-rebind",
      targetCwd: projectDir,
      restoreMode: "rebind_cwd",
    });

    await expect(readFile(deleted.snapshotPath!, "utf8")).resolves.toContain("\"cwd\":\"/work/original-snapshot\"");
    await expect(readFile(filePath, "utf8")).resolves.toContain(`"cwd":"${projectDir}"`);
  });

  test("rejects unsupported restore modes instead of silently normalizing them", async () => {
    await seedSession(harness.codexHome, {
      id: "session-invalid-restore-mode",
      cwd: "/work/invalid-restore-mode",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "校验非法恢复模式",
      latestAgentMessage: "不应该静默兜底。",
    });

    await manager.rescan();

    await expect(
      manager.restoreSession({
        sessionId: "session-invalid-restore-mode",
        restoreMode: "resumeable" as never,
      }),
    ).rejects.toThrow("不支持的恢复模式");
  });

  test("keeps the existing official first user message when the rescanned session no longer has one", async () => {
    await seedSession(harness.codexHome, {
      id: "session-first-user-message",
      cwd: "/work/first-user-message",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "",
      latestAgentMessage: "这是当前助手摘要",
      registerOfficialThread: true,
      registerSessionIndex: true,
    });

    const officialDb = new Database(path.join(harness.codexHome, "state_5.sqlite"));
    officialDb
      .prepare(
        `
          update threads
          set title = ?, first_user_message = ?
          where id = ?
        `,
      )
      .run("旧标题", "历史真实首问", "session-first-user-message");
    officialDb.close();

    await manager.rescan();
    await manager.repairOfficialThreads(["session-first-user-message"]);

    const repairedThreadDb = new Database(path.join(harness.codexHome, "state_5.sqlite"));
    const repairedThread = repairedThreadDb
      .prepare(
        `
          select title, first_user_message as firstUserMessage
          from threads
          where id = ?
        `,
      )
      .get("session-first-user-message") as
      | {
          title: string;
          firstUserMessage: string;
        }
      | undefined;
    repairedThreadDb.close();

    expect(repairedThread).toMatchObject({
      title: "这是当前助手摘要",
      firstUserMessage: "历史真实首问",
    });
  });

  test("repairs missing sandbox and approval metadata with conservative defaults", async () => {
    await seedSession(harness.codexHome, {
      id: "session-repair-conservative-defaults",
      cwd: "/work/repair-conservative",
      startedAt: "2026-03-29T13:16:37.087Z",
      firstUserMessage: "修复时不能放大权限",
      latestAgentMessage: "应该写入保守默认值。",
      registerOfficialThread: false,
      registerSessionIndex: false,
    });

    await manager.rescan();
    await manager.repairOfficialThreads(["session-repair-conservative-defaults"]);

    const db = new Database(path.join(harness.codexHome, "state_5.sqlite"));
    const row = db
      .prepare(
        `
          select
            sandbox_policy as sandboxPolicy,
            approval_mode as approvalMode
          from threads
          where id = ?
        `,
      )
      .get("session-repair-conservative-defaults") as
      | {
          sandboxPolicy: string;
          approvalMode: string;
        }
      | undefined;
    db.close();

    expect(row).toMatchObject({
      sandboxPolicy: "workspace-write",
      approvalMode: "default",
    });
  });

  test("loads session detail with a readable timeline from the jsonl fact source", async () => {
    await seedSession(harness.codexHome, {
      id: "session-detail",
      cwd: "/work/detail",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "检查完整线程",
      latestAgentMessage: "线程已经展开。",
      timeline: [
        { type: "message:user", text: "检查完整线程" },
        {
          type: "tool_call",
          toolName: "read_file",
          input: "src/app.ts",
          output: "export const ready = true;",
        },
        { type: "message:assistant", text: "我已经把文件内容整理好了。" },
      ],
    });

    await manager.rescan();
    const detail = await manager.getSessionDetail("session-detail");

    expect(detail.timeline).toHaveLength(3);
    expect(detail.timeline[1]).toMatchObject({
      type: "tool_call",
      toolName: "read_file",
      input: "src/app.ts",
      output: "export const ready = true;",
    });
  });

  test("rebuilds a v2 catalog with timeline and FTS tables while preserving audit log rows", async () => {
    await seedSession(harness.codexHome, {
      id: "session-v2-catalog",
      cwd: "/work/v2-catalog",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "建立新的 catalog",
      latestAgentMessage: "需要保留审计日志。",
      timeline: [
        { type: "message:user", text: "建立新的 catalog" },
        { type: "message:assistant", text: "需要保留审计日志。" },
      ],
    });

    await manager.rescan();
    await manager.archiveSession("session-v2-catalog");

    expect(readCatalogTableNames(harness.managerHome)).toEqual(
      expect.arrayContaining(["audit_log", "sessions", "timeline_items", "session_search"]),
    );
    const auditCountBefore = readAuditLogCount(harness.managerHome);

    await manager.rescan();

    expect(readCatalogTableNames(harness.managerHome)).toEqual(
      expect.arrayContaining(["audit_log", "sessions", "timeline_items", "session_search"]),
    );
    expect(readAuditLogCount(harness.managerHome)).toBe(auditCountBefore);
  });

  test("supports batch trash and batch restore without losing audit semantics", async () => {
    await seedSession(harness.codexHome, {
      id: "session-batch-a",
      cwd: "/work/batch",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "批量删除 A",
      latestAgentMessage: "A 准备好了。",
    });
    await seedSession(harness.codexHome, {
      id: "session-batch-b",
      cwd: "/work/batch",
      startedAt: "2026-03-29T10:17:37.087Z",
      firstUserMessage: "批量删除 B",
      latestAgentMessage: "B 准备好了。",
    });

    await manager.rescan();
    const trashed = await manager.batchTrashSessions([
      "session-batch-a",
      "session-batch-b",
    ]);

    expect(trashed.failures).toEqual([]);
    expect(trashed.records.map((record) => record.status)).toEqual([
      "deleted_pending_purge",
      "deleted_pending_purge",
    ]);

    const restored = await manager.batchRestoreSessions([
      "session-batch-a",
      "session-batch-b",
    ]);

    expect(restored.failures).toEqual([]);
    expect(restored.records.map((record) => record.status)).toEqual([
      "active",
      "active",
    ]);
  });

  test("purges a deleted session by removing its files and index record", async () => {
    await seedSession(harness.codexHome, {
      id: "session-purge",
      cwd: "/work/purge-me",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "永久删掉",
      latestAgentMessage: "准备清理。",
    });

    await manager.rescan();
    const trashed = await manager.deleteSession("session-purge");

    await expect(access(trashed.archivePath!)).resolves.toBeUndefined();
    await expect(access(trashed.snapshotPath!)).resolves.toBeUndefined();

    await manager.purgeSession("session-purge");

    await expect(access(trashed.archivePath!)).rejects.toThrow();
    await expect(access(trashed.snapshotPath!)).rejects.toThrow();
    await expect(manager.getSessionDetail("session-purge")).rejects.toThrow(
      "session-purge",
    );
    await expect(manager.listSessions({ query: "永久删掉" })).resolves.toEqual([]);
    expect(readOfficialThread(harness.codexHome, "session-purge")).toBeNull();
  });

  test("supports batch purge for trashed sessions", async () => {
    await seedSession(harness.codexHome, {
      id: "session-purge-a",
      cwd: "/work/purge-batch",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "批量清空 A",
      latestAgentMessage: "准备清理 A。",
    });
    await seedSession(harness.codexHome, {
      id: "session-purge-b",
      cwd: "/work/purge-batch",
      startedAt: "2026-03-29T10:18:37.087Z",
      firstUserMessage: "批量清空 B",
      latestAgentMessage: "准备清理 B。",
    });

    await manager.rescan();
    await manager.batchTrashSessions(["session-purge-a", "session-purge-b"]);
    const purged = await manager.batchPurgeSessions([
      "session-purge-a",
      "session-purge-b",
    ]);

    expect(purged.failures).toEqual([]);
    expect(purged.records).toEqual([]);
    await expect(manager.listSessions({ cwd: "/work/purge-batch" })).resolves.toEqual([]);
  });

  test("drops sessions with no snapshot when their source file disappears on rescan", async () => {
    const filePath = await seedSession(harness.codexHome, {
      id: "session-disappeared",
      cwd: "/work/disappeared",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "这条会话文件被手动删掉了",
      latestAgentMessage: "已经不在磁盘上。",
    });

    await manager.rescan();
    await rm(filePath, { force: true });

    await manager.rescan();

    await expect(manager.listSessions({ query: "手动删掉" })).resolves.toEqual([]);
    await expect(manager.getSessionDetail("session-disappeared")).rejects.toThrow(
      "session-disappeared",
    );
  });

  test("rejects delete when a stored active path escapes the managed sessions root", async () => {
    await seedSession(harness.codexHome, {
      id: "session-unsafe-delete",
      cwd: "/work/unsafe-delete",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "不要信任被篡改的路径",
      latestAgentMessage: "删除前应该先校验路径。",
    });

    await manager.rescan();
    updateStoredSessionPath(harness.managerHome, "session-unsafe-delete", "active_path", "/tmp/escape.jsonl");

    await expect(manager.deleteSession("session-unsafe-delete")).rejects.toThrow(
      "会话 active 文件路径超出了受管目录",
    );
  });

  test("includes structured details when a managed session path escapes the active root", async () => {
    await seedSession(harness.codexHome, {
      id: "session-unsafe-delete-details",
      cwd: "/work/unsafe-delete-details",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "不要信任被篡改的路径",
      latestAgentMessage: "删除前应该先校验路径。",
    });

    await manager.rescan();
    updateStoredSessionPath(
      harness.managerHome,
      "session-unsafe-delete-details",
      "active_path",
      "/tmp/escape.jsonl",
    );

    await expect(manager.deleteSession("session-unsafe-delete-details")).rejects.toMatchObject({
      name: "AppError",
      code: "managed_session_path_outside",
      details: { label: "active" },
    } satisfies Partial<AppError & { details: unknown }>);
  });

  test("rejects restore when a stored archive path escapes the managed archive root", async () => {
    await seedSession(harness.codexHome, {
      id: "session-unsafe-restore",
      cwd: "/work/unsafe-restore",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "恢复前要验证归档路径",
      latestAgentMessage: "不能直接相信索引里的归档文件位置。",
    });

    await manager.rescan();
    await manager.archiveSession("session-unsafe-restore");
    updateStoredSessionPath(harness.managerHome, "session-unsafe-restore", "archive_path", "/tmp/escape.jsonl");

    await expect(
      manager.restoreSession({
        sessionId: "session-unsafe-restore",
        restoreMode: "resume_only",
      }),
    ).rejects.toThrow("会话 archive 文件路径超出了受管目录");
  });

  test("rejects purge when a stored archive path escapes the managed archive root", async () => {
    await seedSession(harness.codexHome, {
      id: "session-unsafe-purge",
      cwd: "/work/unsafe-purge",
      startedAt: "2026-03-29T10:16:37.087Z",
      firstUserMessage: "清理前要验证归档路径",
      latestAgentMessage: "不能删到受管目录外面。",
    });

    await manager.rescan();
    await manager.deleteSession("session-unsafe-purge");
    updateStoredSessionPath(harness.managerHome, "session-unsafe-purge", "archive_path", "/tmp/escape.jsonl");

    await expect(manager.purgeSession("session-unsafe-purge")).rejects.toThrow(
      "会话 archive 文件路径超出了受管目录",
    );
  });
});

function updateStoredSessionPath(
  managerHome: string,
  sessionId: string,
  field: "active_path" | "archive_path" | "snapshot_path",
  value: string,
) {
  const db = new Database(path.join(managerHome, "index.db"));
  db.prepare(`update sessions set ${field} = ? where id = ?`).run(value, sessionId);
  db.close();
}

function readCatalogTableNames(managerHome: string) {
  const db = new Database(path.join(managerHome, "index.db"));
  const rows = db
    .prepare(
      `
        select name
        from sqlite_master
        where type in ('table', 'virtual table')
        order by name asc
      `,
    )
    .all() as Array<{ name: string }>;
  db.close();
  return rows.map((row) => row.name);
}

function readAuditLogCount(managerHome: string) {
  const db = new Database(path.join(managerHome, "index.db"));
  const row = db
    .prepare("select count(*) as count from audit_log")
    .get() as { count: number };
  db.close();
  return row.count;
}

function readOfficialThreadTitle(codexHome: string, sessionId: string) {
  const db = new Database(path.join(codexHome, "state_5.sqlite"));
  const row = db
    .prepare(
      `
        select title
        from threads
        where id = ?
      `,
    )
    .get(sessionId) as { title: string } | undefined;
  db.close();
  return row?.title ?? null;
}

async function rewriteFirstUserMessage(filePath: string, nextMessage: string) {
  const content = await readFile(filePath, "utf8");
  let updated = false;
  const nextContent = content
    .split("\n")
    .map((line) => {
      if (updated || !line.trim()) {
        return line;
      }

      try {
        const entry = JSON.parse(line) as {
          type?: unknown;
          payload?: {
            type?: unknown;
            message?: unknown;
          };
        };

        if (
          entry.type !== "event_msg" ||
          !entry.payload ||
          entry.payload.type !== "user_message"
        ) {
          return line;
        }

        entry.payload.message = nextMessage;
        updated = true;
        return JSON.stringify(entry);
      } catch {
        return line;
      }
    })
    .join("\n");

  await writeFile(filePath, nextContent);
}
