import type {
  ApiErrorCode,
  ApiErrorResponse,
  BatchSessionActionResponse,
  OfficialRepairResponse,
  RestoreRequest,
  SessionDetail,
  SessionFilters,
  SessionRecord,
  SessionTimelinePage,
  UiConfigResponse,
} from "../shared/contracts";

export class ApiRequestError extends Error {
  readonly code?: ApiErrorCode;

  constructor(message: string, code?: ApiErrorCode) {
    super(message);
    this.name = "ApiRequestError";
    this.code = code;
  }
}

export async function rescanSessions() {
  const response = await fetch("/api/sessions/rescan", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });

  return parseJson<{ sessions: SessionRecord[] }>(response);
}

export async function fetchSessionDetail(id: string) {
  const response = await fetch(`/api/sessions/${id}`);
  return parseJson<SessionDetail>(response);
}

export async function fetchSessionTimelinePage(
  id: string,
  options: {
    offset: number;
    limit?: number;
  },
) {
  const query = new URLSearchParams({
    offset: String(options.offset),
  });

  if (typeof options.limit === "number") {
    query.set("limit", String(options.limit));
  }

  const response = await fetch(`/api/sessions/${id}/timeline?${query.toString()}`);
  return parseJson<SessionTimelinePage>(response);
}

export async function archiveSession(id: string) {
  const response = await fetch(`/api/sessions/${id}/archive`, { method: "POST" });
  return parseJson<SessionRecord>(response);
}

export async function batchArchiveSessions(sessionIds: string[]) {
  return postBatch("/api/sessions/batch/archive", sessionIds);
}

export async function batchTrashSessions(sessionIds: string[]) {
  return postBatch("/api/sessions/batch/trash", sessionIds);
}

export async function batchRestoreSessions(sessionIds: string[]) {
  return postBatch("/api/sessions/batch/restore", sessionIds);
}

export async function batchPurgeSessions(sessionIds: string[]) {
  return postBatch("/api/sessions/batch/purge", sessionIds);
}

export async function restoreSession(id: string, request: Omit<RestoreRequest, "sessionId">) {
  const response = await fetch(`/api/sessions/${id}/restore`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });

  return parseJson<{
    record: SessionRecord;
    resumeCommand: string;
    launched: boolean;
  }>(response);
}

export async function listSessions(filters: SessionFilters = {}) {
  const query = new URLSearchParams();

  if (filters.query) {
    query.set("query", filters.query);
  }

  if (filters.status) {
    query.set("status", filters.status);
  }

  if (filters.cwd) {
    query.set("cwd", filters.cwd);
  }

  const suffix = query.size > 0 ? `?${query.toString()}` : "";
  const response = await fetch(`/api/sessions${suffix}`);
  return parseJson<{ sessions: SessionRecord[] }>(response);
}

export async function repairOfficialThreads(sessionIds: string[] = []) {
  const response = await fetch("/api/codex/repair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sessionIds }),
  });

  return parseJson<OfficialRepairResponse>(response);
}

export async function fetchUiConfig() {
  const response = await fetch("/api/ui-config");
  return parseJson<UiConfigResponse>(response);
}

async function parseJson<T>(response: Response): Promise<T> {
  if (!response.ok) {
    try {
      const payload = (await response.json()) as Partial<ApiErrorResponse>;

      if (typeof payload?.error === "string" && payload.error.length > 0) {
        throw new ApiRequestError(
          payload.error,
          typeof payload.code === "string" ? payload.code : undefined,
        );
      }
    } catch (error) {
      if (error instanceof Error && error.message.length > 0) {
        throw error;
      }
    }

    const fallback = await response.text();
    throw new ApiRequestError(fallback || "Request failed");
  }

  return (await response.json()) as T;
}

async function postBatch(path: string, sessionIds: string[]) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sessionIds }),
  });

  return parseJson<BatchSessionActionResponse>(response);
}
