import type { SessionRecord } from "../shared/contracts";
import type { UiLanguage } from "./i18n";
import { resolveLocale } from "./i18n";

export function getSessionTitle(session: SessionRecord) {
  return (
    normalizeExcerpt(session.userPromptExcerpt) ??
    normalizeExcerpt(session.latestAgentMessageExcerpt)
  );
}

export function normalizeExcerpt(excerpt: string | null | undefined) {
  const value = excerpt?.trim();
  return value ? value : null;
}

export function readProjectName(cwd: string, fallbackName: string) {
  const segments = cwd.split("/").filter(Boolean);
  return segments.at(-1) || cwd || fallbackName;
}

export function formatSessionListTime(startedAt: string, language: UiLanguage) {
  return new Date(startedAt).toLocaleString(resolveLocale(language), {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function formatSessionDate(value: string, language: UiLanguage) {
  return new Date(value).toLocaleString(resolveLocale(language), {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function formatTimelineTime(value: string, language: UiLanguage) {
  return new Date(value).toLocaleString(resolveLocale(language), {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

export function parseTimestamp(value: string) {
  return Number.isNaN(Date.parse(value)) ? 0 : Date.parse(value);
}
