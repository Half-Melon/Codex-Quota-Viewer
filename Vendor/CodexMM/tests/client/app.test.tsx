import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import type { SessionDetail, SessionRecord } from "../../src/shared/contracts";
import App from "../../src/client/App";

type UiLanguage = "en" | "zh";

const LOCALE_STORAGE_KEY = "codex-session-manager.locale";

const syncedOfficialState = {
  status: "synced" as const,
  canAppearInCodex: true,
  threadRowPresent: true,
  sessionIndexPresent: true,
  rolloutPathMatches: true,
  archivedFlagMatches: true,
  sessionIndexMatches: true,
  summary: "这条会话已经同步到官方 Codex 的 threads 和 recent conversations。",
  issues: [],
};

const repairNeededOfficialState = {
  status: "repair_needed" as const,
  canAppearInCodex: true,
  threadRowPresent: false,
  sessionIndexPresent: false,
  rolloutPathMatches: false,
  archivedFlagMatches: false,
  sessionIndexMatches: false,
  summary: "这条会话在官方 Codex 的本地线程状态还没有完全同步。",
  issues: ["官方 threads 缺少这条线程记录。", "官方 recent conversations 缺少这条索引。"],
};

const hiddenOfficialState = {
  status: "hidden" as const,
  canAppearInCodex: false,
  threadRowPresent: false,
  sessionIndexPresent: false,
  rolloutPathMatches: true,
  archivedFlagMatches: true,
  sessionIndexMatches: true,
  summary: "这条会话只剩 snapshot 备份，当前已从官方 Codex 列表隐藏。",
  issues: [],
};

const sessionAlpha: SessionRecord = {
  id: "session-alpha",
  filePath: "/tmp/example-home/.codex/sessions/2026/03/29/session-alpha.jsonl",
  activePath: "/tmp/example-home/.codex/sessions/2026/03/29/session-alpha.jsonl",
  archivePath: null,
  snapshotPath: null,
  originalRelativePath: "2026/03/29/session-alpha.jsonl",
  cwd: "/work/project-alpha",
  startedAt: "2026-03-29T10:16:37.087Z",
  originator: "Codex Desktop",
  source: "vscode",
  cliVersion: "0.118.0-alpha.2",
  modelProvider: "openai",
  sizeBytes: 1024,
  lineCount: 12,
  eventCount: 4,
  toolCallCount: 2,
  userPromptExcerpt: "请帮我恢复这个项目的会话",
  latestAgentMessageExcerpt: "我已经完成扫描并准备恢复。",
  status: "active",
  createdAt: "2026-03-29T10:16:37.087Z",
  updatedAt: "2026-03-29T10:16:37.087Z",
  indexedAt: "2026-03-30T08:00:00.000Z",
};

const sessionBeta: SessionRecord = {
  ...sessionAlpha,
  id: "session-beta",
  filePath: "/tmp/example-home/.codex/sessions/2026/03/28/session-beta.jsonl",
  activePath: "/tmp/example-home/.codex/sessions/2026/03/28/session-beta.jsonl",
  originalRelativePath: "2026/03/28/session-beta.jsonl",
  cwd: "/work/project-beta",
  startedAt: "2026-03-28T08:00:00.000Z",
  userPromptExcerpt: "解释一下现有会话结构",
  latestAgentMessageExcerpt: "这是当前结构摘要。",
  toolCallCount: 0,
};

const sessionAlphaSibling: SessionRecord = {
  ...sessionAlpha,
  id: "session-alpha-sibling",
  filePath: "/tmp/example-home/.codex/sessions/2026/03/29/session-alpha-sibling.jsonl",
  activePath: "/tmp/example-home/.codex/sessions/2026/03/29/session-alpha-sibling.jsonl",
  originalRelativePath: "2026/03/29/session-alpha-sibling.jsonl",
  startedAt: "2026-03-29T11:16:37.087Z",
  userPromptExcerpt: "请继续整理这个项目的历史会话",
  latestAgentMessageExcerpt: "我已经归纳出第二条会话。",
  toolCallCount: 1,
};

const sessionArchived: SessionRecord = {
  ...sessionAlpha,
  id: "session-archived",
  activePath: null,
  archivePath: "/tmp/example-home/.codex/archived_sessions/session-archived.jsonl",
  cwd: "/work/project-archived",
  startedAt: "2026-03-27T08:00:00.000Z",
  userPromptExcerpt: "把这个会话归档保存",
  latestAgentMessageExcerpt: "会话已经归档。",
  status: "archived",
};

const sessionRestorable: SessionRecord = {
  ...sessionAlpha,
  id: "session-restorable",
  activePath: null,
  archivePath: null,
  snapshotPath: "/tmp/example-home/.codex-session-manager/snapshots/session-restorable.jsonl",
  cwd: "/work/project-restorable",
  startedAt: "2026-03-26T08:00:00.000Z",
  userPromptExcerpt: "这个会话还能恢复吗",
  latestAgentMessageExcerpt: "可以从快照恢复。",
  status: "restorable",
};

const alphaDetail: SessionDetail = {
  record: sessionAlpha,
  auditEntries: [],
  officialState: syncedOfficialState,
  timeline: [
    {
      id: "message-1",
      type: "message:user",
      timestamp: "2026-03-29T10:16:38.000Z",
      text: "请帮我恢复这个项目的会话",
    },
    {
      id: "tool-1",
      type: "tool_call",
      timestamp: "2026-03-29T10:16:39.000Z",
      toolName: "shell",
      summary: "shell · rg --files",
      input: "rg --files",
      output: "README.md\nsrc/app.ts",
      status: "completed",
    },
    {
      id: "message-2",
      type: "message:assistant",
      timestamp: "2026-03-29T10:16:40.000Z",
      text: "我已经完成扫描并准备恢复。",
    },
  ],
  timelineTotal: 3,
  timelineNextOffset: null,
} as SessionDetail;

const betaDetail: SessionDetail = {
  record: sessionBeta,
  auditEntries: [
    {
      id: 1,
      action: "archive",
      sessionId: "session-beta",
      sourcePath: sessionBeta.activePath,
      targetPath: "/tmp/example-home/.codex/archived_sessions/session-beta.jsonl",
      details: {},
      createdAt: "2026-03-29T10:16:40.000Z",
    },
  ],
  officialState: repairNeededOfficialState,
  timeline: [
    {
      id: "beta-message-1",
      type: "message:user",
      timestamp: "2026-03-28T08:00:01.000Z",
      text: "解释一下现有会话结构",
    },
    {
      id: "beta-message-2",
      type: "message:assistant",
      timestamp: "2026-03-28T08:00:02.000Z",
      text: "这是当前结构摘要。",
    },
  ],
  timelineTotal: 2,
  timelineNextOffset: null,
} as SessionDetail;

const restorableDetail: SessionDetail = {
  record: sessionRestorable,
  auditEntries: [],
  officialState: hiddenOfficialState,
  timeline: [
    {
      id: "restorable-message-1",
      type: "message:user",
      timestamp: "2026-03-26T08:00:01.000Z",
      text: "这个会话还能恢复吗",
    },
    {
      id: "restorable-message-2",
      type: "message:assistant",
      timestamp: "2026-03-26T08:00:02.000Z",
      text: "可以从快照恢复。",
    },
  ],
  timelineTotal: 2,
  timelineNextOffset: null,
} as SessionDetail;

const longTimelineDetail: SessionDetail = {
  record: sessionAlpha,
  auditEntries: [],
  officialState: syncedOfficialState,
  timeline: Array.from({ length: 200 }, (_, index) => ({
    id: `message-${index + 1}`,
    type: index % 2 === 0 ? "message:user" : "message:assistant",
    timestamp: new Date(Date.parse("2026-03-29T10:16:38.000Z") + index * 1000).toISOString(),
    text: `timeline-${index + 1}`,
  })),
  timelineTotal: 205,
  timelineNextOffset: 200,
} as SessionDetail;

describe("App", () => {
  const fetchMock = vi.fn<typeof fetch>();
  const clipboardWriteText = vi.fn();
  const confirmMock = vi.fn(() => true);
  let isNarrowViewport = false;

  beforeEach(() => {
    isNarrowViewport = false;
    window.localStorage.clear();
    vi.stubGlobal("fetch", fetchMock);
    vi.stubGlobal("confirm", confirmMock);
    vi.stubGlobal(
      "matchMedia",
      vi.fn().mockImplementation((query: string) => ({
        matches: isNarrowViewport && query === "(max-width: 767px)",
        media: query,
        onchange: null,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        addListener: vi.fn(),
        removeListener: vi.fn(),
        dispatchEvent: vi.fn(),
      })),
    );
    Object.assign(navigator, {
      clipboard: {
        writeText: clipboardWriteText,
      },
    });
  });

  afterEach(() => {
    window.localStorage.clear();
    vi.unstubAllGlobals();
    fetchMock.mockReset();
    clipboardWriteText.mockReset();
    confirmMock.mockReset();
  });

  test("defaults to English and persists the selected locale after switching", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha, sessionBeta] }));

    const firstView = renderAppWithoutLocale();

    expect(await screen.findByText("Codex Sessions")).toBeInTheDocument();
    expect(screen.getByText("2 indexed")).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "Active" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Repair official threads" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "English" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("textbox", { name: "Search sessions, paths, or excerpts" })).toBeInTheDocument();
    expect(window.localStorage.getItem(LOCALE_STORAGE_KEY)).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "中文" }));

    expect(await screen.findByText("Codex 会话")).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "活动" })).toBeInTheDocument();
    expect(window.localStorage.getItem(LOCALE_STORAGE_KEY)).toBe("zh");

    firstView.unmount();
    fetchMock.mockReset();
    fetchMock.mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha] }));

    render(<App />);

    expect(await screen.findByText("Codex 会话")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "中文" })).toHaveAttribute("aria-pressed", "true");
  });

  test("switches localized chrome without translating stored session content", async () => {
    const expectedEnglishTime = new Date(sessionAlpha.startedAt).toLocaleString("en-US", {
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    });
    const expectedChineseTime = new Date(sessionAlpha.startedAt).toLocaleString("zh-CN", {
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    });

    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha] }))
      .mockResolvedValueOnce(jsonResponse(alphaDetail));

    renderAppWithoutLocale();

    fireEvent.click(await screen.findByRole("button", { name: "Toggle project /work/project-alpha" }));
    fireEvent.click(await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }));

    await screen.findByRole("button", { name: "Restore to directory" });

    expect(screen.getByText(expectedEnglishTime)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Restore to directory" })).toBeInTheDocument();
    expect(screen.getByText("Official Codex sync")).toBeInTheDocument();
    expect(screen.getByText("Synced")).toBeInTheDocument();
    expect(
      screen.getByText("This session is synced to Official Codex threads and recent conversations."),
    ).toBeInTheDocument();
    expect(screen.getByText("Tool")).toBeInTheDocument();
    expect(screen.getByText("User")).toBeInTheDocument();
    expect(screen.getByText("Assistant")).toBeInTheDocument();
    expect(screen.getAllByText("我已经完成扫描并准备恢复。").length).toBeGreaterThan(0);

    fireEvent.click(screen.getByRole("button", { name: "中文" }));

    expect(await screen.findByText(expectedChineseTime)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "恢复到目录" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "切换项目 /work/project-alpha" })).toBeInTheDocument();
    expect(screen.getByText("官方 Codex 同步")).toBeInTheDocument();
    expect(screen.getByText("已同步")).toBeInTheDocument();
    expect(
      screen.getByText("这条会话已经同步到官方 Codex 的 threads 和 recent conversations。"),
    ).toBeInTheDocument();
    expect(screen.getByText("工具")).toBeInTheDocument();
    expect(screen.getByText("用户")).toBeInTheDocument();
    expect(screen.getByText("助手")).toBeInTheDocument();
    expect(screen.getAllByText("我已经完成扫描并准备恢复。").length).toBeGreaterThan(0);
  });

  test("localizes audit actions and official sync issues in English", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionBeta] }))
      .mockResolvedValueOnce(jsonResponse(betaDetail));

    renderAppWithoutLocale();

    fireEvent.click(await screen.findByRole("button", { name: "Toggle project /work/project-beta" }));
    fireEvent.click(await screen.findByRole("button", { name: /解释一下现有会话结构/i }));

    expect(await screen.findByText("Official Codex sync")).toBeInTheDocument();
    expect(screen.getByText("Needs repair")).toBeInTheDocument();
    expect(
      screen.getByText("This session is not fully synced with Official Codex local thread state."),
    ).toBeInTheDocument();
    expect(screen.getByText("Official threads is missing this thread record.")).toBeInTheDocument();
    expect(
      screen.getByText("Official recent conversations is missing this entry."),
    ).toBeInTheDocument();
    expect(
      screen.getByText((content) => content.startsWith("Archived · ")),
    ).toBeInTheDocument();
  });

  test("starts with projects collapsed, shows human-friendly session rows, and lets users open a project to read a session", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha, sessionBeta] }))
      .mockResolvedValueOnce(jsonResponse(alphaDetail));

    renderAppWithLocale();

    expect(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "切换项目 /work/project-beta" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "修复官方线程" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /请帮我恢复这个项目的会话/i })).not.toBeInTheDocument();
    expect(screen.getByText("从左侧选一个会话，右侧会显示摘要和完整线程。")).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "活动" })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "归档" })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "回收站" })).toBeInTheDocument();
    expect(screen.queryByRole("tab", { name: "可恢复" })).not.toBeInTheDocument();
    expect(screen.queryByRole("tab", { name: "全部" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "更多筛选" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "全选" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "移到回收站" })).not.toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "活动" })).toHaveAttribute("aria-selected", "true");

    fireEvent.click(screen.getByRole("button", { name: "切换项目 /work/project-alpha" }));
    expect(
      await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }),
    ).toBeInTheDocument();
    const alphaGroup = screen.getByTestId("project-group-/work/project-alpha");
    const alphaSession = within(alphaGroup).getByRole("button", {
      name: /请帮我恢复这个项目的会话/i,
    });
    expect(within(alphaSession).queryByText("session-alpha")).not.toBeInTheDocument();
    expect(within(alphaSession).queryByText("活动")).not.toBeInTheDocument();
    expect(within(alphaSession).getByText("我已经完成扫描并准备恢复。")).toBeInTheDocument();

    fireEvent.click(alphaSession);

    expect(await screen.findByText("shell · rg --files")).toBeInTheDocument();
    expect(screen.getAllByText("我已经完成扫描并准备恢复。").length).toBeGreaterThan(0);
    expect(screen.getByText("这条会话已经同步到官方 Codex 的 threads 和 recent conversations。")).toBeInTheDocument();
  });

  test("renders independent desktop scroll containers for the sidebar list and detail content", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha, sessionBeta] }))
      .mockResolvedValueOnce(jsonResponse(alphaDetail));

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));
    fireEvent.click(await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }));

    expect(await screen.findByTestId("session-sidebar-scroll")).toBeInTheDocument();
    expect(screen.getByTestId("reader-content")).toBeInTheDocument();
    expect(screen.getByTestId("session-sidebar")).toBeInTheDocument();
  });

  test("keeps batch toolbar disabled when only the current session is focused", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha] }))
      .mockResolvedValueOnce(jsonResponse(alphaDetail));

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));
    fireEvent.click(await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }));

    expect(await screen.findByRole("button", { name: "归档当前" })).toBeEnabled();
    expect(screen.queryByRole("button", { name: /^归档$/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "移到回收站" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^恢复$/ })).not.toBeInTheDocument();
    expect(screen.getByText("未选择批量项")).toBeInTheDocument();
  });

  test("switches filters through direct tabs", async () => {
    fetchMock
      .mockResolvedValueOnce(
        jsonResponse({ sessions: [sessionAlpha, sessionBeta, sessionArchived, sessionRestorable] }),
      )
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionArchived, sessionRestorable] }))
      .mockResolvedValueOnce(jsonResponse({ sessions: [] }));

    renderAppWithLocale();
    await screen.findByRole("button", { name: "切换项目 /work/project-alpha" });

    vi.useFakeTimers();

    try {
      fireEvent.click(screen.getByRole("tab", { name: "归档" }));

      await act(async () => {
        await vi.advanceTimersByTimeAsync(200);
      });

      expect(
        fetchMock.mock.calls.some(([url]) => url === "/api/sessions?status=archived"),
      ).toBe(true);
      expect(screen.getByRole("button", { name: "切换项目 /work/project-restorable" })).toBeInTheDocument();

      fireEvent.click(screen.getByRole("tab", { name: "回收站" }));

      await act(async () => {
        await vi.advanceTimersByTimeAsync(200);
      });

      expect(
        fetchMock.mock.calls.some(
          ([url]) => url === "/api/sessions?status=deleted_pending_purge",
        ),
      ).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  test("explains backup-only recovery in the detail view without exposing a restorable tab", async () => {
    fetchMock
      .mockResolvedValueOnce(
        jsonResponse({ sessions: [sessionAlpha, sessionArchived, sessionRestorable] }),
      )
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionArchived, sessionRestorable] }))
      .mockResolvedValueOnce(jsonResponse(restorableDetail));

    renderAppWithLocale();
    await screen.findByRole("button", { name: "切换项目 /work/project-alpha" });

    vi.useFakeTimers();

    try {
      fireEvent.click(screen.getByRole("tab", { name: "归档" }));

      await act(async () => {
        await vi.advanceTimersByTimeAsync(200);
      });

      expect(screen.queryByRole("tab", { name: "可恢复" })).not.toBeInTheDocument();

      fireEvent.click(screen.getByRole("button", { name: "切换项目 /work/project-restorable" }));
      fireEvent.click(screen.getByRole("button", { name: /这个会话还能恢复吗/i }));

      vi.useRealTimers();

      expect(await screen.findByText("仅剩备份，可恢复")).toBeInTheDocument();
      expect(
        screen.getByText("原会话文件已经不在活动区或归档区，当前只能从 snapshot 备份恢复。"),
      ).toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  test("does not keep refetching filtered sessions after a filter response settles", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha, sessionArchived] }))
      .mockResolvedValue(jsonResponse({ sessions: [sessionArchived] }));

    renderAppWithLocale();
    await screen.findByRole("button", { name: "切换项目 /work/project-alpha" });

    vi.useFakeTimers();

    try {
      fireEvent.click(screen.getByRole("tab", { name: "归档" }));

      await act(async () => {
        await vi.advanceTimersByTimeAsync(200);
      });

      await act(async () => {
        await vi.advanceTimersByTimeAsync(400);
      });

      expect(
        fetchMock.mock.calls.filter(([url]) => url === "/api/sessions?status=archived"),
      ).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });

  test("selects an entire project and sends a batch trash request", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha, sessionAlphaSibling, sessionBeta] }))
      .mockResolvedValueOnce(
        jsonResponse({
          records: [
            { ...sessionAlpha, status: "deleted_pending_purge" },
            { ...sessionAlphaSibling, status: "deleted_pending_purge" },
          ],
          failures: [],
        }),
      );

    renderAppWithLocale();

    expect(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "切换项目 /work/project-alpha" }));
    fireEvent.click(screen.getByRole("checkbox", { name: "选择项目 /work/project-alpha" }));

    await waitFor(() => {
      expect(screen.getByRole("checkbox", { name: "选择会话：请帮我恢复这个项目的会话" })).toBeChecked();
      expect(screen.getByRole("checkbox", { name: "选择会话：请继续整理这个项目的历史会话" })).toBeChecked();
    });

    expect(screen.getByText("已选 2 项")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "移到回收站" }));

    await waitFor(() => {
      expect(
        fetchMock.mock.calls.some(
          ([url, options]) =>
            url === "/api/sessions/batch/trash" &&
            options?.method === "POST" &&
            options.body === JSON.stringify({
              sessionIds: ["session-alpha", "session-alpha-sibling"],
            }),
        ),
      ).toBe(true);
    });
  });

  test("shows failed batch items with details", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha, sessionAlphaSibling] }))
      .mockResolvedValueOnce(
        jsonResponse({
          records: [{ ...sessionAlpha, status: "deleted_pending_purge" }],
          failures: [
            {
              sessionId: "session-alpha-sibling",
              error: "会话文件正在被占用，稍后再试。",
            },
          ],
        }),
      );

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));
    fireEvent.click(screen.getByRole("checkbox", { name: "选择项目 /work/project-alpha" }));
    fireEvent.click(screen.getByRole("button", { name: "移到回收站" }));

    expect(await screen.findByText("以下会话处理失败：")).toBeInTheDocument();
    expect(
      screen.getByText("session-alpha-sibling: 会话文件正在被占用，稍后再试。"),
    ).toBeInTheDocument();
  });

  test("keeps failed sessions visible after a partially failed trash purge", async () => {
    fetchMock
      .mockResolvedValueOnce(
        jsonResponse({
          sessions: [
            { ...sessionAlpha, status: "deleted_pending_purge" },
            { ...sessionAlphaSibling, status: "deleted_pending_purge" },
          ],
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          sessions: [
            { ...sessionAlpha, status: "deleted_pending_purge" },
            { ...sessionAlphaSibling, status: "deleted_pending_purge" },
          ],
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          ...alphaDetail,
          record: { ...sessionAlpha, status: "deleted_pending_purge" },
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          records: [],
          failures: [
            {
              sessionId: "session-alpha-sibling",
              error: "这条会话暂时无法清理。",
            },
          ],
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          sessions: [{ ...sessionAlphaSibling, status: "deleted_pending_purge" }],
        }),
      );

    renderAppWithLocale();
    await screen.findByRole("tab", { name: "活动" });

    vi.useFakeTimers();

    try {
      fireEvent.click(screen.getByRole("tab", { name: "回收站" }));

      await act(async () => {
        await vi.advanceTimersByTimeAsync(200);
      });
    } finally {
      vi.useRealTimers();
    }

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));
    fireEvent.click(await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }));
    fireEvent.click(screen.getByRole("button", { name: "清空回收站" }));

    expect(await screen.findByText("以下会话处理失败：")).toBeInTheDocument();
    expect(screen.getByText("session-alpha-sibling: 这条会话暂时无法清理。")).toBeInTheDocument();

    await waitFor(() => {
      expect(screen.queryByRole("button", { name: /请帮我恢复这个项目的会话/i })).not.toBeInTheDocument();
      expect(
        screen.getByRole("button", { name: /请继续整理这个项目的历史会话/i }),
      ).toBeInTheDocument();
    });
  });

  test("shows selection actions only after choosing sessions and keeps the labels compact", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha, sessionAlphaSibling] }));

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));

    expect(screen.getByRole("button", { name: "全选" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "清除" })).toBeDisabled();
    expect(screen.queryByRole("button", { name: "移到回收站" })).not.toBeInTheDocument();
    expect(screen.queryByText("全选当前筛选结果")).not.toBeInTheDocument();
    expect(screen.queryByText("清除选择")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("checkbox", { name: "选择项目 /work/project-alpha" }));

    expect(await screen.findByRole("button", { name: "移到回收站" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "清除" })).toBeEnabled();
  });

  test("restores a session to a chosen directory and shows the generated resume command", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha] }))
      .mockResolvedValueOnce(jsonResponse(alphaDetail))
      .mockResolvedValueOnce(
        jsonResponse({
          record: sessionAlpha,
          resumeCommand: "codex resume session-alpha -C /tmp/project-alpha",
          launched: false,
        }),
      );

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));
    fireEvent.click(await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }));
    fireEvent.change(await screen.findByLabelText("目标项目目录"), {
      target: { value: "/tmp/project-alpha" },
    });
    fireEvent.click(screen.getByRole("button", { name: "恢复到目录" }));

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/sessions/session-alpha/restore",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({
            restoreMode: "resume_only",
            targetCwd: "/tmp/project-alpha",
            launch: false,
          }),
        }),
      );
    });

    expect(
      await screen.findByText("codex resume session-alpha -C /tmp/project-alpha"),
    ).toBeInTheDocument();
  });

  test("supports permanently rebinding cwd from the detail view", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionArchived] }))
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionArchived] }))
      .mockResolvedValueOnce(
        jsonResponse({
          ...betaDetail,
          record: sessionArchived,
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          record: {
            ...sessionArchived,
            status: "active",
            activePath: "/tmp/example-home/.codex/sessions/2026/03/27/session-archived.jsonl",
            archivePath: null,
            cwd: "/tmp/rebound-project",
          },
          resumeCommand: "codex resume session-archived",
          launched: false,
        }),
      );

    renderAppWithLocale();

    await screen.findByRole("tab", { name: "活动" });

    vi.useFakeTimers();
    fireEvent.click(screen.getByRole("tab", { name: "归档" }));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(200);
    });
    vi.useRealTimers();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-archived" }));
    fireEvent.click(await screen.findByRole("button", { name: /把这个会话归档保存/i }));
    fireEvent.change(await screen.findByLabelText("目标项目目录"), {
      target: { value: "/tmp/rebound-project" },
    });
    fireEvent.click(screen.getByRole("radio", { name: "永久改目录" }));
    fireEvent.click(screen.getByRole("button", { name: "恢复并改目录" }));

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/sessions/session-archived/restore",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({
            restoreMode: "rebind_cwd",
            targetCwd: "/tmp/rebound-project",
            launch: false,
          }),
        }),
      );
    });

    expect(await screen.findByText("codex resume session-archived")).toBeInTheDocument();
    expect(screen.getByDisplayValue("/tmp/rebound-project")).toBeInTheDocument();
  });

  test("repairs official Codex thread stores from the UI", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha] }))
      .mockResolvedValueOnce(
        jsonResponse({
          sessions: [sessionAlpha],
          stats: {
            createdThreads: 1,
            updatedThreads: 0,
            updatedSessionIndexEntries: 1,
            removedBrokenThreads: 0,
            hiddenSnapshotOnlySessions: 0,
          },
        }),
      );

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "修复官方线程" }));

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/codex/repair",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ sessionIds: [] }),
        }),
      );
    });

    expect(
      await screen.findByText("官方线程修复完成：新建 1 条 threads，补齐 1 条 recent 索引。"),
    ).toBeInTheDocument();
  });

  test("shows restore validation errors inline instead of raw JSON", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha] }))
      .mockResolvedValueOnce(jsonResponse(alphaDetail))
      .mockResolvedValueOnce(
        errorResponse(400, "目标项目目录不存在，请先创建后再恢复。"),
      );

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));
    fireEvent.click(await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }));
    fireEvent.change(await screen.findByLabelText("目标项目目录"), {
      target: { value: "/tmp/missing-project" },
    });
    fireEvent.click(screen.getByRole("button", { name: "恢复到目录" }));

    expect(
      await screen.findByText("目标项目目录不存在，请先创建后再恢复。"),
    ).toBeInTheDocument();
    expect(screen.queryByText(/{"error":/)).not.toBeInTheDocument();
  });

  test("localizes known server validation errors in English", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha] }))
      .mockResolvedValueOnce(jsonResponse(alphaDetail))
      .mockResolvedValueOnce(
        errorResponse(400, "目标项目目录不存在，请先创建后再恢复。"),
      );

    renderAppWithoutLocale();

    fireEvent.click(await screen.findByRole("button", { name: "Toggle project /work/project-alpha" }));
    fireEvent.click(await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }));
    fireEvent.change(await screen.findByLabelText("Target project directory"), {
      target: { value: "/tmp/missing-project" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Restore to directory" }));

    expect(
      await screen.findByText(
        "The target project directory does not exist. Create it before restoring.",
      ),
    ).toBeInTheDocument();
    expect(screen.queryByText("目标项目目录不存在，请先创建后再恢复。")).not.toBeInTheDocument();
  });

  test("debounces remote search requests through the sessions API", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha, sessionBeta] }))
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionBeta] }));

    renderAppWithLocale();
    await screen.findByRole("button", { name: "切换项目 /work/project-alpha" });

    vi.useFakeTimers();

    try {
      fireEvent.change(screen.getByRole("textbox", { name: "搜索会话、路径或摘要" }), {
        target: { value: "beta" },
      });

      expect(
        fetchMock.mock.calls.some(
          ([url]) => url === "/api/sessions?query=beta&status=active",
        ),
      ).toBe(false);

      await act(async () => {
        await vi.advanceTimersByTimeAsync(200);
      });

      expect(
        fetchMock.mock.calls.some(
          ([url]) => url === "/api/sessions?query=beta&status=active",
        ),
      ).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  test("ignores stale detail responses when switching sessions quickly", async () => {
    const alphaDetailResponse = deferred<Response>();
    const betaDetailResponse = deferred<Response>();

    fetchMock.mockImplementation(async (input) => {
      const url = String(input);

      if (url === "/api/sessions/rescan") {
        return jsonResponse({ sessions: [sessionAlpha, sessionBeta] });
      }

      if (url === "/api/sessions/session-alpha") {
        return alphaDetailResponse.promise;
      }

      if (url === "/api/sessions/session-beta") {
        return betaDetailResponse.promise;
      }

      throw new Error(`Unexpected fetch: ${url}`);
    });

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));
    fireEvent.click(await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }));
    fireEvent.click(screen.getByRole("button", { name: "切换项目 /work/project-beta" }));
    fireEvent.click(await screen.findByRole("button", { name: /解释一下现有会话结构/i }));

    betaDetailResponse.resolve(jsonResponse(betaDetail));

    expect(await screen.findByRole("heading", { name: "解释一下现有会话结构" })).toBeInTheDocument();

    alphaDetailResponse.resolve(jsonResponse(alphaDetail));

    await waitFor(() => {
      expect(screen.getByRole("heading", { name: "解释一下现有会话结构" })).toBeInTheDocument();
      expect(screen.queryByRole("heading", { name: "请帮我恢复这个项目的会话" })).not.toBeInTheDocument();
    });
  });

  test("renders long timelines in batches with an explicit load more action", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha] }))
      .mockResolvedValueOnce(jsonResponse(longTimelineDetail))
      .mockResolvedValueOnce(
        jsonResponse({
          items: Array.from({ length: 5 }, (_, index) => ({
            id: `message-${index + 201}`,
            type: index % 2 === 0 ? "message:user" : "message:assistant",
            timestamp: new Date(
              Date.parse("2026-03-29T10:16:38.000Z") + (index + 200) * 1000,
            ).toISOString(),
            text: `timeline-${index + 201}`,
          })),
          total: 205,
          nextOffset: null,
        }),
      );

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));
    fireEvent.click(await screen.findByRole("button", { name: /请帮我恢复这个项目的会话/i }));

    expect(await screen.findByText("timeline-1")).toBeInTheDocument();
    expect(screen.getByText("timeline-200")).toBeInTheDocument();
    expect(screen.queryByText("timeline-201")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "加载更多 5 条" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "加载更多 5 条" }));

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith("/api/sessions/session-alpha/timeline?offset=200");
    });
    expect(await screen.findByText("timeline-201")).toBeInTheDocument();
    expect(screen.getByText("已加载 205 / 205 条")).toBeInTheDocument();
  });

  test("switches between the mobile session list and detail view with a back action", async () => {
    isNarrowViewport = true;
    fetchMock
      .mockResolvedValueOnce(jsonResponse({ sessions: [sessionAlpha] }))
      .mockResolvedValueOnce(jsonResponse(alphaDetail));

    renderAppWithLocale();

    fireEvent.click(await screen.findByRole("button", { name: "切换项目 /work/project-alpha" }));
    expect(screen.getByTestId("session-sidebar")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "返回列表" })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /请帮我恢复这个项目的会话/i }));

    expect(await screen.findByRole("button", { name: "返回列表" })).toBeInTheDocument();
    expect(screen.queryByTestId("session-sidebar")).not.toBeInTheDocument();
    expect(screen.getByText("shell · rg --files")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "返回列表" }));

    expect(await screen.findByTestId("session-sidebar")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "返回列表" })).not.toBeInTheDocument();
  });
});

function renderAppWithLocale(locale: UiLanguage = "zh") {
  window.localStorage.setItem(LOCALE_STORAGE_KEY, locale);
  return render(<App />);
}

function renderAppWithoutLocale() {
  window.localStorage.removeItem(LOCALE_STORAGE_KEY);
  return render(<App />);
}

function jsonResponse(payload: unknown): Response {
  return {
    ok: true,
    json: async () => payload,
    text: async () => JSON.stringify(payload),
  } as Response;
}

function errorResponse(status: number, message: string): Response {
  return {
    ok: false,
    status,
    json: async () => ({ error: message }),
    text: async () => JSON.stringify({ error: message }),
  } as Response;
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;

  const promise = new Promise<T>((nextResolve, nextReject) => {
    resolve = nextResolve;
    reject = nextReject;
  });

  return {
    promise,
    resolve,
    reject,
  };
}
