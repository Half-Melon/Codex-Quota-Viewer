import path from "node:path";

import { AppError } from "./errors";

export function ensureInsidePath(root: string, candidate: string): string {
  const resolvedRoot = path.resolve(root);
  const resolvedCandidate = path.resolve(candidate);

  if (
    resolvedCandidate !== resolvedRoot &&
    !resolvedCandidate.startsWith(`${resolvedRoot}${path.sep}`)
  ) {
    throw new AppError(400, `Path is outside managed root: ${candidate}`);
  }

  return resolvedCandidate;
}

export function buildSessionRoots(codexHome: string, managerHome: string) {
  return {
    sessionsRoot: path.join(codexHome, "sessions"),
    archiveRoot: path.join(codexHome, "archived_sessions"),
    snapshotRoot: path.join(managerHome, "snapshots"),
    databasePath: path.join(managerHome, "index.db"),
  };
}

export function sessionArchivePath(archiveRoot: string, relativePath: string) {
  return path.join(archiveRoot, relativePath);
}

export function sessionSnapshotPath(snapshotRoot: string, sessionId: string) {
  return path.join(snapshotRoot, `${sessionId}.jsonl`);
}

export function shellQuote(value: string): string {
  if (/^[\w./:@-]+$/.test(value)) {
    return value;
  }

  return `'${value.replaceAll("'", `'\\''`)}'`;
}
