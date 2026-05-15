import { invoke } from "@tauri-apps/api/core";
import { renderAccounts } from "./accounts-view";
import { escapeHtml } from "./dom";
import { renderGeneralSettings } from "./settings-view";
import type { AccountsPresentation, SettingsPresentation } from "./types";

const app = document.querySelector<HTMLDivElement>("#app");

if (!app) {
  throw new Error("Missing #app element");
}

let settingsPresentation: SettingsPresentation | null = null;
let accountsPresentation: AccountsPresentation | null = null;
let activeTab: "general" | "accounts" = "general";

function render(): void {
  if (!settingsPresentation || !accountsPresentation) {
    return;
  }
  document.title = settingsPresentation.labels.title;
  const body =
    activeTab === "general"
      ? renderGeneralSettings(settingsPresentation, (next) => {
          settingsPresentation = next;
          render();
        })
      : renderAccounts(accountsPresentation, (next) => {
          accountsPresentation = next;
          render();
        });

  app.innerHTML = `
    <main class="settings-shell">
      <header class="settings-header">
        <h1>${escapeHtml(settingsPresentation.labels.title)}</h1>
        <nav class="settings-tabs">
          <button id="tabGeneral" class="${activeTab === "general" ? "active" : ""}">General</button>
          <button id="tabAccounts" class="${activeTab === "accounts" ? "active" : ""}">${escapeHtml(accountsPresentation.labels.accounts)}</button>
        </nav>
      </header>
      ${body}
    </main>
  `;
  document.querySelector("#tabGeneral")?.addEventListener("click", () => {
    activeTab = "general";
    render();
  });
  document.querySelector("#tabAccounts")?.addEventListener("click", () => {
    activeTab = "accounts";
    render();
  });
}

async function load(): Promise<void> {
  try {
    settingsPresentation = await invoke<SettingsPresentation>("get_settings");
    accountsPresentation = await invoke<AccountsPresentation>("get_accounts");
    render();
  } catch (error) {
    app.textContent = String(error);
  }
}

void load();
