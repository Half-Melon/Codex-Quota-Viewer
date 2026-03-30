import path from "node:path";

import { createApp } from "./app";
import { resolveClientDistPath } from "./runtime-paths";
import { mountClientAssets } from "./static-client";

const port = Number(process.env.PORT ?? 4318);
const codexHome = process.env.CODEX_HOME ?? path.join(process.env.HOME ?? "", ".codex");
const managerHome =
  process.env.CODEX_MANAGER_HOME ??
  path.join(process.env.HOME ?? "", ".codex-session-manager");
const clientDistPath = resolveClientDistPath();

const app = createApp({ codexHome, managerHome });
mountClientAssets(app, clientDistPath);

app.listen(port, () => {
  console.log(`Codex Session Manager listening on http://127.0.0.1:${port}`);
});
