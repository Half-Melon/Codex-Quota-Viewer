import { createContext, useContext } from "react";

export type UiLanguage = "en" | "zh";

export type RestoreTargetErrorKey =
  | "missingDirectory"
  | "notDirectory"
  | "permissionDenied";

type TranslationSet = {
  languageNames: Record<UiLanguage, string>;
  topbar: {
    title: string;
    indexedCount: (count: number) => string;
    activeCount: (count: number) => string;
    archivedCount: (count: number) => string;
    trashCount: (count: number) => string;
    languageLabel: string;
  };
  sidebar: {
    title: string;
    repairOfficial: string;
    repairingOfficial: string;
    refresh: string;
    refreshing: string;
    searchLabel: string;
    searchPlaceholder: string;
    statusFilterLabel: string;
    selectProject: (cwd: string) => string;
    selectSession: (title: string) => string;
    toggleProject: (cwd: string) => string;
    unnamedSession: string;
    scanningOrFiltering: string;
    noMatches: string;
  };
  detail: {
    selectionSummaryBusy: string;
    selectionSummaryNone: string;
    selectionSummaryCount: (count: number) => string;
    backToList: string;
    selectAll: string;
    clear: string;
    emptyTrash: string;
    archive: string;
    moveToTrash: string;
    restore: string;
    failuresHeading: string;
    loadingSessionDetail: string;
    emptyDetail: string;
    backupOnlyNote: string;
    lineCount: (count: number) => string;
    eventCount: (count: number) => string;
    toolCallCount: (count: number) => string;
    userSummary: string;
    assistantSummary: string;
    emptySummary: string;
    targetProjectDirectory: string;
    restoreMode: string;
    resumeOnly: string;
    rebindCwd: string;
    restoreAndRebind: string;
    restoreToDirectory: string;
    archiveCurrent: string;
    repairCurrentThread: string;
    officialSync: string;
    copyCommand: string;
    emptyTimeline: string;
    loadedTimeline: (loaded: number, total: number) => string;
    loadingMore: string;
    loadMore: (count: number) => string;
    input: string;
    noInput: string;
    output: string;
    waitingOutput: string;
  };
  messages: {
    confirmTrashSelected: (count: number) => string;
    confirmEmptyTrash: (count: number) => string;
    archiveSelectionSuccess: string;
    trashSelectionSuccess: string;
    restoreSelectionSuccess: string;
    purgeTrashSuccess: string;
    partialBatchSuccess: (successMessage: string, failedCount: number) => string;
    currentRestored: string;
    currentArchived: string;
    resumeCopied: string;
  };
  statuses: Record<"active" | "archived" | "deleted_pending_purge" | "restorable", string>;
  officialStates: Record<"synced" | "repair_needed" | "hidden" | "unknown", string>;
  errors: {
    unknown: string;
    restoreTarget: Record<RestoreTargetErrorKey, string>;
  };
  repairFeedback: {
    alreadySynced: string;
    summary: (parts: string[]) => string;
    createdThreads: (count: number) => string;
    updatedThreads: (count: number) => string;
    updatedSessionIndexEntries: (count: number) => string;
    removedBrokenThreads: (count: number) => string;
    hiddenSnapshotOnlySessions: (count: number) => string;
  };
  project: {
    unnamedDirectory: string;
  };
};

export type I18nValue = {
  language: UiLanguage;
  locale: string;
  copy: TranslationSet;
  setLanguage: (language: UiLanguage) => void;
};

export const DEFAULT_LANGUAGE: UiLanguage = "en";
export const LOCALE_STORAGE_KEY = "codex-session-manager.locale";

const LOCALE_BY_LANGUAGE: Record<UiLanguage, string> = {
  en: "en-US",
  zh: "zh-CN",
};

const translations: Record<UiLanguage, TranslationSet> = {
  en: {
    languageNames: {
      en: "English",
      zh: "中文",
    },
    topbar: {
      title: "Codex Sessions",
      indexedCount: (count) => `${count} indexed`,
      activeCount: (count) => `${count} Active`,
      archivedCount: (count) => `${count} Archived`,
      trashCount: (count) => `${count} Trash`,
      languageLabel: "Language",
    },
    sidebar: {
      title: "Projects",
      repairOfficial: "Repair official threads",
      repairingOfficial: "Repairing...",
      refresh: "Refresh",
      refreshing: "Refreshing...",
      searchLabel: "Search sessions, paths, or excerpts",
      searchPlaceholder: "Search sessions, paths, or excerpts",
      statusFilterLabel: "Status filters",
      selectProject: (cwd) => `Select project ${cwd}`,
      selectSession: (title) => `Select session: ${title}`,
      toggleProject: (cwd) => `Toggle project ${cwd}`,
      unnamedSession: "Untitled session",
      scanningOrFiltering: "Scanning or filtering sessions...",
      noMatches: "No matching sessions. Try adjusting the filters.",
    },
    detail: {
      selectionSummaryBusy: "Processing...",
      selectionSummaryNone: "No batch selection",
      selectionSummaryCount: (count) => `${count} selected`,
      backToList: "Back to list",
      selectAll: "Select all",
      clear: "Clear",
      emptyTrash: "Empty trash",
      archive: "Archive",
      moveToTrash: "Move to trash",
      restore: "Restore",
      failuresHeading: "These sessions failed to process:",
      loadingSessionDetail: "Loading session details...",
      emptyDetail: "Select a session from the left to view the summary and full thread.",
      backupOnlyNote:
        "The original session file is no longer in the active or archived area, so it can only be restored from the snapshot backup.",
      lineCount: (count) => `${count} lines`,
      eventCount: (count) => `${count} events`,
      toolCallCount: (count) => `${count} tool calls`,
      userSummary: "User summary",
      assistantSummary: "Assistant summary",
      emptySummary: "None",
      targetProjectDirectory: "Target project directory",
      restoreMode: "Restore mode",
      resumeOnly: "Resume only",
      rebindCwd: "Rebind cwd",
      restoreAndRebind: "Restore and rebind cwd",
      restoreToDirectory: "Restore to directory",
      archiveCurrent: "Archive current",
      repairCurrentThread: "Repair this thread",
      officialSync: "Official Codex sync",
      copyCommand: "Copy command",
      emptyTimeline: "This session has no thread content to display yet.",
      loadedTimeline: (loaded, total) => `Loaded ${loaded} / ${total}`,
      loadingMore: "Loading more...",
      loadMore: (count) => `Load ${count} more`,
      input: "Input",
      noInput: "No input",
      output: "Output",
      waitingOutput: "Waiting for output",
    },
    messages: {
      confirmTrashSelected: (count) => `Move the selected ${count} sessions to trash?`,
      confirmEmptyTrash: (count) =>
        `Empty the ${count} trashed sessions in the current filtered results?`,
      archiveSelectionSuccess: "Archived the selected sessions.",
      trashSelectionSuccess: "Moved the selected sessions to trash.",
      restoreSelectionSuccess: "Restored the selected sessions.",
      purgeTrashSuccess: "Emptied the trashed sessions in the current filtered results.",
      partialBatchSuccess: (successMessage, failedCount) =>
        `${successMessage} ${failedCount} failed.`,
      currentRestored: "The current session has been restored to a Codex-recognized location.",
      currentArchived: "The current session has been archived.",
      resumeCopied: "Copied the resume command to the clipboard.",
    },
    statuses: {
      active: "Active",
      archived: "Archived",
      deleted_pending_purge: "Trash",
      restorable: "Backup only, restorable",
    },
    officialStates: {
      synced: "Synced",
      repair_needed: "Needs repair",
      hidden: "Hidden",
      unknown: "Unknown",
    },
    errors: {
      unknown: "Unknown error",
      restoreTarget: {
        missingDirectory: "The target project directory does not exist. Create it before restoring.",
        notDirectory: "The target project path is not a directory. Choose a directory instead.",
        permissionDenied:
          "Permission denied for the target project directory. Check the directory permissions.",
      },
    },
    repairFeedback: {
      alreadySynced:
        "Official Codex threads and recent conversations are already up to date.",
      summary: (parts) => `Official thread repair finished: ${parts.join(", ")}.`,
      createdThreads: (count) => `created ${count} thread${count === 1 ? "" : "s"}`,
      updatedThreads: (count) => `updated ${count} thread${count === 1 ? "" : "s"}`,
      updatedSessionIndexEntries: (count) =>
        `filled ${count} recent conversation entr${count === 1 ? "y" : "ies"}`,
      removedBrokenThreads: (count) =>
        `removed ${count} broken thread${count === 1 ? "" : "s"}`,
      hiddenSnapshotOnlySessions: (count) =>
        `hid ${count} snapshot-only thread${count === 1 ? "" : "s"}`,
    },
    project: {
      unnamedDirectory: "Unnamed directory",
    },
  },
  zh: {
    languageNames: {
      en: "English",
      zh: "中文",
    },
    topbar: {
      title: "Codex 会话",
      indexedCount: (count) => `${count} 条索引`,
      activeCount: (count) => `${count} 活动`,
      archivedCount: (count) => `${count} 归档`,
      trashCount: (count) => `${count} 回收站`,
      languageLabel: "语言",
    },
    sidebar: {
      title: "项目目录",
      repairOfficial: "修复官方线程",
      repairingOfficial: "修复中...",
      refresh: "刷新",
      refreshing: "刷新中...",
      searchLabel: "搜索会话、路径或摘要",
      searchPlaceholder: "搜索会话、路径或摘要",
      statusFilterLabel: "状态筛选",
      selectProject: (cwd) => `选择项目 ${cwd}`,
      selectSession: (title) => `选择会话：${title}`,
      toggleProject: (cwd) => `切换项目 ${cwd}`,
      unnamedSession: "未命名会话",
      scanningOrFiltering: "正在扫描或筛选会话...",
      noMatches: "没有匹配的会话，试试调整筛选条件。",
    },
    detail: {
      selectionSummaryBusy: "处理中...",
      selectionSummaryNone: "未选择批量项",
      selectionSummaryCount: (count) => `已选 ${count} 项`,
      backToList: "返回列表",
      selectAll: "全选",
      clear: "清除",
      emptyTrash: "清空回收站",
      archive: "归档",
      moveToTrash: "移到回收站",
      restore: "恢复",
      failuresHeading: "以下会话处理失败：",
      loadingSessionDetail: "正在加载会话详情...",
      emptyDetail: "从左侧选一个会话，右侧会显示摘要和完整线程。",
      backupOnlyNote: "原会话文件已经不在活动区或归档区，当前只能从 snapshot 备份恢复。",
      lineCount: (count) => `${count} 行`,
      eventCount: (count) => `${count} 事件`,
      toolCallCount: (count) => `${count} 次工具调用`,
      userSummary: "用户摘要",
      assistantSummary: "助手摘要",
      emptySummary: "暂无",
      targetProjectDirectory: "目标项目目录",
      restoreMode: "恢复模式",
      resumeOnly: "仅用于 resume",
      rebindCwd: "永久改目录",
      restoreAndRebind: "恢复并改目录",
      restoreToDirectory: "恢复到目录",
      archiveCurrent: "归档当前",
      repairCurrentThread: "修复这个线程",
      officialSync: "官方 Codex 同步",
      copyCommand: "复制命令",
      emptyTimeline: "这个会话还没有可展示的线程内容。",
      loadedTimeline: (loaded, total) => `已加载 ${loaded} / ${total} 条`,
      loadingMore: "正在加载更多...",
      loadMore: (count) => `加载更多 ${count} 条`,
      input: "输入",
      noInput: "无输入",
      output: "输出",
      waitingOutput: "等待输出",
    },
    messages: {
      confirmTrashSelected: (count) => `确认将选中的 ${count} 条会话移到回收站吗？`,
      confirmEmptyTrash: (count) => `确认清空当前筛选结果中的 ${count} 条回收站会话吗？`,
      archiveSelectionSuccess: "已归档选中的会话。",
      trashSelectionSuccess: "已将选中的会话移到回收站。",
      restoreSelectionSuccess: "已恢复选中的会话。",
      purgeTrashSuccess: "已清空当前筛选结果中的回收站会话。",
      partialBatchSuccess: (successMessage, failedCount) =>
        `${successMessage} 其中 ${failedCount} 条失败。`,
      currentRestored: "当前会话已恢复到 Codex 可识别位置。",
      currentArchived: "当前会话已归档。",
      resumeCopied: "resume 命令已复制到剪贴板。",
    },
    statuses: {
      active: "活动",
      archived: "归档",
      deleted_pending_purge: "回收站",
      restorable: "仅剩备份，可恢复",
    },
    officialStates: {
      synced: "已同步",
      repair_needed: "待修复",
      hidden: "已隐藏",
      unknown: "未知",
    },
    errors: {
      unknown: "未知错误",
      restoreTarget: {
        missingDirectory: "目标项目目录不存在，请先创建后再恢复。",
        notDirectory: "目标项目目录不是文件夹，请重新选择目录。",
        permissionDenied: "当前没有权限访问目标项目目录，请检查目录权限。",
      },
    },
    repairFeedback: {
      alreadySynced: "官方 Codex 的 threads 和 recent conversations 已经是最新状态。",
      summary: (parts) => `官方线程修复完成：${parts.join("，")}。`,
      createdThreads: (count) => `新建 ${count} 条 threads`,
      updatedThreads: (count) => `更新 ${count} 条 threads`,
      updatedSessionIndexEntries: (count) => `补齐 ${count} 条 recent 索引`,
      removedBrokenThreads: (count) => `清理 ${count} 条坏线程`,
      hiddenSnapshotOnlySessions: (count) => `隐藏 ${count} 条仅剩备份的线程`,
    },
    project: {
      unnamedDirectory: "未命名目录",
    },
  },
};

export const I18nContext = createContext<I18nValue | null>(null);

export function getTranslation(language: UiLanguage) {
  return translations[language];
}

export function resolveLocale(language: UiLanguage) {
  return LOCALE_BY_LANGUAGE[language];
}

export function isUiLanguage(value: string | null | undefined): value is UiLanguage {
  return value === "en" || value === "zh";
}

export function readStoredLanguage() {
  if (typeof window === "undefined") {
    return DEFAULT_LANGUAGE;
  }

  try {
    const storedLanguage = window.localStorage.getItem(LOCALE_STORAGE_KEY);
    return isUiLanguage(storedLanguage) ? storedLanguage : DEFAULT_LANGUAGE;
  } catch {
    return DEFAULT_LANGUAGE;
  }
}

export function useI18n() {
  const value = useContext(I18nContext);

  if (!value) {
    throw new Error("I18n context is not available.");
  }

  return value;
}

export type { TranslationSet };
