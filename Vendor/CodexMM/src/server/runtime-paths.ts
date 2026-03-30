import path from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_CLIENT_DIST_PATH = path.join("dist", "client");

export function resolveClientDistPath(
  env: NodeJS.ProcessEnv = process.env,
  runtimeModuleUrl: string = import.meta.url,
  cwd: string = process.cwd(),
) {
  const explicitPath = env.CODEX_SESSION_MANAGER_CLIENT_DIST?.trim();
  if (explicitPath) {
    return path.resolve(explicitPath);
  }

  const runtimeFilePath = fileURLToPath(runtimeModuleUrl);
  const runtimeDirectory = path.dirname(runtimeFilePath);
  const runtimeParent = path.basename(path.dirname(runtimeDirectory));

  if (path.basename(runtimeDirectory) === "server" && runtimeParent === "dist") {
    return path.resolve(runtimeDirectory, "..", "client");
  }

  return path.resolve(cwd, DEFAULT_CLIENT_DIST_PATH);
}
