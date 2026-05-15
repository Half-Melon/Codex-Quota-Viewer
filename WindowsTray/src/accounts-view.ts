import { invoke } from "@tauri-apps/api/core";
import { escapeHtml } from "./dom";
import type { AccountsPresentation } from "./types";

export function renderAccounts(
  presentation: AccountsPresentation,
  onUpdated: (next: AccountsPresentation) => void,
): string {
  queueMicrotask(() => bindAccountControls(onUpdated));
  const rows = presentation.rows.length
    ? presentation.rows.map((row) => `
      <div class="account-row" data-account-id="${escapeHtml(row.id)}">
        <div>
          <strong>${escapeHtml(row.displayName)}</strong>
          <span>${escapeHtml(row.kind === "chatGpt" ? "ChatGPT" : "API")}</span>
          <small>${escapeHtml(row.status)}</small>
        </div>
        <div class="account-actions">
          <button data-action="activate" data-account-id="${escapeHtml(row.id)}">${escapeHtml(presentation.labels.activate)}</button>
          <button data-action="rename" data-account-id="${escapeHtml(row.id)}">${escapeHtml(presentation.labels.rename)}</button>
          <button data-action="forget" data-account-id="${escapeHtml(row.id)}">${escapeHtml(presentation.labels.forget)}</button>
        </div>
      </div>
    `).join("")
    : `<p class="settings-status">${escapeHtml(presentation.labels.noSavedAccounts)}</p>`;

  return `
    <section class="accounts-panel">
      <div class="accounts-toolbar">
        <button id="importChatGpt">${escapeHtml(presentation.labels.signInWithChatgpt)}</button>
        <button id="showApiForm">${escapeHtml(presentation.labels.addApiAccount)}</button>
        <button id="openVaultFolder">${escapeHtml(presentation.labels.openVaultFolder)}</button>
      </div>
      <form id="apiAccountForm" class="api-form" hidden>
        <label>Display name<input id="apiDisplayName" /></label>
        <label>API key<input id="apiKey" /></label>
        <label>Base URL<input id="apiBaseUrl" /></label>
        <label>Model<input id="apiModel" /></label>
        <label>Provider name<input id="apiProviderName" /></label>
        <button type="submit">${escapeHtml(presentation.labels.addApiAccount)}</button>
      </form>
      <div class="account-list">${rows}</div>
      <p id="accountsStatus" class="settings-status">${escapeHtml(presentation.message ?? "")}</p>
    </section>
  `;
}

function bindAccountControls(onUpdated: (next: AccountsPresentation) => void): void {
  document.querySelector("#importChatGpt")?.addEventListener("click", async () => {
    onUpdated(await invoke<AccountsPresentation>("import_current_chatgpt_account", { displayName: null }));
  });
  document.querySelector("#showApiForm")?.addEventListener("click", () => {
    const form = document.querySelector<HTMLFormElement>("#apiAccountForm");
    if (form) {
      form.hidden = !form.hidden;
    }
  });
  document.querySelector("#openVaultFolder")?.addEventListener("click", async () => {
    await invoke("open_vault_folder");
  });
  document.querySelector("#apiAccountForm")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    onUpdated(await invoke<AccountsPresentation>("add_api_account", {
      input: {
        displayName: document.querySelector<HTMLInputElement>("#apiDisplayName")?.value ?? "",
        apiKey: document.querySelector<HTMLInputElement>("#apiKey")?.value ?? "",
        baseUrl: document.querySelector<HTMLInputElement>("#apiBaseUrl")?.value ?? "",
        model: document.querySelector<HTMLInputElement>("#apiModel")?.value || null,
        providerName: document.querySelector<HTMLInputElement>("#apiProviderName")?.value || null,
      },
    }));
  });
  const actionButtons = document.querySelectorAll<HTMLButtonElement>("[data-action]");
  for (let i = 0; i < actionButtons.length; i++) {
    const button = actionButtons[i];
    button.addEventListener("click", async () => {
      const accountId = button.dataset.accountId ?? "";
      const action = button.dataset.action;
      if (action === "activate" && confirm("Activate this account for local Codex? This updates files in your Codex home.")) {
        onUpdated(await invoke<AccountsPresentation>("activate_account", { accountId }));
      }
      if (action === "rename") {
        const displayName = prompt("Rename account");
        if (displayName) {
          onUpdated(await invoke<AccountsPresentation>("rename_account", { accountId, displayName }));
        }
      }
      if (action === "forget" && confirm("Forget this account?")) {
        onUpdated(await invoke<AccountsPresentation>("forget_account", { accountId }));
      }
    });
  }
}
