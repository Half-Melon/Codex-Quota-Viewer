import path from "node:path";

import { resolveClientDistPath } from "./runtime-paths";
import { startServer } from "./server";

const port = Number(process.env.PORT ?? 4318);
const codexHome = process.env.CODEX_HOME ?? path.join(process.env.HOME ?? "", ".codex");
const managerHome =
  process.env.CODEX_MANAGER_HOME ??
  path.join(process.env.HOME ?? "", ".codex-session-manager");
const clientDistPath = resolveClientDistPath();

void startServer({
  port,
  codexHome,
  managerHome,
  clientDistPath,
}).then(() => {
  console.log(`Codex Session Manager listening on http://127.0.0.1:${port}`);
});
