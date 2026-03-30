import { existsSync } from "node:fs";
import path from "node:path";

import express from "express";

export function mountClientAssets(app: express.Express, clientDistPath: string) {
  if (!existsSync(clientDistPath)) {
    return;
  }

  app.use(express.static(clientDistPath));
  app.get("/{*path}", (_request, response) => {
    response.sendFile(path.join(clientDistPath, "index.html"));
  });
}
