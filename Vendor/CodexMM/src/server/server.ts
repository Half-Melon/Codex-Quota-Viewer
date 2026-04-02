import type http from "node:http";

import { createApp, createUiConfigReader } from "./app";
import { mountClientAssets } from "./static-client";

type StartServerConfig = {
  port: number;
  codexHome: string;
  managerHome: string;
  clientDistPath: string;
};

export async function startServer(
  config: StartServerConfig,
): Promise<http.Server> {
  const readUiConfig = createUiConfigReader();
  const app = createApp({
    codexHome: config.codexHome,
    managerHome: config.managerHome,
    readUiConfig,
  });
  mountClientAssets(app, config.clientDistPath, readUiConfig);

  return new Promise((resolve, reject) => {
    const server = app.listen(config.port, "127.0.0.1", () => {
      resolve(server);
    });
    server.once("error", reject);
  });
}
