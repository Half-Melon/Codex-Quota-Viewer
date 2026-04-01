import { existsSync, readFileSync } from "node:fs";

import express from "express";

import type {
  BatchSessionActionRequest,
  RestoreRequest,
  SessionFilters,
  UiConfigResponse,
} from "../shared/contracts";
import { AppError } from "./lib/errors";
import { createSessionManager } from "./services/session-manager";

type AppConfig = {
  codexHome: string;
  managerHome: string;
  readUiConfig?: () => UiConfigResponse;
};

export function createApp(config: AppConfig) {
  const app = express();
  const manager = createSessionManager(config);
  const readUiConfig = config.readUiConfig ?? createUiConfigReader();

  app.use(express.json());

  app.get("/api/health", (_request, response) => {
    response.json({ ok: true });
  });

  app.get("/api/ui-config", (_request, response) => {
    response.json(readUiConfig());
  });

  app.get("/api/sessions", async (request, response, next) => {
    try {
      const filters: SessionFilters = {
        query: toOptionalString(request.query.query),
        cwd: toOptionalString(request.query.cwd),
        status: toOptionalString(request.query.status) as SessionFilters["status"],
      };

      response.json({ sessions: await manager.listSessions(filters) });
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/sessions/:id", async (request, response, next) => {
    try {
      response.json(await manager.getSessionDetail(request.params.id));
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/sessions/:id/timeline", async (request, response, next) => {
    try {
      response.json(
        await manager.getSessionTimelinePage(request.params.id, {
          offset: toOptionalNumber(request.query.offset),
          limit: toOptionalNumber(request.query.limit),
        }),
      );
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/sessions/rescan", async (_request, response, next) => {
    try {
      response.json({ sessions: await manager.rescan() });
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/codex/repair", async (request, response, next) => {
    try {
      response.json(
        await manager.repairOfficialThreads(readBatchRequest(request.body).sessionIds),
      );
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/sessions/batch/archive", async (request, response, next) => {
    try {
      response.json(
        await manager.batchArchiveSessions(readBatchRequest(request.body).sessionIds),
      );
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/sessions/batch/trash", async (request, response, next) => {
    try {
      response.json(
        await manager.batchTrashSessions(readBatchRequest(request.body).sessionIds),
      );
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/sessions/batch/restore", async (request, response, next) => {
    try {
      response.json(
        await manager.batchRestoreSessions(readBatchRequest(request.body).sessionIds),
      );
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/sessions/batch/purge", async (request, response, next) => {
    try {
      response.json(
        await manager.batchPurgeSessions(readBatchRequest(request.body).sessionIds),
      );
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/sessions/:id/archive", async (request, response, next) => {
    try {
      response.json(await manager.archiveSession(request.params.id));
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/sessions/:id/restore", async (request, response, next) => {
    try {
      const body = request.body as Omit<RestoreRequest, "sessionId">;
      response.json(
        await manager.restoreSession({
          sessionId: request.params.id,
          restoreMode: body.restoreMode ?? "resume_only",
          targetCwd: body.targetCwd,
          launch: body.launch,
        }),
      );
    } catch (error) {
      next(error);
    }
  });

  app.delete("/api/sessions/:id", async (request, response, next) => {
    try {
      response.json(await manager.deleteSession(request.params.id));
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/sessions/:id/purge", async (request, response, next) => {
    try {
      response.json(await manager.purgeSession(request.params.id));
    } catch (error) {
      next(error);
    }
  });

  app.use((error: unknown, _request: express.Request, response: express.Response, _next: express.NextFunction) => {
    if (error instanceof AppError) {
      response.status(error.statusCode).json({ error: error.message });
      return;
    }

    if (error instanceof Error) {
      response.status(500).json({ error: error.message });
      return;
    }

    response.status(500).json({ error: "Unknown server error" });
  });

  return app;
}

export function createUiConfigReader(): () => UiConfigResponse {
  const uiConfigPath = process.env.CODEX_VIEWER_UI_CONFIG_PATH;

  return () => {
    if (!uiConfigPath || !existsSync(uiConfigPath)) {
      return { language: resolveDefaultLanguage() };
    }

    try {
      const payload = JSON.parse(readFileSync(uiConfigPath, "utf8")) as Partial<UiConfigResponse>;
      if (payload.language === "en" || payload.language === "zh") {
        return { language: payload.language };
      }
    } catch {
      return { language: resolveDefaultLanguage() };
    }

    return { language: resolveDefaultLanguage() };
  };
}

function resolveDefaultLanguage(): UiConfigResponse["language"] {
  const bundledDefault = process.env.CODEX_VIEWER_DEFAULT_LANGUAGE;
  if (bundledDefault === "en" || bundledDefault === "zh") {
    return bundledDefault;
  }

  const rawLocale = process.env.LC_ALL ?? process.env.LANG ?? "";
  return rawLocale.toLowerCase().startsWith("zh") ? "zh" : "en";
}

function toOptionalString(value: unknown) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function toOptionalNumber(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }

  if (typeof value === "string" && value.length > 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }

  return undefined;
}

function readBatchRequest(body: unknown): BatchSessionActionRequest {
  const sessionIds = Array.isArray((body as BatchSessionActionRequest | undefined)?.sessionIds)
    ? ((body as BatchSessionActionRequest).sessionIds.filter(
        (value): value is string => typeof value === "string" && value.length > 0,
      ) as string[])
    : [];

  return { sessionIds };
}
