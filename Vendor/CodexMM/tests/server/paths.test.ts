import path from "node:path";

import { describe, expect, test } from "vitest";

import { AppError } from "../../src/server/lib/errors";
import { ensureInsidePath } from "../../src/server/lib/paths";

describe("ensureInsidePath", () => {
  test("includes structured details when a candidate escapes the managed root", () => {
    const root = path.join("/tmp", "managed-root");
    const candidate = path.join("/tmp", "escape.jsonl");

    try {
      ensureInsidePath(root, candidate);
      throw new Error("expected ensureInsidePath to throw");
    } catch (error) {
      expect(error).toBeInstanceOf(AppError);
      expect(error).toMatchObject({
        code: "path_outside_managed_root",
        details: {
          managedRoot: root,
          candidatePath: candidate,
          resolvedCandidatePath: candidate,
        },
      } satisfies Partial<AppError & { details: unknown }>);
      expect((error as AppError).message).toBe(
        `Path is outside managed root: ${candidate}`,
      );
    }
  });
});
