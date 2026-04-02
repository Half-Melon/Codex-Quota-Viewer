import path from "node:path";
import { realpath } from "node:fs/promises";

import { AppError } from "./errors";

export function ensureInsidePath(root: string, candidate: string): string {
  const resolvedRoot = path.resolve(root);
  const resolvedCandidate = path.resolve(candidate);

  if (
    resolvedCandidate !== resolvedRoot &&
    !resolvedCandidate.startsWith(`${resolvedRoot}${path.sep}`)
  ) {
    throw new AppError(
      400,
      "path_outside_managed_root",
      `Path is outside managed root: ${candidate}`,
      {
        managedRoot: resolvedRoot,
        candidatePath: candidate,
        resolvedCandidatePath: resolvedCandidate,
      },
    );
  }

  return resolvedCandidate;
}

export async function ensureInsideRealpath(
  root: string,
  candidate: string,
  options: {
    allowMissingTail?: boolean;
  } = {},
): Promise<string> {
  const resolvedRoot = await realpath(path.resolve(root));
  const resolvedCandidate = await resolveCandidateRealpath(
    candidate,
    options.allowMissingTail === true,
  );

  if (
    resolvedCandidate !== resolvedRoot &&
    !resolvedCandidate.startsWith(`${resolvedRoot}${path.sep}`)
  ) {
    throw new AppError(
      400,
      "path_outside_managed_root",
      `Path is outside managed root: ${candidate}`,
      {
        managedRoot: resolvedRoot,
        candidatePath: candidate,
        resolvedCandidatePath: resolvedCandidate,
      },
    );
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

async function resolveCandidateRealpath(candidate: string, allowMissingTail: boolean) {
  const resolvedCandidate = path.resolve(candidate);

  try {
    return await realpath(resolvedCandidate);
  } catch (error) {
    if (!allowMissingTail || !isMissingPathError(error)) {
      throw error;
    }

    const missingSegments: string[] = [];
    let cursor = resolvedCandidate;

    while (true) {
      try {
        const realCursor = await realpath(cursor);
        return path.join(realCursor, ...missingSegments.reverse());
      } catch (nextError) {
        if (!isMissingPathError(nextError)) {
          throw nextError;
        }

        const parent = path.dirname(cursor);
        if (parent === cursor) {
          throw nextError;
        }

        missingSegments.push(path.basename(cursor));
        cursor = parent;
      }
    }
  }
}

function isMissingPathError(error: unknown) {
  return error instanceof Error && "code" in error && (error as Error & { code?: unknown }).code === "ENOENT";
}
