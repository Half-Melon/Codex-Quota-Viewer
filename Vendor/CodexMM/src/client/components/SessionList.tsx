import { useEffect, useRef, useState } from "react";

import type { SessionRecord, SessionStatus } from "../../shared/contracts";
import { useI18n } from "../i18n";
import {
  formatSessionListTime,
  getSessionTitle,
  normalizeExcerpt,
  parseTimestamp,
  readProjectName,
} from "../session-display";

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
  onSelect: (sessionId: string) => void;
  onToggleChecked: (sessionId: string, checked: boolean) => void;
  onToggleProject: (cwd: string, checked: boolean) => void;
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
  onSelect,
  onToggleChecked,
  onToggleProject,
}: SessionListProps) {
  const { copy, language } = useI18n();
  const [collapsedProjects, setCollapsedProjects] = useState<Record<string, boolean>>({});
  const projectGroups = buildProjectGroups(sessions, copy.project.unnamedDirectory);
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
            disabled={repairingOfficial || loading}
          >
            {repairingOfficial ? copy.sidebar.repairingOfficial : copy.sidebar.repairOfficial}
          </button>
          <button
            type="button"
            className="sidebar-command"
            onClick={onRescan}
            disabled={loading || repairingOfficial}
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

      <div className="project-groups" data-testid="session-sidebar-scroll">
        {projectGroups.map((group) => {
          const isCollapsed = collapsedProjects[group.cwd] ?? true;
          const checkedCount = group.sessions.filter((session) => selectedIds.includes(session.id)).length;
          const isChecked = checkedCount > 0 && checkedCount === group.sessions.length;
          const isIndeterminate = checkedCount > 0 && checkedCount < group.sessions.length;

          return (
            <section
              key={group.cwd}
              className="project-group"
              data-testid={`project-group-${group.cwd}`}
            >
              <div className={`project-group__header ${isCollapsed ? "" : "project-group__header--open"}`}>
                <label className="project-group__checkbox">
                  <ProjectCheckbox
                    ariaLabel={copy.sidebar.selectProject(group.cwd)}
                    checked={isChecked}
                    indeterminate={isIndeterminate}
                    onChange={(checked) => onToggleProject(group.cwd, checked)}
                  />
                </label>
                <button
                  type="button"
                  className="project-group__toggle"
                  aria-label={copy.sidebar.toggleProject(group.cwd)}
                  aria-expanded={!isCollapsed}
                  onClick={() =>
                    setCollapsedProjects((current) => ({
                      ...current,
                      [group.cwd]: !isCollapsed,
                    }))
                  }
                >
                  <span className="project-group__chevron">{isCollapsed ? "▸" : "▾"}</span>
                  <span className="project-group__label">
                    <strong>{group.name}</strong>
                    <span>{group.cwd}</span>
                  </span>
                  <span className="project-group__count">{group.sessions.length}</span>
                </button>
              </div>

              {isCollapsed ? null : (
                <div className="project-group__sessions">
                  {group.sessions.map((session) => {
                    const checked = selectedIds.includes(session.id);
                    const sessionTitle = getSessionTitle(session) ?? copy.sidebar.unnamedSession;
                    const sessionPreview = getSessionPreview(session);

                    return (
                      <div
                        key={session.id}
                        className={`session-row ${selectedId === session.id ? "session-row--selected" : ""}`}
                      >
                        <label className="session-row__checkbox">
                          <input
                            type="checkbox"
                            aria-label={copy.sidebar.selectSession(sessionTitle)}
                            checked={checked}
                            onChange={(event) =>
                              onToggleChecked(session.id, event.target.checked)
                            }
                            onClick={(event) => event.stopPropagation()}
                          />
                        </label>
                        <button
                          type="button"
                          className="session-row__button"
                          onClick={() => onSelect(session.id)}
                        >
                          <div className="session-row__headline">
                            <strong>{sessionTitle}</strong>
                            <span>{formatSessionListTime(session.startedAt, language)}</span>
                          </div>
                          {sessionPreview ? (
                            <div className="session-row__preview">
                              <span>{sessionPreview}</span>
                            </div>
                          ) : null}
                        </button>
                      </div>
                    );
                  })}
                </div>
              )}
            </section>
          );
        })}

        {loading && projectGroups.length === 0 ? (
          <div className="empty-state">{copy.sidebar.scanningOrFiltering}</div>
        ) : null}

        {!loading && projectGroups.length === 0 ? (
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

type ProjectGroup = {
  cwd: string;
  name: string;
  latestStartedAt: number;
  sessions: SessionRecord[];
};

function buildProjectGroups(sessions: SessionRecord[], fallbackName: string) {
  const groups = new Map<string, ProjectGroup>();

  for (const session of sessions) {
    const existing = groups.get(session.cwd);

    if (existing) {
      existing.sessions.push(session);
      existing.latestStartedAt = Math.max(existing.latestStartedAt, parseTimestamp(session.startedAt));
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
