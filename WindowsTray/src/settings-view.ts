import { invoke } from "@tauri-apps/api/core";
import { escapeHtml, optionMarkup } from "./dom";
import type { AppSettings, SettingsPresentation } from "./types";

export function renderGeneralSettings(
  presentation: SettingsPresentation,
  onUpdated: (next: SettingsPresentation) => void,
): string {
  const next = presentation;
  queueMicrotask(() => bindGeneralControls(next, onUpdated));
  return `
    <section class="settings-form" aria-label="${escapeHtml(next.labels.title)}">
      <label class="settings-row">
        <span>${escapeHtml(next.labels.refreshInterval)}</span>
        <select id="refreshIntervalPreset">
          ${optionMarkup(next.refreshIntervalOptions, next.settings.refreshIntervalPreset)}
        </select>
      </label>
      <label class="settings-row">
        <span>${escapeHtml(next.labels.language)}</span>
        <select id="appLanguage">
          ${optionMarkup(next.languageOptions, next.settings.appLanguage)}
        </select>
      </label>
      <label class="settings-row">
        <span>${escapeHtml(next.labels.trayStyle)}</span>
        <select id="statusItemStyle">
          ${optionMarkup(next.trayStyleOptions, next.settings.statusItemStyle)}
        </select>
      </label>
      <label class="settings-check">
        <input id="launchAtLoginEnabled" type="checkbox"${next.settings.launchAtLoginEnabled ? " checked" : ""} />
        <span>${escapeHtml(next.labels.launchAtLogin)}</span>
      </label>
    </section>
  `;
}

function readSettingsFromDom(previous: AppSettings): AppSettings {
  return {
    ...previous,
    refreshIntervalPreset: (document.querySelector<HTMLSelectElement>("#refreshIntervalPreset")?.value ?? "fiveMinutes") as AppSettings["refreshIntervalPreset"],
    appLanguage: (document.querySelector<HTMLSelectElement>("#appLanguage")?.value ?? "system") as AppSettings["appLanguage"],
    statusItemStyle: (document.querySelector<HTMLSelectElement>("#statusItemStyle")?.value ?? "meter") as AppSettings["statusItemStyle"],
    launchAtLoginEnabled: document.querySelector<HTMLInputElement>("#launchAtLoginEnabled")?.checked ?? false,
  };
}

function bindGeneralControls(
  presentation: SettingsPresentation,
  onUpdated: (next: SettingsPresentation) => void,
): void {
  for (const id of ["refreshIntervalPreset", "appLanguage", "statusItemStyle", "launchAtLoginEnabled"]) {
    document.querySelector(`#${id}`)?.addEventListener("change", async () => {
      const updated = await invoke<SettingsPresentation>("update_settings", {
        updated: readSettingsFromDom(presentation.settings),
      });
      onUpdated(updated);
    });
  }
}
