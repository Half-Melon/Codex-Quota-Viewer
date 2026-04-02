import type {
  BatchSessionActionFailure,
  RestoreMode,
  SessionDetail as SessionDetailModel,
  SessionStatus,
  SessionTimelineItem,
} from "../../shared/contracts";
import { useI18n } from "../i18n";
import {
  describeOfficialState,
  localizeAuditAction,
  localizeKnownMessage,
} from "../session-browser-helpers";
import {
  formatSessionDate,
  formatTimelineTime,
  getSessionTitle,
} from "../session-display";

type SessionDetailProps = {
  detail: SessionDetailModel | null;
  loadingDetail: boolean;
  loadingTimeline: boolean;
  targetCwd: string;
  restoreMode: RestoreMode;
  restoreTargetError: string | null;
  feedback: string | null;
  batchFailures: BatchSessionActionFailure[];
  resumeCommand: string | null;
  busyAction: string | null;
  checkedCount: number;
  showEmptyTrashAction: boolean;
  visibleSessionCount: number;
  canArchiveSelection: boolean;
  canTrashSelection: boolean;
  canRestoreSelection: boolean;
  canRestoreCurrent: boolean;
  canArchiveCurrent: boolean;
  showBackToList: boolean;
  onBackToList: () => void;
  onTargetCwdChange: (value: string) => void;
  onRestoreModeChange: (value: RestoreMode) => void;
  onSelectAllVisible: () => void;
  onClearSelection: () => void;
  onArchiveSelected: () => void;
  onTrashSelected: () => void;
  onRestoreSelected: () => void;
  onEmptyTrash: () => void;
  onRestoreCurrentToDirectory: () => void;
  onArchiveCurrent: () => void;
  onRepairCurrentOfficial: () => void;
  onCopyCommand: () => void;
  onLoadMoreTimeline: () => void;
};

export function SessionDetail({
  detail,
  loadingDetail,
  loadingTimeline,
  targetCwd,
  restoreMode,
  restoreTargetError,
  feedback,
  batchFailures,
  resumeCommand,
  busyAction,
  checkedCount,
  showEmptyTrashAction,
  visibleSessionCount,
  canArchiveSelection,
  canTrashSelection,
  canRestoreSelection,
  canRestoreCurrent,
  canArchiveCurrent,
  showBackToList,
  onBackToList,
  onTargetCwdChange,
  onRestoreModeChange,
  onSelectAllVisible,
  onClearSelection,
  onArchiveSelected,
  onTrashSelected,
  onRestoreSelected,
  onEmptyTrash,
  onRestoreCurrentToDirectory,
  onArchiveCurrent,
  onRepairCurrentOfficial,
  onCopyCommand,
  onLoadMoreTimeline,
}: SessionDetailProps) {
  const { copy, language } = useI18n();
  const hasSelection = checkedCount > 0;
  const sessionTitle = detail ? (getSessionTitle(detail.record) ?? detail.record.id) : null;
  const officialStateCopy = detail ? describeOfficialState(detail.officialState, copy) : null;
  const selectionSummary = busyAction
    ? copy.detail.selectionSummaryBusy
    : hasSelection
      ? copy.detail.selectionSummaryCount(checkedCount)
      : copy.detail.selectionSummaryNone;
  const remainingTimelineCount = detail
    ? Math.max(detail.timelineTotal - detail.timeline.length, 0)
    : 0;

  return (
    <section className="reader-shell">
      <header className="reader-toolbar">
        <div className="reader-toolbar__group reader-toolbar__group--utility">
          {showBackToList ? (
            <button
              type="button"
              className="compact-button compact-button--ghost"
              onClick={onBackToList}
            >
              {copy.detail.backToList}
            </button>
          ) : null}
          <button
            type="button"
            className="compact-button compact-button--ghost"
            onClick={onSelectAllVisible}
            disabled={visibleSessionCount === 0 || !!busyAction}
          >
            {copy.detail.selectAll}
          </button>
          <button
            type="button"
            className="compact-button compact-button--ghost"
            onClick={onClearSelection}
            disabled={checkedCount === 0 || !!busyAction}
          >
            {copy.detail.clear}
          </button>
          {showEmptyTrashAction ? (
            <button
              type="button"
              className="compact-button compact-button--ghost compact-button--warn"
              disabled={!!busyAction}
              onClick={onEmptyTrash}
            >
              {copy.detail.emptyTrash}
            </button>
          ) : null}
        </div>
        {hasSelection ? (
          <div className="reader-selection-bar" aria-live="polite">
            <span className="reader-selection-bar__summary">{selectionSummary}</span>
            <div className="reader-selection-bar__actions">
              <button
                type="button"
                className="compact-button"
                disabled={!canArchiveSelection || !!busyAction}
                onClick={onArchiveSelected}
              >
                {copy.detail.archive}
              </button>
              <button
                type="button"
                className="compact-button compact-button--warn"
                disabled={!canTrashSelection || !!busyAction}
                onClick={onTrashSelected}
              >
                {copy.detail.moveToTrash}
              </button>
              <button
                type="button"
                className="compact-button"
                disabled={!canRestoreSelection || !!busyAction}
                onClick={onRestoreSelected}
              >
                {copy.detail.restore}
              </button>
            </div>
          </div>
        ) : (
          <span className="reader-toolbar__summary">{selectionSummary}</span>
        )}
      </header>

      <div className="reader-content" data-testid="reader-content">
        {feedback ? (
          <div className="reader-inline-notice app-banner app-banner--success" aria-live="polite">
            {feedback}
          </div>
        ) : null}

        {batchFailures.length > 0 ? (
          <section className="failure-panel" aria-live="polite">
            <strong>{copy.detail.failuresHeading}</strong>
            <ul className="failure-list">
              {batchFailures.map((failure) => (
                <li key={failure.sessionId}>
                  {failure.sessionId}: {localizeKnownMessage(
                    failure.error,
                    copy,
                    failure.code,
                    failure.details,
                  )}
                </li>
              ))}
            </ul>
          </section>
        ) : null}

        {!detail ? (
          <section className="reader-empty">
            <div className="empty-state">
              {loadingDetail ? copy.detail.loadingSessionDetail : copy.detail.emptyDetail}
            </div>
          </section>
        ) : (
          <>
            <section className="reader-summary">
              <div className="reader-summary__main">
                <div className="reader-summary__title">
                  <h2>{sessionTitle}</h2>
                  <span className={`status-chip status-chip--${detail.record.status}`}>
                    {copy.statuses[detail.record.status]}
                  </span>
                </div>
                <div className="reader-summary__session-id">{detail.record.id}</div>
                <div className="reader-summary__path">{detail.record.cwd}</div>
                {detail.record.status === "restorable" ? (
                  <div className="reader-summary__note">{copy.detail.backupOnlyNote}</div>
                ) : null}
                <div className="reader-summary__meta">
                  <span>{formatSessionDate(detail.record.startedAt, language)}</span>
                  <span>{detail.record.originator}</span>
                  <span>{detail.record.source}</span>
                  <span>{detail.record.modelProvider}</span>
                  <span>{copy.detail.lineCount(detail.record.lineCount)}</span>
                  <span>{copy.detail.eventCount(detail.record.eventCount)}</span>
                  <span>{copy.detail.toolCallCount(detail.record.toolCallCount)}</span>
                </div>
              </div>

              <div className="reader-summary__excerpt-grid">
                <article className="summary-card">
                  <span>{copy.detail.userSummary}</span>
                  <p>{detail.record.userPromptExcerpt || copy.detail.emptySummary}</p>
                </article>
                <article className="summary-card">
                  <span>{copy.detail.assistantSummary}</span>
                  <p>{detail.record.latestAgentMessageExcerpt || copy.detail.emptySummary}</p>
                </article>
              </div>

              <div className="reader-actions">
                <label className="reader-actions__field">
                  <span>{copy.detail.targetProjectDirectory}</span>
                  <input
                    aria-label={copy.detail.targetProjectDirectory}
                    className={`weui-input detail-input ${restoreTargetError ? "detail-input--error" : ""}`}
                    value={targetCwd}
                    onChange={(event) => onTargetCwdChange(event.target.value)}
                    placeholder={copy.detail.targetProjectDirectoryPlaceholder}
                  />
                  {restoreTargetError ? (
                    <span className="field-error" role="status">
                      {restoreTargetError}
                    </span>
                  ) : null}
                </label>
                <fieldset className="reader-actions__mode" aria-label={copy.detail.restoreMode}>
                  <legend>{copy.detail.restoreMode}</legend>
                  <label className="reader-actions__mode-option">
                    <input
                      type="radio"
                      name="restore-mode"
                      checked={restoreMode === "resume_only"}
                      onChange={() => onRestoreModeChange("resume_only")}
                    />
                    <span>{copy.detail.resumeOnly}</span>
                  </label>
                  <label className="reader-actions__mode-option">
                    <input
                      type="radio"
                      name="restore-mode"
                      checked={restoreMode === "rebind_cwd"}
                      onChange={() => onRestoreModeChange("rebind_cwd")}
                    />
                    <span>{copy.detail.rebindCwd}</span>
                  </label>
                </fieldset>
                <div className="reader-actions__buttons">
                  <button
                    type="button"
                    className="compact-button"
                    onClick={onRestoreCurrentToDirectory}
                    disabled={!canRestoreCurrent || !!busyAction}
                  >
                    {restoreMode === "rebind_cwd"
                      ? copy.detail.restoreAndRebind
                      : copy.detail.restoreToDirectory}
                  </button>
                  <button
                    type="button"
                    className="compact-button"
                    onClick={onArchiveCurrent}
                    disabled={!canArchiveCurrent || !!busyAction}
                  >
                    {copy.detail.archiveCurrent}
                  </button>
                  <button
                    type="button"
                    className="compact-button compact-button--ghost"
                    onClick={onRepairCurrentOfficial}
                    disabled={!!busyAction}
                  >
                    {copy.detail.repairCurrentThread}
                  </button>
                </div>
              </div>

              <section
                className={`official-sync-panel official-sync-panel--${detail.officialState.status}`}
                aria-live="polite"
              >
                <div className="official-sync-panel__header">
                  <strong>{copy.detail.officialSync}</strong>
                  <span>{labelForOfficialState(detail.officialState.status, copy)}</span>
                </div>
                <p>{officialStateCopy?.summary}</p>
                {officialStateCopy && officialStateCopy.issues.length > 0 ? (
                  <ul className="official-sync-panel__issues">
                    {officialStateCopy.issues.map((issue) => (
                      <li key={issue}>{issue}</li>
                    ))}
                  </ul>
                ) : null}
              </section>

              {resumeCommand ? (
                <div className="resume-box">
                  <code>{resumeCommand}</code>
                  <button type="button" className="compact-button" onClick={onCopyCommand}>
                    {copy.detail.copyCommand}
                  </button>
                </div>
              ) : null}

              {detail.auditEntries.length > 0 ? (
                <div className="audit-inline">
                  {detail.auditEntries.slice(0, 3).map((entry) => (
                    <span key={entry.id}>
                      {localizeAuditAction(entry.action, copy)} · {formatSessionDate(entry.createdAt, language)}
                    </span>
                  ))}
                </div>
              ) : null}
            </section>

            <section className="thread-panel">
              {detail.timeline.length === 0 ? (
                <div className="empty-state">{copy.detail.emptyTimeline}</div>
              ) : (
                detail.timeline.map((item) => <TimelineEntry key={item.id} item={item} />)
              )}

              {detail.timelineTotal > 0 ? (
                <div className="thread-panel__meta">
                  {copy.detail.loadedTimeline(detail.timeline.length, detail.timelineTotal)}
                </div>
              ) : null}

              {remainingTimelineCount > 0 ? (
                <button
                  type="button"
                  className="compact-button thread-panel__more"
                  onClick={onLoadMoreTimeline}
                  disabled={loadingTimeline}
                >
                  {loadingTimeline
                    ? copy.detail.loadingMore
                    : copy.detail.loadMore(remainingTimelineCount)}
                </button>
              ) : null}
            </section>
          </>
        )}
      </div>
    </section>
  );
}

function TimelineEntry({ item }: { item: SessionTimelineItem }) {
  const { copy, language } = useI18n();

  if (item.type === "tool_call") {
    return (
      <details className="thread-entry thread-entry--tool">
        <summary>
          <span className="thread-entry__pill">{copy.detail.toolLabel}</span>
          <strong>{item.toolName}</strong>
          <span>{item.summary}</span>
          <time>{formatTimelineTime(item.timestamp, language)}</time>
        </summary>
        <div className="thread-entry__tool-body">
          <div>
            <span>{copy.detail.input}</span>
            <pre>{item.input || copy.detail.noInput}</pre>
          </div>
          <div>
            <span>{copy.detail.output}</span>
            <pre>{item.output || copy.detail.waitingOutput}</pre>
          </div>
        </div>
      </details>
    );
  }

  return (
    <article
      className={`thread-entry ${item.type === "message:user" ? "thread-entry--user" : "thread-entry--assistant"}`}
    >
      <header className="thread-entry__header">
        <span className="thread-entry__pill">
          {item.type === "message:user" ? copy.detail.userLabel : copy.detail.assistantLabel}
        </span>
        <time>{formatTimelineTime(item.timestamp, language)}</time>
      </header>
      <p>{item.text}</p>
    </article>
  );
}

function labelForOfficialState(
  status: SessionDetailModel["officialState"]["status"],
  copy: ReturnType<typeof useI18n>["copy"],
) {
  switch (status) {
    case "synced":
      return copy.officialStates.synced;
    case "repair_needed":
      return copy.officialStates.repair_needed;
    case "hidden":
      return copy.officialStates.hidden;
    default:
      return copy.officialStates.unknown;
  }
}

export function labelForStatus(
  status: SessionStatus,
  copy: ReturnType<typeof useI18n>["copy"],
) {
  return copy.statuses[status];
}
