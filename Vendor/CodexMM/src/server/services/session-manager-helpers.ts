import { access, copyFile, readdir } from "node:fs/promises";
import path from "node:path";

import type { SessionRecord } from "../../shared/contracts";
import { shellQuote } from "../lib/paths";
import { parseSessionFile } from "./jsonl-session-parser";

const SESSION_SCAN_CONCURRENCY = 16;

export async function collectSessions(root: string) {
  const files = await walkJsonlFiles(root);
  const entries: Array<{
    filePath: string;
    summary: Awaited<ReturnType<typeof parseSessionFile>>;
  }> = [];
  let nextIndex = 0;

  await Promise.all(
    Array.from({ length: Math.min(SESSION_SCAN_CONCURRENCY, files.length) }, async () => {
      while (nextIndex < files.length) {
        const fileIndex = nextIndex;
        nextIndex += 1;

        const filePath = files[fileIndex];
        if (!filePath) {
          continue;
        }

        entries.push({
          filePath,
          summary: await parseSessionFile(filePath),
        });
      }
    }),
  );

  return entries.filter(
    (entry): entry is { filePath: string; summary: NonNullable<typeof entry.summary> } =>
      entry.summary !== null,
  );
}

export function buildFallbackRelativePath(startedAt: string, sessionId: string) {
  const date = new Date(startedAt);
  const year = `${date.getUTCFullYear()}`;
  const month = `${date.getUTCMonth() + 1}`.padStart(2, "0");
  const day = `${date.getUTCDate()}`.padStart(2, "0");
  const safeTimestamp = startedAt.replaceAll(":", "-");
  return path.join(year, month, day, `rollout-${safeTimestamp}-${sessionId}.jsonl`);
}

export function resolveSessionRelativePath(
  record: Pick<SessionRecord, "originalRelativePath" | "startedAt" | "id">,
) {
  return record.originalRelativePath ?? buildFallbackRelativePath(record.startedAt, record.id);
}

export function looksCanonicalSessionRelativePath(relativePath: string, sessionId: string) {
  const segments = relativePath.split(path.sep);

  if (segments.length < 4) {
    return false;
  }

  const [year, month, day, ...rest] = segments;
  const basename = rest.join(path.sep);
  const normalizedYear = year ?? "";
  const normalizedMonth = month ?? "";
  const normalizedDay = day ?? "";

  return (
    /^\d{4}$/.test(normalizedYear) &&
    /^\d{2}$/.test(normalizedMonth) &&
    /^\d{2}$/.test(normalizedDay) &&
    basename.startsWith("rollout-") &&
    basename.endsWith(`-${sessionId}.jsonl`)
  );
}

export async function copyIfMissing(sourcePath: string, targetPath: string) {
  if (await pathExists(targetPath)) {
    return;
  }

  await copyFile(sourcePath, targetPath);
}

export async function pathExists(filePath: string | null) {
  if (!filePath) {
    return false;
  }

  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

export function buildResumeCommand(sessionId: string, targetCwd?: string) {
  if (!targetCwd) {
    return `codex resume ${shellQuote(sessionId)}`;
  }

  return `codex resume ${shellQuote(sessionId)} -C ${shellQuote(targetCwd)}`;
}

async function walkJsonlFiles(root: string): Promise<string[]> {
  try {
    const files: string[] = [];
    const pendingDirectories = [root];

    while (pendingDirectories.length > 0) {
      const currentDirectory = pendingDirectories.pop();

      if (!currentDirectory) {
        continue;
      }

      const items = await readdir(currentDirectory, { withFileTypes: true });

      for (const item of items) {
        const fullPath = path.join(currentDirectory, item.name);

        if (item.isDirectory()) {
          pendingDirectories.push(fullPath);
          continue;
        }

        if (item.name.endsWith(".jsonl")) {
          files.push(fullPath);
        }
      }
    }

    return files;
  } catch {
    return [];
  }
}
