import { useEffect, useMemo, useRef, useState } from "react";

import type { SessionRecord, SessionStatus } from "../../shared/contracts";
import { useI18n } from "../i18n";
import {
  formatSessionListTime,
  getSessionTitle,
  normalizeExcerpt,
  parseTimestamp,
  readProjectName,
} from "../session-display";

const PROJECT_ROW_HEIGHT = 88;
const SESSION_ROW_HEIGHT = 86;
const VIRTUAL_OVERSCAN_PX = 480;
const FALLBACK_VIEWPORT_HEIGHT = 640;

type SessionListProps = {
  sessions: SessionRecord[];
  indexedCount: number;
  loading: boolean;
  search: string;
  status: SessionStatus;
  selectedId: string | null;
  selectedIds: string[];
  onSearchChange: (value: string) => void;
  onStatusChange: (value: SessionStatus) => void;
  onRescan: () => void;
  onRepairOfficial: () => void;
  repairingOfficial: boolean;
  busy: boolean;
  onSelect: (sessionId: string) => void;
  onToggleChecked: (sessionId: string, checked: boolean) => void;
  onToggleProject: (cwd: string, checked: boolean) => void;
};

type ProjectGroup = {
  cwd: string;
  name: string;
  latestStartedAt: number;
  sessions: SessionRecord[];
};

type ProjectRow = {
  type: "project";
  key: string;
  top: number;
  height: number;
  group: ProjectGroup;
  isCollapsed: boolean;
  isChecked: boolean;
  isIndeterminate: boolean;
};

type SessionRow = {
  type: "session";
  key: string;
  top: number;
  height: number;
  group: ProjectGroup;
  session: SessionRecord;
  checked: boolean;
  preview: string | null;
  title: string;
};

export function SessionList({
  sessions,
  indexedCount,
  loading,
  search,
  status,
  selectedId,
  selectedIds,
  onSearchChange,
  onStatusChange,
  onRescan,
  onRepairOfficial,
  repairingOfficial,
  busy,
  onSelect,
  onToggleChecked,
  onToggleProject,
}: SessionListProps) {
  const { copy, language } = useI18n();
  const [collapsedProjects, setCollapsedProjects] = useState<Record<string, boolean>>({});
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportHeight, setViewportHeight] = useState(FALLBACK_VIEWPORT_HEIGHT);
  const scrollRef = useRef<HTMLDivElement>(null);
  const projectGroups = useMemo(
    () => buildProjectGroups(sessions, copy.project.unnamedDirectory),
    [copy.project.unnamedDirectory, sessions],
  );
  const selectedIdSet = useMemo(() => new Set(selectedIds), [selectedIds]);
  const statusFilters: Array<{ value: SessionStatus; label: string }> = [
    { value: "active", label: copy.statuses.active },
    { value: "archived", label: copy.statuses.archived },
    { value: "deleted_pending_purge", label: copy.statuses.deleted_pending_purge },
  ];

  useEffect(() => {
    setCollapsedProjects((current) => {
      const next = Object.fromEntries(
        projectGroups.map((group) => [group.cwd, current[group.cwd] ?? true]),
      );

      return shallowEqual(current, next) ? current : next;
    });
  }, [projectGroups]);

  useEffect(() => {
    const scrollElement = scrollRef.current;

    if (!scrollElement) {
      return;
    }

    const updateViewport = () => {
      setViewportHeight(scrollElement.clientHeight || FALLBACK_VIEWPORT_HEIGHT);
    };

    updateViewport();

    if (typeof ResizeObserver !== "function") {
      window.addEventListener("resize", updateViewport);
      return () => {
        window.removeEventListener("resize", updateViewport);
      };
    }

    const observer = new ResizeObserver(updateViewport);
    observer.observe(scrollElement);
    return () => {
      observer.disconnect();
    };
  }, []);

  const virtualModel = useMemo(() => {
    let top = 0;
    const rows: Array<ProjectRow | SessionRow> = [];

    for (const group of projectGroups) {
      const checkedCount = group.sessions.filter((session) =>
        selectedIdSet.has(session.id),
      ).length;
      const isCollapsed = collapsedProjects[group.cwd] ?? true;

      rows.push({
        type: "project",
        key: group.cwd,
        top,
        height: PROJECT_ROW_HEIGHT,
        group,
        isCollapsed,
        isChecked: checkedCount > 0 && checkedCount === group.sessions.length,
        isIndeterminate: checkedCount > 0 && checkedCount < group.sessions.length,
      });
      top += PROJECT_ROW_HEIGHT;

      if (isCollapsed) {
        continue;
      }

      for (const session of group.sessions) {
        rows.push({
          type: "session",
          key: session.id,
          top,
          height: SESSION_ROW_HEIGHT,
          group,
          session,
          checked: selectedIdSet.has(session.id),
          preview: getSessionPreview(session),
          title: getSessionTitle(session) ?? copy.sidebar.unnamedSession,
        });
        top += SESSION_ROW_HEIGHT;
      }
    }

    return {
      totalHeight: top,
      rows,
    };
  }, [collapsedProjects, copy.sidebar.unnamedSession, projectGroups, selectedIdSet]);

  const visibleRows = useMemo(
    () =>
      virtualModel.rows.filter(
        (row) =>
          row.top + row.height >= scrollTop - VIRTUAL_OVERSCAN_PX &&
          row.top <= scrollTop + viewportHeight + VIRTUAL_OVERSCAN_PX,
      ),
    [scrollTop, viewportHeight, virtualModel.rows],
  );

  return (
    <aside className="session-sidebar" data-testid="session-sidebar">
      <header className="sidebar-header">
        <div>
          <span className="sidebar-header__title">{copy.sidebar.title}</span>
          <span className="sidebar-header__meta">{sessions.length} / {indexedCount}</span>
        </div>
        <div className="sidebar-header__actions">
          <button
            type="button"
            className="sidebar-command"
            onClick={onRepairOfficial}
            disabled={repairingOfficial || loading || busy}
          >
            {repairingOfficial ? copy.sidebar.repairingOfficial : copy.sidebar.repairOfficial}
          </button>
          <button
            type="button"
            className="sidebar-command"
            onClick={onRescan}
            disabled={loading || repairingOfficial || busy}
          >
            {loading ? copy.sidebar.refreshing : copy.sidebar.refresh}
          </button>
        </div>
      </header>

      <div className="sidebar-filters">
        <input
          aria-label={copy.sidebar.searchLabel}
          className="weui-input sidebar-input"
          placeholder={copy.sidebar.searchPlaceholder}
          value={search}
          onChange={(event) => onSearchChange(event.target.value)}
        />
        <div
          className="sidebar-filter-switcher"
          role="tablist"
          aria-label={copy.sidebar.statusFilterLabel}
        >
          {statusFilters.map((filter) => {
            const isActive = status === filter.value;

            return (
              <button
                key={filter.value}
                type="button"
                role="tab"
                aria-selected={isActive}
                tabIndex={isActive ? 0 : -1}
                className={`sidebar-filter-tab ${isActive ? "sidebar-filter-tab--active" : ""}`}
                onClick={() => onStatusChange(filter.value)}
              >
                {filter.label}
              </button>
            );
          })}
        </div>
      </div>

      <div
        ref={scrollRef}
        className="project-groups"
        data-testid="session-sidebar-scroll"
        onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}
      >
        {virtualModel.rows.length > 0 ? (
          <div className="project-groups__canvas" style={{ height: `${virtualModel.totalHeight}px` }}>
            {visibleRows.map((row) =>
              row.type === "project" ? (
                <section
                  key={row.key}
                  className={`project-group project-group--virtual ${row.isCollapsed ? "" : "project-group--open"}`}
                  data-testid={`project-group-${row.group.cwd}`}
                  style={{ top: `${row.top}px`, height: `${row.height}px` }}
                >
                  <div className={`project-group__header ${row.isCollapsed ? "" : "project-group__header--open"}`}>
                    <label className="project-group__checkbox">
                      <ProjectCheckbox
                        ariaLabel={copy.sidebar.selectProject(row.group.cwd)}
                        checked={row.isChecked}
                        indeterminate={row.isIndeterminate}
                        onChange={(checked) => onToggleProject(row.group.cwd, checked)}
                      />
                    </label>
                    <button
                      type="button"
                      className="project-group__toggle"
                      aria-label={copy.sidebar.toggleProject(row.group.cwd)}
                      aria-expanded={!row.isCollapsed}
                      onClick={() =>
                        setCollapsedProjects((current) => ({
                          ...current,
                          [row.group.cwd]: !row.isCollapsed,
                        }))
                      }
                    >
                      <span className="project-group__chevron">{row.isCollapsed ? "▸" : "▾"}</span>
                      <span className="project-group__label">
                        <strong>{row.group.name}</strong>
                        <span>{row.group.cwd}</span>
                      </span>
                      <span className="project-group__count">{row.group.sessions.length}</span>
                    </button>
                  </div>
                </section>
              ) : (
                <div
                  key={row.key}
                  className={`session-row session-row--virtual ${selectedId === row.session.id ? "session-row--selected" : ""}`}
                  data-testid={`session-row-${row.session.id}`}
                  style={{ top: `${row.top}px`, height: `${row.height}px` }}
                >
                  <label className="session-row__checkbox">
                    <input
                      type="checkbox"
                      aria-label={copy.sidebar.selectSession(row.title)}
                      checked={row.checked}
                      onChange={(event) => onToggleChecked(row.session.id, event.target.checked)}
                      onClick={(event) => event.stopPropagation()}
                    />
                  </label>
                  <button
                    type="button"
                    className="session-row__button"
                    onClick={() => onSelect(row.session.id)}
                  >
                    <div className="session-row__headline">
                      <strong>{row.title}</strong>
                      <span>{formatSessionListTime(row.session.startedAt, language)}</span>
                    </div>
                    {row.preview ? (
                      <div className="session-row__preview">
                        <span>{row.preview}</span>
                      </div>
                    ) : null}
                  </button>
                </div>
              ),
            )}
          </div>
        ) : null}

        {loading && virtualModel.rows.length === 0 ? (
          <div className="empty-state">{copy.sidebar.scanningOrFiltering}</div>
        ) : null}

        {!loading && virtualModel.rows.length === 0 ? (
          <div className="empty-state">{copy.sidebar.noMatches}</div>
        ) : null}
      </div>
    </aside>
  );
}

function ProjectCheckbox({
  ariaLabel,
  checked,
  indeterminate,
  onChange,
}: {
  ariaLabel: string;
  checked: boolean;
  indeterminate: boolean;
  onChange: (checked: boolean) => void;
}) {
  const ref = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (ref.current) {
      ref.current.indeterminate = indeterminate;
    }
  }, [indeterminate]);

  return (
    <input
      ref={ref}
      type="checkbox"
      aria-label={ariaLabel}
      checked={checked}
      onChange={(event) => onChange(event.target.checked)}
      onClick={(event) => event.stopPropagation()}
    />
  );
}

function buildProjectGroups(sessions: SessionRecord[], fallbackName: string) {
  const groups = new Map<string, ProjectGroup>();

  for (const session of sessions) {
    const existing = groups.get(session.cwd);

    if (existing) {
      existing.sessions.push(session);
      existing.latestStartedAt = Math.max(
        existing.latestStartedAt,
        parseTimestamp(session.startedAt),
      );
      continue;
    }

    groups.set(session.cwd, {
      cwd: session.cwd,
      name: readProjectName(session.cwd, fallbackName),
      latestStartedAt: parseTimestamp(session.startedAt),
      sessions: [session],
    });
  }

  return [...groups.values()]
    .map((group) => ({
      ...group,
      sessions: [...group.sessions].sort(
        (left, right) => parseTimestamp(right.startedAt) - parseTimestamp(left.startedAt),
      ),
    }))
    .sort((left, right) => right.latestStartedAt - left.latestStartedAt);
}

function getSessionPreview(session: SessionRecord) {
  const userExcerpt = normalizeExcerpt(session.userPromptExcerpt);
  const agentExcerpt = normalizeExcerpt(session.latestAgentMessageExcerpt);

  if (userExcerpt && agentExcerpt && userExcerpt !== agentExcerpt) {
    return agentExcerpt;
  }

  return null;
}

function shallowEqual(
  left: Record<string, boolean>,
  right: Record<string, boolean>,
) {
  const leftKeys = Object.keys(left);
  const rightKeys = Object.keys(right);

  if (leftKeys.length !== rightKeys.length) {
    return false;
  }

  return leftKeys.every((key) => left[key] === right[key]);
}
