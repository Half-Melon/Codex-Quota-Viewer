import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type {
  BatchSessionActionFailure,
  BatchSessionActionResponse,
  RestoreMode,
  SessionDetail,
  SessionFilters,
  SessionRecord,
  SessionStatus,
} from "../shared/contracts";
import {
  archiveSession,
  batchArchiveSessions,
  batchPurgeSessions,
  batchRestoreSessions,
  batchTrashSessions,
  fetchSessionDetail,
  fetchSessionTimelinePage,
  listSessions,
  repairOfficialThreads,
  rescanSessions,
  restoreSession,
} from "./api";
import type { TranslationSet } from "./i18n";
import {
  buildFilters,
  buildOfficialRepairFeedback,
  canRestoreSessionStatus,
  canResumeSessionStatus,
  canTrashSessionStatus,
  filterVisibleSessions,
  isArchivedViewStatus,
  NARROW_VIEWPORT_MEDIA_QUERY,
  isRestoreTargetError,
  mergeSessionList,
  readError,
  readMediaQueryMatch,
  subscribeMediaQuery,
} from "./session-browser-helpers";

const DEFAULT_STATUS: SessionStatus = "active";
const FILTER_DEBOUNCE_MS = 200;

export function useSessionBrowser(copy: TranslationSet) {
  const [indexedSessions, setIndexedSessions] = useState<SessionRecord[]>([]);
  const [listedSessions, setListedSessions] = useState<SessionRecord[]>([]);
  const [focusedSessionId, setFocusedSessionId] = useState<string | null>(null);
  const [checkedSessionIds, setCheckedSessionIds] = useState<string[]>([]);
  const [detail, setDetail] = useState<SessionDetail | null>(null);
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState<SessionStatus>(DEFAULT_STATUS);
  const [targetCwd, setTargetCwd] = useState("");
  const [restoreMode, setRestoreMode] = useState<RestoreMode>("resume_only");
  const [feedback, setFeedback] = useState<string | null>(null);
  const [resumeCommand, setResumeCommand] = useState<string | null>(null);
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [restoreTargetError, setRestoreTargetError] = useState<string | null>(null);
  const [batchFailures, setBatchFailures] = useState<BatchSessionActionFailure[]>([]);
  const [loadingSessions, setLoadingSessions] = useState(true);
  const [loadingDetail, setLoadingDetail] = useState(false);
  const [loadingTimeline, setLoadingTimeline] = useState(false);
  const [hasLoadedInitialIndex, setHasLoadedInitialIndex] = useState(false);
  const [isNarrowViewport, setIsNarrowViewport] = useState(() =>
    readMediaQueryMatch(NARROW_VIEWPORT_MEDIA_QUERY),
  );
  const [showMobileList, setShowMobileList] = useState(() =>
    readMediaQueryMatch(NARROW_VIEWPORT_MEDIA_QUERY),
  );

  const listRequestSequenceRef = useRef(0);
  const detailRequestSequenceRef = useRef(0);
  const loadInitialIndexRef = useRef<() => Promise<void>>(async () => {});
  const loadDetailRef = useRef<(sessionId: string, requestId: number) => Promise<void>>(
    async () => {},
  );
  const latestListStateRef = useRef({
    search,
    status,
    indexedSessions,
  });

  const loadListedSessions = useCallback(async (filters: SessionFilters) => {
    const requestId = ++listRequestSequenceRef.current;

    setLoadingSessions(true);
    setError(null);

    try {
      const response = await listSessions(filters);

      if (listRequestSequenceRef.current !== requestId) {
        return;
      }

      setListedSessions(response.sessions);
      setIndexedSessions((current) =>
        mergeSessionList(
          current,
          new Map(response.sessions.map((record) => [record.id, record])),
        ),
      );
    } catch (loadError) {
      if (listRequestSequenceRef.current !== requestId) {
        return;
      }

      setError(readError(loadError, copy));
    } finally {
      if (listRequestSequenceRef.current === requestId) {
        setLoadingSessions(false);
      }
    }
  }, [copy]);

  loadInitialIndexRef.current = loadInitialIndex;
  loadDetailRef.current = loadDetail;

  useEffect(() => {
    void loadInitialIndexRef.current();
  }, []);

  useEffect(() => {
    if (!hasLoadedInitialIndex) {
      return;
    }

    if (search.trim().length > 0 || status !== DEFAULT_STATUS) {
      return;
    }

    listRequestSequenceRef.current += 1;
    setListedSessions(filterVisibleSessions(indexedSessions, search, status));
    setLoadingSessions(false);
  }, [hasLoadedInitialIndex, indexedSessions, search, status]);

  useEffect(() => {
    if (!hasLoadedInitialIndex) {
      return;
    }

    const nextFilters = buildFilters(search, status);

    if (!nextFilters.query && status === DEFAULT_STATUS) {
      return;
    }

    const timeoutId = window.setTimeout(() => {
      void loadListedSessions(nextFilters);
    }, FILTER_DEBOUNCE_MS);

    return () => {
      window.clearTimeout(timeoutId);
    };
  }, [hasLoadedInitialIndex, loadListedSessions, search, status]);

  useEffect(() => {
    latestListStateRef.current = {
      search,
      status,
      indexedSessions,
    };
  }, [indexedSessions, search, status]);

  useEffect(() => {
    return subscribeMediaQuery(NARROW_VIEWPORT_MEDIA_QUERY, setIsNarrowViewport);
  }, []);

  useEffect(() => {
    if (!isNarrowViewport) {
      setShowMobileList(false);
      return;
    }

    if (!focusedSessionId) {
      setShowMobileList(true);
    }
  }, [focusedSessionId, isNarrowViewport]);

  useEffect(() => {
    const visibleIdSet = new Set(listedSessions.map((session) => session.id));

    setCheckedSessionIds((current) => {
      const next = current.filter((sessionId) => visibleIdSet.has(sessionId));
      return next.length === current.length ? current : next;
    });

    if (listedSessions.length === 0) {
      setFocusedSessionId(null);
      return;
    }

    if (focusedSessionId && !visibleIdSet.has(focusedSessionId)) {
      setFocusedSessionId(null);
    }
  }, [focusedSessionId, listedSessions]);

  useEffect(() => {
    if (!focusedSessionId) {
      detailRequestSequenceRef.current += 1;
      setDetail(null);
      setTargetCwd("");
      setRestoreMode("resume_only");
      setRestoreTargetError(null);
      setLoadingDetail(false);
      setLoadingTimeline(false);
      return;
    }

    const requestId = ++detailRequestSequenceRef.current;

    setLoadingDetail(true);
    setDetail(null);
    setRestoreTargetError(null);
    setResumeCommand(null);
    setError(null);
    setBatchFailures([]);
    setLoadingTimeline(false);

    void loadDetailRef.current(focusedSessionId, requestId);
  }, [focusedSessionId]);

  const indexedSessionMap = useMemo(
    () => new Map(indexedSessions.map((session) => [session.id, session])),
    [indexedSessions],
  );
  const checkedSessionRecords = useMemo(
    () =>
      checkedSessionIds
        .map((sessionId) => indexedSessionMap.get(sessionId))
        .filter((session): session is SessionRecord => Boolean(session)),
    [checkedSessionIds, indexedSessionMap],
  );
  const currentRecord = detail?.record ?? null;
  const archivedLikeCount = useMemo(
    () => indexedSessions.filter((session) => isArchivedViewStatus(session.status)).length,
    [indexedSessions],
  );
  const trashIds = useMemo(
    () =>
      listedSessions
        .filter((session) => session.status === "deleted_pending_purge")
        .map((session) => session.id),
    [listedSessions],
  );
  const canArchiveBatch =
    checkedSessionRecords.length > 0 &&
    checkedSessionRecords.every((session) => session.status === "active");
  const canTrashBatch =
    checkedSessionRecords.length > 0 &&
    checkedSessionRecords.every((session) => canTrashSessionStatus(session.status));
  const canRestoreBatch =
    checkedSessionRecords.length > 0 &&
    checkedSessionRecords.every((session) => canRestoreSessionStatus(session.status));
  const canRestoreCurrent =
    currentRecord !== null && canResumeSessionStatus(currentRecord.status);
  const canArchiveCurrent = currentRecord?.status === "active";

  return {
    indexedSessions,
    listedSessions,
    focusedSessionId,
    checkedSessionIds,
    detail,
    search,
    status,
    targetCwd,
    restoreMode,
    feedback,
    resumeCommand,
    busyAction,
    error,
    restoreTargetError,
    batchFailures,
    loadingSessions,
    loadingDetail,
    loadingTimeline,
    isNarrowViewport,
    showMobileList,
    archivedLikeCount,
    trashIds,
    canArchiveBatch,
    canTrashBatch,
    canRestoreBatch,
    canRestoreCurrent,
    canArchiveCurrent,
    setSearch,
    setStatus,
    setTargetCwd,
    setRestoreMode,
    setCheckedSessionIds,
    rescanIndex,
    selectSession,
    showSessionList,
    toggleChecked,
    toggleProject,
    runAction,
    archiveSelected,
    trashSelected,
    restoreSelected,
    purgeTrash,
    restoreCurrentToDirectory,
    archiveCurrent,
    repairAllOfficialThreads,
    repairCurrentOfficialThread,
    copyResumeCommand,
    loadMoreTimeline,
  };

  async function loadInitialIndex() {
    const requestId = ++listRequestSequenceRef.current;

    setLoadingSessions(true);
    setError(null);

    try {
      const response = await listSessions(buildFilters("", DEFAULT_STATUS));

      if (listRequestSequenceRef.current !== requestId) {
        return;
      }

      setIndexedSessions(response.sessions);
      const latest = latestListStateRef.current;
      setListedSessions(filterVisibleSessions(response.sessions, latest.search, latest.status));
      setHasLoadedInitialIndex(true);
      setResumeCommand(null);
      setFeedback(null);
      setBatchFailures([]);
    } catch (loadError) {
      if (listRequestSequenceRef.current !== requestId) {
        return;
      }

      setError(readError(loadError, copy));
    } finally {
      if (listRequestSequenceRef.current === requestId) {
        setLoadingSessions(false);
      }
    }
  }

  async function rescanIndex() {
    const requestId = ++listRequestSequenceRef.current;

    setLoadingSessions(true);
    setError(null);

    try {
      const response = await rescanSessions();

      if (listRequestSequenceRef.current !== requestId) {
        return;
      }

      setIndexedSessions(response.sessions);
      const latest = latestListStateRef.current;
      setListedSessions(filterVisibleSessions(response.sessions, latest.search, latest.status));
      setHasLoadedInitialIndex(true);
      setResumeCommand(null);
      setFeedback(null);
      setBatchFailures([]);
    } catch (loadError) {
      if (listRequestSequenceRef.current !== requestId) {
        return;
      }

      setError(readError(loadError, copy));
    } finally {
      if (listRequestSequenceRef.current === requestId) {
        setLoadingSessions(false);
      }
    }
  }

  async function loadDetail(sessionId: string, requestId: number) {
    try {
      setError(null);
      const nextDetail = await fetchSessionDetail(sessionId);

      if (detailRequestSequenceRef.current !== requestId) {
        return;
      }

      setDetail(nextDetail);
      setTargetCwd(nextDetail.record.cwd);
      setRestoreMode("resume_only");
      mergeRecords([nextDetail.record]);
    } catch (loadError) {
      if (detailRequestSequenceRef.current !== requestId) {
        return;
      }

      setError(readError(loadError, copy));
    } finally {
      if (detailRequestSequenceRef.current === requestId) {
        setLoadingDetail(false);
      }
    }
  }

  async function runAction(label: string, action: () => Promise<void>) {
    try {
      setBusyAction(label);
      clearActionFeedback();
      await action();
    } catch (actionError) {
      setError(readError(actionError, copy));
    } finally {
      setBusyAction(null);
    }
  }

  async function archiveSelected() {
    const response = await batchArchiveSessions(checkedSessionIds);
    syncBatch(response, copy.messages.archiveSelectionSuccess);
  }

  async function trashSelected() {
    if (checkedSessionIds.length === 0) {
      return;
    }

    if (!confirmAction(copy.messages.confirmTrashSelected(checkedSessionIds.length))) {
      return;
    }

    const response = await batchTrashSessions(checkedSessionIds);
    syncBatch(response, copy.messages.trashSelectionSuccess);
  }

  async function restoreSelected() {
    const response = await batchRestoreSessions(checkedSessionIds);
    syncBatch(response, copy.messages.restoreSelectionSuccess);
  }

  async function purgeTrash() {
    if (trashIds.length === 0) {
      return;
    }

    if (!confirmAction(copy.messages.confirmEmptyTrash(trashIds.length))) {
      return;
    }

    const response = await batchPurgeSessions(trashIds);
    const failedIdSet = new Set(response.failures.map((failure) => failure.sessionId));
    const purgedIds = trashIds.filter((sessionId) => !failedIdSet.has(sessionId));
    removeRecords(purgedIds);
    syncBatch(response, copy.messages.purgeTrashSuccess);
  }

  async function restoreCurrentToDirectory() {
    if (!focusedSessionId) {
      return;
    }

    try {
      setBusyAction("restore-current");
      clearActionFeedback();

      const response = await restoreSession(focusedSessionId, {
        restoreMode,
        targetCwd: targetCwd.trim() || undefined,
        launch: false,
      });

      mergeRecords([response.record]);
      setDetail((current) =>
        current && current.record.id === response.record.id
          ? { ...current, record: response.record }
          : current,
      );
      setTargetCwd(response.record.cwd);
      setFeedback(copy.messages.currentRestored);
      setResumeCommand(response.resumeCommand);
      await refreshListedSessionsForCurrentFilters();
    } catch (actionError) {
      const message = readError(actionError, copy);

      if (isRestoreTargetError(actionError)) {
        setRestoreTargetError(message);
        return;
      }

      setError(message);
    } finally {
      setBusyAction(null);
    }
  }

  async function archiveCurrent() {
    if (!focusedSessionId) {
      return;
    }

    const record = await archiveSession(focusedSessionId);
    mergeRecords([record]);
    setDetail((current) =>
      current && current.record.id === record.id
        ? { ...current, record }
        : current,
    );
    setFeedback(copy.messages.currentArchived);
    setResumeCommand(null);
    await refreshListedSessionsForCurrentFilters();
  }

  async function repairAllOfficialThreads() {
    const response = await repairOfficialThreads();
    replaceSessions(response.sessions);
    setFeedback(buildOfficialRepairFeedback(response.stats, copy));
    await refreshFocusedDetail();
  }

  async function repairCurrentOfficialThread() {
    if (!focusedSessionId) {
      return;
    }

    const response = await repairOfficialThreads([focusedSessionId]);
    replaceSessions(response.sessions);
    setFeedback(buildOfficialRepairFeedback(response.stats, copy));
    await refreshFocusedDetail();
  }

  async function copyResumeCommand() {
    if (!resumeCommand) {
      return;
    }

    try {
      await navigator.clipboard.writeText(resumeCommand);
      setFeedback(copy.messages.resumeCopied);
    } catch (copyError) {
      setError(readError(copyError, copy));
    }
  }

  async function loadMoreTimeline() {
    if (!detail?.record.id || detail.timelineNextOffset === null || loadingTimeline) {
      return;
    }

    const requestId = detailRequestSequenceRef.current;
    setLoadingTimeline(true);

    try {
      const nextPage = await fetchSessionTimelinePage(detail.record.id, {
        offset: detail.timelineNextOffset,
      });

      if (detailRequestSequenceRef.current !== requestId) {
        return;
      }

      setDetail((current) => {
        if (!current || current.record.id !== detail.record.id) {
          return current;
        }

        const existingItemIds = new Set(current.timeline.map((item) => item.id));
        const appendedItems = nextPage.items.filter((item) => !existingItemIds.has(item.id));

        return {
          ...current,
          timeline: [...current.timeline, ...appendedItems],
          timelineTotal: nextPage.total,
          timelineNextOffset: nextPage.nextOffset,
        };
      });
    } catch (loadError) {
      setError(readError(loadError, copy));
    } finally {
      if (detailRequestSequenceRef.current === requestId) {
        setLoadingTimeline(false);
      }
    }
  }

  function toggleChecked(sessionId: string, checked: boolean) {
    setCheckedSessionIds((current) => {
      if (checked) {
        return current.includes(sessionId) ? current : [...current, sessionId];
      }

      return current.filter((value) => value !== sessionId);
    });
  }

  function toggleProject(cwd: string, checked: boolean) {
    const projectSessionIds = listedSessions
      .filter((session) => session.cwd === cwd)
      .map((session) => session.id);

    setCheckedSessionIds((current) => {
      if (checked) {
        return [...new Set([...current, ...projectSessionIds])];
      }

      const projectIdSet = new Set(projectSessionIds);
      return current.filter((sessionId) => !projectIdSet.has(sessionId));
    });
  }

  function syncBatch(response: BatchSessionActionResponse, successMessage: string) {
    mergeRecords(response.records);
    setCheckedSessionIds([]);
    setResumeCommand(null);
    setBatchFailures(response.failures);

    if (response.failures.length === 0) {
      setFeedback(successMessage);
      void refreshListedSessionsForCurrentFilters();
      return;
    }

    if (response.records.length > 0) {
      setFeedback(copy.messages.partialBatchSuccess(successMessage, response.failures.length));
    }

    void refreshListedSessionsForCurrentFilters();
  }

  function mergeRecords(records: SessionRecord[]) {
    if (records.length === 0) {
      return;
    }

    const recordMap = new Map(records.map((record) => [record.id, record]));
    setIndexedSessions((current) => mergeSessionList(current, recordMap));
    setListedSessions((current) => mergeSessionList(current, recordMap));
  }

  function replaceSessions(nextSessions: SessionRecord[]) {
    setIndexedSessions(nextSessions);
    const latest = latestListStateRef.current;
    setListedSessions(filterVisibleSessions(nextSessions, latest.search, latest.status));
  }

  function removeRecords(sessionIds: string[]) {
    if (sessionIds.length === 0) {
      return;
    }

    const removedIdSet = new Set(sessionIds);
    setIndexedSessions((current) => current.filter((session) => !removedIdSet.has(session.id)));
    setListedSessions((current) => current.filter((session) => !removedIdSet.has(session.id)));
    setCheckedSessionIds((current) => current.filter((sessionId) => !removedIdSet.has(sessionId)));
    setDetail((current) =>
      current && removedIdSet.has(current.record.id) ? null : current,
    );
    setFocusedSessionId((current) =>
      current && removedIdSet.has(current) ? null : current,
    );
  }

  async function refreshListedSessionsForCurrentFilters() {
    const latest = latestListStateRef.current;
    const filters = buildFilters(latest.search, latest.status);

    if (!filters.query && latest.status === DEFAULT_STATUS) {
      listRequestSequenceRef.current += 1;
      setListedSessions(
        filterVisibleSessions(latest.indexedSessions, latest.search, latest.status),
      );
      setLoadingSessions(false);
      return;
    }

    await loadListedSessions(filters);
  }

  async function refreshFocusedDetail() {
    if (!focusedSessionId) {
      return;
    }

    const requestId = ++detailRequestSequenceRef.current;
    setLoadingDetail(true);
    await loadDetail(focusedSessionId, requestId);
  }

  function clearActionFeedback() {
    setError(null);
    setRestoreTargetError(null);
    setFeedback(null);
    setBatchFailures([]);
  }

  function selectSession(sessionId: string) {
    setFocusedSessionId(sessionId);

    if (isNarrowViewport) {
      setShowMobileList(false);
    }
  }

  function showSessionList() {
    if (isNarrowViewport) {
      setShowMobileList(true);
    }
  }

  function confirmAction(message: string) {
    try {
      return window.confirm(message);
    } catch (confirmError) {
      setError(readError(confirmError, copy));
      return false;
    }
  }
}
