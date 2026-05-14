import { invoke } from "@tauri-apps/api/core";

type RefreshIntervalPreset =
  | "manual"
  | "oneMinute"
  | "fiveMinutes"
  | "fifteenMinutes";
type StatusItemStyle = "meter" | "text";
type AppLanguage = "system" | "english" | "chinese";
type ResolvedAppLanguage = "english" | "chinese";

type AppSettings = {
  refreshIntervalPreset: RefreshIntervalPreset;
  launchAtLoginEnabled: boolean;
  statusItemStyle: StatusItemStyle;
  appLanguage: AppLanguage;
  lastResolvedLanguage: ResolvedAppLanguage | null;
};

type SelectOption = {
  value: string;
  label: string;
};

type SettingsPresentation = {
  settings: AppSettings;
  resolvedLanguage: ResolvedAppLanguage;
  labels: {
    title: string;
    refreshInterval: string;
    language: string;
    trayStyle: string;
    launchAtLogin: string;
    saved: string;
  };
  refreshIntervalOptions: SelectOption[];
  languageOptions: SelectOption[];
  trayStyleOptions: SelectOption[];
  message: string | null;
};

const app = document.querySelector<HTMLDivElement>("#app");

if (!app) {
  throw new Error("Missing #app element");
}

let presentation: SettingsPresentation | null = null;

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => {
    switch (character) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      default:
        return "&#39;";
    }
  });
}

function optionMarkup(options: SelectOption[], selected: string): string {
  return options
    .map((option) => {
      const isSelected = option.value === selected ? " selected" : "";
      return `<option value="${escapeHtml(option.value)}"${isSelected}>${escapeHtml(
        option.label,
      )}</option>`;
    })
    .join("");
}

function setStatus(message: string): void {
  const status = document.querySelector<HTMLParagraphElement>("#status");

  if (status) {
    status.textContent = message;
  }
}

function render(next: SettingsPresentation): void {
  presentation = next;
  document.title = next.labels.title;
  app.innerHTML = `
    <main class="settings-shell">
      <header class="settings-header">
        <h1>${escapeHtml(next.labels.title)}</h1>
      </header>
      <section class="settings-form" aria-label="${escapeHtml(next.labels.title)}">
        <label class="settings-row">
          <span>${escapeHtml(next.labels.refreshInterval)}</span>
          <select id="refreshIntervalPreset">
            ${optionMarkup(
              next.refreshIntervalOptions,
              next.settings.refreshIntervalPreset,
            )}
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
          <input id="launchAtLoginEnabled" type="checkbox"${
            next.settings.launchAtLoginEnabled ? " checked" : ""
          } />
          <span>${escapeHtml(next.labels.launchAtLogin)}</span>
        </label>
      </section>
      <p id="status" class="settings-status">${escapeHtml(next.message ?? "")}</p>
    </main>
  `;

  bindControls();
}

function readSettingsFromDom(): AppSettings {
  if (!presentation) {
    throw new Error("Settings presentation has not loaded");
  }

  return {
    ...presentation.settings,
    refreshIntervalPreset: (document.querySelector<HTMLSelectElement>(
      "#refreshIntervalPreset",
    )?.value ?? "fiveMinutes") as RefreshIntervalPreset,
    appLanguage: (document.querySelector<HTMLSelectElement>("#appLanguage")
      ?.value ?? "system") as AppLanguage,
    statusItemStyle: (document.querySelector<HTMLSelectElement>("#statusItemStyle")
      ?.value ?? "meter") as StatusItemStyle,
    launchAtLoginEnabled:
      document.querySelector<HTMLInputElement>("#launchAtLoginEnabled")?.checked ??
      false,
  };
}

function bindControls(): void {
  for (const id of [
    "refreshIntervalPreset",
    "appLanguage",
    "statusItemStyle",
    "launchAtLoginEnabled",
  ]) {
    document.querySelector(`#${id}`)?.addEventListener("change", async () => {
      setStatus("");

      try {
        const updated = await invoke<SettingsPresentation>("update_settings", {
          updated: readSettingsFromDom(),
        });
        render(updated);
      } catch (error) {
        setStatus(String(error));
      }
    });
  }
}

async function load(): Promise<void> {
  try {
    render(await invoke<SettingsPresentation>("get_settings"));
  } catch (error) {
    app.textContent = String(error);
  }
}

void load();
