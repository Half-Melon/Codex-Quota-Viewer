import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

import express from "express";

import type { UiConfigResponse } from "../shared/contracts";

export function mountClientAssets(
  app: express.Express,
  clientDistPath: string,
  readUiConfig: () => UiConfigResponse = () => ({ language: "en" }),
) {
  if (!existsSync(clientDistPath)) {
    return;
  }

  const renderIndex = (_request: express.Request, response: express.Response) => {
    const indexPath = path.join(clientDistPath, "index.html");
    const uiConfig = readUiConfig();
    const uiConfigScript = `<script>window.__CODEX_VIEWER_UI_CONFIG__=${JSON.stringify(uiConfig)};</script>`;
    const html = readFileSync(indexPath, "utf8");
    const localizedHtml = html
      .replace(/<html lang="[^"]*">/, `<html lang="${uiConfig.language === "zh" ? "zh-CN" : "en-US"}">`)
      .replace("</head>", `${uiConfigScript}</head>`);
    response.type("html").send(localizedHtml);
  };

  app.use(express.static(clientDistPath, { index: false }));
  app.get("/", renderIndex);
  app.get("/{*path}", renderIndex);
}
