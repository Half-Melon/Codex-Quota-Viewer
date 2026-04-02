import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

export type CodexSessionIndexEntry = {
  id: string;
  threadName: string;
  updatedAt: string;
};

export class CodexSessionIndexRepository {
  private readonly filePath: string;

  constructor(codexHome: string) {
    this.filePath = path.join(codexHome, "session_index.jsonl");
  }

  async listEntries() {
    return [...(await this.readEntryMap()).values()].sort(sortEntriesByUpdatedAt);
  }

  async getEntry(id: string) {
    return (await this.readEntryMap()).get(id) ?? null;
  }

  async replaceEntries(entries: Iterable<CodexSessionIndexEntry>) {
    const nextEntries = new Map<string, CodexSessionIndexEntry>();

    for (const entry of entries) {
      nextEntries.set(entry.id, entry);
    }

    await this.writeEntryMap(nextEntries);
  }

  async upsertEntry(entry: CodexSessionIndexEntry) {
    const entries = await this.readEntryMap();
    const existing = entries.get(entry.id);

    if (
      existing &&
      existing.threadName === entry.threadName &&
      existing.updatedAt === entry.updatedAt
    ) {
      return "unchanged" as const;
    }

    entries.set(entry.id, entry);
    await this.writeEntryMap(entries);
    return existing ? ("updated" as const) : ("created" as const);
  }

  async deleteEntry(id: string) {
    const entries = await this.readEntryMap();

    if (!entries.delete(id)) {
      return false;
    }

    await this.writeEntryMap(entries);
    return true;
  }

  private async readEntryMap() {
    try {
      const content = await readFile(this.filePath, "utf8");
      const entries = new Map<string, CodexSessionIndexEntry>();

      for (const line of content.split(/\r?\n/u)) {
        const trimmed = line.trim();

        if (!trimmed) {
          continue;
        }

        try {
          const parsed = JSON.parse(trimmed) as Record<string, unknown>;
          const id = typeof parsed.id === "string" ? parsed.id : "";
          const threadName =
            typeof parsed.thread_name === "string"
              ? parsed.thread_name
              : typeof parsed.threadName === "string"
                ? parsed.threadName
                : "";
          const updatedAt =
            typeof parsed.updated_at === "string"
              ? parsed.updated_at
              : typeof parsed.updatedAt === "string"
                ? parsed.updatedAt
                : "";

          if (!id || !threadName || !updatedAt) {
            continue;
          }

          entries.set(id, { id, threadName, updatedAt });
        } catch {
          continue;
        }
      }

      return entries;
    } catch {
      return new Map<string, CodexSessionIndexEntry>();
    }
  }

  private async writeEntryMap(entries: Map<string, CodexSessionIndexEntry>) {
    const directory = path.dirname(this.filePath);
    const tempPath = path.join(
      directory,
      `session_index.jsonl.tmp-${process.pid}-${Date.now()}`,
    );

    await mkdir(directory, { recursive: true });
    const content = [...entries.values()]
      .sort(sortEntriesByUpdatedAt)
      .map((entry) =>
        JSON.stringify({
          id: entry.id,
          thread_name: entry.threadName,
          updated_at: entry.updatedAt,
        }),
      )
      .join("\n");

    await writeFile(tempPath, content ? `${content}\n` : "");
    await rename(tempPath, this.filePath);
  }
}

function sortEntriesByUpdatedAt(left: CodexSessionIndexEntry, right: CodexSessionIndexEntry) {
  return Date.parse(right.updatedAt) - Date.parse(left.updatedAt);
}
