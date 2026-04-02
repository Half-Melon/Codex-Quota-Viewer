import { useCallback, useEffect, useState } from "react";

import { fetchUiConfig } from "./api";
import { SessionDetail as SessionReader } from "./components/SessionDetail";
import { SessionList } from "./components/SessionList";
import {
  DEFAULT_LANGUAGE,
  I18nContext,
  getTranslation,
  isUiLanguage,
  resolveLocale,
  type UiLanguage,
} from "./i18n";
import { useSessionBrowser } from "./use-session-browser";

declare global {
  interface Window {
    __CODEX_VIEWER_UI_CONFIG__?: {
      language?: UiLanguage;
    };
  }
}

export default function App() {
  const [language, setLanguageState] = useState<UiLanguage>(() => readInjectedLanguage());
  const locale = resolveLocale(language);
  const copy = getTranslation(language);
  const i18nValue = {
    language,
    locale,
    copy,
  };
  const browser = useSessionBrowser(copy);

  const reloadUiLanguage = useCallback(async () => {
    try {
      const uiConfig = await fetchUiConfig();
      if (isUiLanguage(uiConfig.language)) {
        setLanguageState(uiConfig.language);
      }
    } catch {
      // Keep the current language if the config endpoint is temporarily unavailable.
    }
  }, []);

  useEffect(() => {
    if (!isUiLanguage(window.__CODEX_VIEWER_UI_CONFIG__?.language)) {
      void reloadUiLanguage();
    }
  }, [reloadUiLanguage]);

  useEffect(() => {
    const refreshUiLanguage = () => {
      void reloadUiLanguage();
    };
    const handleVisibilityChange = () => {
      if (!document.hidden) {
        void reloadUiLanguage();
      }
    };

    window.addEventListener("focus", refreshUiLanguage);
    document.addEventListener("visibilitychange", handleVisibilityChange);

    return () => {
      window.removeEventListener("focus", refreshUiLanguage);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, [reloadUiLanguage]);

  useEffect(() => {
    document.documentElement.lang = language === "zh" ? "zh-CN" : "en-US";
  }, [language]);

  return (
    <I18nContext.Provider value={i18nValue}>
      <main className="app-shell">
        <header className="app-topbar">
          <div className="app-topbar__title">
            <strong>{copy.topbar.title}</strong>
            <span>{copy.topbar.indexedCount(browser.indexedSessions.length)}</span>
          </div>
          <div className="app-topbar__stats">
            <span>
              {copy.topbar.activeCount(
                browser.indexedSessions.filter((session) => session.status === "active").length,
              )}
            </span>
            <span>{copy.topbar.archivedCount(browser.archivedLikeCount)}</span>
            <span>
              {copy.topbar.trashCount(
                browser.indexedSessions.filter(
                  (session) => session.status === "deleted_pending_purge",
                ).length,
              )}
            </span>
          </div>
        </header>

        {browser.error ? (
          <div className="app-banner app-banner--error" role="alert">
            {browser.error}
          </div>
        ) : null}

        <section className="app-workspace">
          <div className="app-workspace__inner">
            {browser.shouldRenderSidebar ? (
              <div className="app-workspace__sidebar-shell">
                <SessionList
                  sessions={browser.listedSessions}
                  indexedCount={browser.indexedSessions.length}
                  loading={browser.loadingSessions}
                  search={browser.search}
                  status={browser.status}
                  selectedId={browser.focusedSessionId}
                  selectedIds={browser.checkedSessionIds}
                  onSearchChange={browser.setSearch}
                  onStatusChange={browser.setStatus}
                  onRescan={() => void browser.loadInitialIndex()}
                  onRepairOfficial={() =>
                    void browser.runAction(
                      "repair-official-all",
                      browser.repairAllOfficialThreads,
                    )
                  }
                  repairingOfficial={browser.busyAction === "repair-official-all"}
                  busy={!!browser.busyAction}
                  onSelect={browser.selectSession}
                  onToggleChecked={browser.toggleChecked}
                  onToggleProject={browser.toggleProject}
                />
              </div>
            ) : null}
            {browser.shouldRenderDetail ? (
              <div className="app-workspace__detail-shell">
                <SessionReader
                  detail={browser.detail}
                  loadingDetail={browser.loadingDetail}
                  loadingTimeline={browser.loadingTimeline}
                  targetCwd={browser.targetCwd}
                  restoreMode={browser.restoreMode}
                  restoreTargetError={browser.restoreTargetError}
                  feedback={browser.feedback}
                  batchFailures={browser.batchFailures}
                  resumeCommand={browser.resumeCommand}
                  busyAction={browser.busyAction}
                  checkedCount={browser.checkedSessionIds.length}
                  showEmptyTrashAction={
                    browser.status === "deleted_pending_purge" && browser.trashIds.length > 0
                  }
                  visibleSessionCount={browser.listedSessions.length}
                  canArchiveSelection={browser.canArchiveBatch}
                  canTrashSelection={browser.canTrashBatch}
                  canRestoreSelection={browser.canRestoreBatch}
                  canRestoreCurrent={browser.canRestoreCurrent}
                  canArchiveCurrent={browser.canArchiveCurrent}
                  showBackToList={browser.isNarrowViewport && browser.focusedSessionId !== null}
                  onBackToList={browser.showSessionList}
                  onTargetCwdChange={browser.setTargetCwd}
                  onRestoreModeChange={browser.setRestoreMode}
                  onSelectAllVisible={() =>
                    browser.setCheckedSessionIds(
                      browser.listedSessions.map((session) => session.id),
                    )
                  }
                  onClearSelection={() => browser.setCheckedSessionIds([])}
                  onArchiveSelected={() =>
                    void browser.runAction("batch-archive", browser.archiveSelected)
                  }
                  onTrashSelected={() =>
                    void browser.runAction("batch-trash", browser.trashSelected)
                  }
                  onRestoreSelected={() =>
                    void browser.runAction("batch-restore", browser.restoreSelected)
                  }
                  onEmptyTrash={() => void browser.runAction("batch-purge", browser.purgeTrash)}
                  onRestoreCurrentToDirectory={() => void browser.restoreCurrentToDirectory()}
                  onArchiveCurrent={() =>
                    void browser.runAction("archive-current", browser.archiveCurrent)
                  }
                  onRepairCurrentOfficial={() =>
                    void browser.runAction(
                      "repair-official-current",
                      browser.repairCurrentOfficialThread,
                    )
                  }
                  onCopyCommand={() => void browser.copyResumeCommand()}
                  onLoadMoreTimeline={() => void browser.loadMoreTimeline()}
                />
              </div>
            ) : null}
          </div>
        </section>
      </main>
    </I18nContext.Provider>
  );
}

function readInjectedLanguage(): UiLanguage {
  if (typeof window === "undefined") {
    return DEFAULT_LANGUAGE;
  }

  const injectedLanguage = window.__CODEX_VIEWER_UI_CONFIG__?.language;
  return isUiLanguage(injectedLanguage) ? injectedLanguage : DEFAULT_LANGUAGE;
}
