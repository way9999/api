const STORAGE_KEYS = {
  settings: "chat-workspace-settings-v2",
  threads: "chat-workspace-threads-v2",
  activeThreadId: "chat-workspace-active-thread-v2"
};

const USER_ACCESS_TOKEN_ID = "__user_access__";

const defaultSettings = {
  activeMode: "guest",
  guest: {
    apiBase: defaultGuestBase(),
    apiKey: "",
    model: "",
    systemPrompt: "",
    temperature: 0.7,
    maxTokens: "",
    stream: true
  },
  account: {
    apiBase: window.location.origin,
    username: "",
    model: "",
    systemPrompt: "",
    temperature: 0.7,
    maxTokens: "",
    stream: true,
    selectedTokenId: USER_ACCESS_TOKEN_ID
  }
};

const state = {
  settings: loadSettings(),
  threads: loadThreads(),
  activeThreadId: localStorage.getItem(STORAGE_KEYS.activeThreadId) || null,
  account: {
    user: null,
    userAccessToken: "",
    tokens: [],
    loading: false
  },
  models: {
    guest: [],
    account: []
  },
  request: {
    controller: null,
    active: false
  }
};

const el = {
  sidebar: document.querySelector("#sidebar"),
  sidebarBackdrop: document.querySelector("#sidebarBackdrop"),
  openSidebarButton: document.querySelector("#openSidebarButton"),
  closeSidebarButton: document.querySelector("#closeSidebarButton"),
  threadList: document.querySelector("#threadList"),
  threadCountLabel: document.querySelector("#threadCountLabel"),
  newChatButton: document.querySelector("#newChatButton"),
  openSettingsButton: document.querySelector("#openSettingsButton"),
  settingsButton: document.querySelector("#settingsButton"),
  settingsPanel: document.querySelector("#settingsPanel"),
  closeSettingsButton: document.querySelector("#closeSettingsButton"),
  panelBackdrop: document.querySelector("#panelBackdrop"),
  modeSwitch: document.querySelector("#modeSwitch"),
  modeSummary: document.querySelector("#modeSummary"),
  topbarModeLabel: document.querySelector("#topbarModeLabel"),
  conversationTitle: document.querySelector("#conversationTitle"),
  modelSelect: document.querySelector("#modelSelect"),
  refreshModelsButton: document.querySelector("#refreshModelsButton"),
  accountBanner: document.querySelector("#accountBanner"),
  messageSurface: document.querySelector("#messageSurface"),
  welcomeState: document.querySelector("#welcomeState"),
  messageList: document.querySelector("#messageList"),
  statusPill: document.querySelector("#statusPill"),
  credentialHint: document.querySelector("#credentialHint"),
  composerForm: document.querySelector("#composerForm"),
  composerInput: document.querySelector("#composerInput"),
  sendButton: document.querySelector("#sendButton"),
  stopButton: document.querySelector("#stopButton"),
  toastStack: document.querySelector("#toastStack"),
  accountSection: document.querySelector("#accountSection"),
  guestSection: document.querySelector("#guestSection"),
  accountBaseInput: document.querySelector("#accountBaseInput"),
  accountUsernameInput: document.querySelector("#accountUsernameInput"),
  accountPasswordInput: document.querySelector("#accountPasswordInput"),
  accountLoginForm: document.querySelector("#accountLoginForm"),
  accountSessionButton: document.querySelector("#accountSessionButton"),
  accountLogoutButton: document.querySelector("#accountLogoutButton"),
  accountInfoCard: document.querySelector("#accountInfoCard"),
  accountTokenSelect: document.querySelector("#accountTokenSelect"),
  guestApiBaseInput: document.querySelector("#guestApiBaseInput"),
  guestApiKeyInput: document.querySelector("#guestApiKeyInput"),
  guestModelInput: document.querySelector("#guestModelInput"),
  systemPromptInput: document.querySelector("#systemPromptInput"),
  temperatureInput: document.querySelector("#temperatureInput"),
  maxTokensInput: document.querySelector("#maxTokensInput"),
  streamToggle: document.querySelector("#streamToggle")
};

init();

function init() {
  clampActiveThread();
  bindEvents();
  renderAll();
  hydrateModeSettings();
  bootstrapActiveMode();
  autoResizeTextarea(el.composerInput);
}

function bindEvents() {
  el.newChatButton.addEventListener("click", handleNewChat);
  el.openSettingsButton.addEventListener("click", openSettingsPanel);
  el.settingsButton.addEventListener("click", openSettingsPanel);
  el.closeSettingsButton.addEventListener("click", closeSettingsPanel);
  el.panelBackdrop.addEventListener("click", closeSettingsPanel);
  el.openSidebarButton.addEventListener("click", () => toggleSidebar(true));
  el.closeSidebarButton.addEventListener("click", () => toggleSidebar(false));
  el.sidebarBackdrop.addEventListener("click", () => toggleSidebar(false));
  el.threadList.addEventListener("click", handleThreadListClick);
  el.modeSwitch.addEventListener("click", handleModeSwitch);
  el.modelSelect.addEventListener("change", handleModelSelectChange);
  el.refreshModelsButton.addEventListener("click", () => refreshModels(true));
  el.accountLoginForm.addEventListener("submit", handleAccountLogin);
  el.accountSessionButton.addEventListener("click", () => bootstrapAccountSession(true));
  el.accountLogoutButton.addEventListener("click", handleAccountLogout);
  el.accountTokenSelect.addEventListener("change", handleAccountTokenChange);
  el.composerForm.addEventListener("submit", handleComposerSubmit);
  el.composerInput.addEventListener("input", () => autoResizeTextarea(el.composerInput));
  el.composerInput.addEventListener("keydown", handleComposerKeydown);
  el.stopButton.addEventListener("click", stopStreaming);
  el.messageList.addEventListener("click", handleMessageToolsClick);
  document.querySelectorAll("[data-prompt]").forEach((button) => {
    button.addEventListener("click", () => {
      el.composerInput.value = button.dataset.prompt || "";
      autoResizeTextarea(el.composerInput);
      el.composerInput.focus();
    });
  });
  el.accountBaseInput.addEventListener("input", () => {
    state.settings.account.apiBase = normalizeAccountBase(el.accountBaseInput.value);
    persistSettings();
    renderAccountBanner();
  });
  el.accountUsernameInput.addEventListener("input", () => {
    state.settings.account.username = el.accountUsernameInput.value.trim();
    persistSettings();
  });
  el.guestApiBaseInput.addEventListener("input", () => {
    state.settings.guest.apiBase = normalizeGuestBase(el.guestApiBaseInput.value);
    persistSettings();
    renderCredentialHint();
  });
  el.guestApiKeyInput.addEventListener("input", () => {
    state.settings.guest.apiKey = el.guestApiKeyInput.value.trim();
    persistSettings();
    renderCredentialHint();
  });
  el.guestModelInput.addEventListener("input", () => {
    state.settings.guest.model = el.guestModelInput.value.trim();
    persistSettings();
    syncModelSelect();
  });
  el.systemPromptInput.addEventListener("input", () => {
    activeModeSettings().systemPrompt = el.systemPromptInput.value;
    persistSettings();
  });
  el.temperatureInput.addEventListener("input", () => {
    activeModeSettings().temperature = sanitizeTemperature(el.temperatureInput.value);
    persistSettings();
  });
  el.maxTokensInput.addEventListener("input", () => {
    activeModeSettings().maxTokens = sanitizeMaxTokens(el.maxTokensInput.value);
    persistSettings();
  });
  el.streamToggle.addEventListener("change", () => {
    activeModeSettings().stream = el.streamToggle.checked;
    persistSettings();
  });
  window.addEventListener("resize", () => {
    if (window.innerWidth > 920) toggleSidebar(false);
  });
}

function handleModeSwitch(event) {
  const button = event.target.closest("[data-mode]");
  if (!button) return;
  const nextMode = button.dataset.mode;
  if (!nextMode || nextMode === state.settings.activeMode) return;
  state.settings.activeMode = nextMode;
  persistSettings();
  hydrateModeSettings();
  renderAll();
  bootstrapActiveMode();
}

function handleModelSelectChange() {
  activeModeSettings().model = el.modelSelect.value;
  if (state.settings.activeMode === "guest") el.guestModelInput.value = el.modelSelect.value;
  persistSettings();
  renderCredentialHint();
}

function handleThreadListClick(event) {
  const deleteButton = event.target.closest("[data-thread-delete]");
  if (deleteButton) {
    deleteThread(deleteButton.dataset.threadDelete);
    return;
  }
  const threadButton = event.target.closest("[data-thread-id]");
  if (!threadButton) return;
  state.activeThreadId = threadButton.dataset.threadId;
  persistActiveThreadId();
  renderThreadArea();
  toggleSidebar(false);
}

function handleMessageToolsClick(event) {
  const copyButton = event.target.closest("[data-copy-message]");
  if (!copyButton) return;
  const message = findMessageById(copyButton.dataset.copyMessage);
  if (!message) return;
  navigator.clipboard.writeText(message.content || "").then(
    () => notify("Copied", "success"),
    () => notify("Copy failed. Please copy manually.", "error")
  );
}

async function handleAccountLogin(event) {
  event.preventDefault();
  const username = el.accountUsernameInput.value.trim();
  const password = el.accountPasswordInput.value;
  if (!username || !password) {
    notify("Enter username and password.", "error");
    return;
  }
  try {
    setStatus("Signing in...");
    const payload = await postAccountLogin(normalizeAccountBase(el.accountBaseInput.value), { username, password, email: username });
    applyLoginPayload(payload);
    state.settings.account.username = username;
    persistSettings();
    el.accountPasswordInput.value = "";
    if (state.account.user && state.account.userAccessToken) {
      await loadAccountTokens();
      await refreshModels(false);
      renderAll();
      setStatus("Account connected");
    } else {
      await bootstrapAccountSession(true);
    }
    notify("Signed in", "success");
  } catch (error) {
    notify(error.message || "Sign-in failed", "error");
    setStatus("Sign-in failed");
  }
}

async function handleAccountLogout() {
  try {
    await accountFetchJson("/api/user/logout", { method: "GET", credentials: "include" });
  } catch (error) {
  }
  clearAccountSession();
  renderAll();
  notify("Signed out", "success");
}

async function handleAccountTokenChange() {
  state.settings.account.selectedTokenId = el.accountTokenSelect.value || USER_ACCESS_TOKEN_ID;
  persistSettings();
  await refreshModels(true);
}

function handleComposerKeydown(event) {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    el.composerForm.requestSubmit();
  }
}

async function handleComposerSubmit(event) {
  event.preventDefault();
  const content = el.composerInput.value.trim();
  if (!content || state.request.active) return;
  const validation = validateBeforeSend();
  if (!validation.ok) {
    notify(validation.message, "error");
    return;
  }
  const thread = ensureActiveThread(content);
  thread.messages.push(createMessage("user", content));
  touchThread(thread, content);
  persistThreads();
  persistActiveThreadId();
  el.composerInput.value = "";
  autoResizeTextarea(el.composerInput);
  const assistantMessage = createMessage("assistant", "");
  thread.messages.push(assistantMessage);
  persistThreads();
  renderThreadArea();
  scrollMessagesToBottom(true);
  try {
    const payloadMessages = buildChatMessages(thread.messages.slice(0, -1));
    await dispatchChatCompletion(assistantMessage, payloadMessages);
    if (!assistantMessage.content.trim()) assistantMessage.content = "The model returned no displayable text.";
  } catch (error) {
    assistantMessage.content = `Request failed: ${error.message || "Unknown error"}`;
    notify(error.message || "Request failed", "error");
  } finally {
    persistThreads();
    renderThreadArea();
    setRequestActive(false);
  }
}

function handleNewChat() {
  state.activeThreadId = null;
  persistActiveThreadId();
  renderThreadArea();
  toggleSidebar(false);
}

async function bootstrapActiveMode() {
  if (state.settings.activeMode === "account") {
    await bootstrapAccountSession(false);
  } else {
    await refreshModels(false);
  }
}

async function bootstrapAccountSession(forceNotice) {
  if (state.account.loading) return;
  state.account.loading = true;
  renderAccountCard();
  setStatus("Checking account session...");
  try {
    const user = await accountFetchJson("/api/user/self", { credentials: "include" });
    const userData = unwrapResponseData(user);
    if (!userData || typeof userData !== "object") throw new Error("No valid session found");
    state.account.user = userData;
    state.account.userAccessToken = await fetchUserAccessToken();
    await loadAccountTokens();
    await refreshModels(false);
    if (forceNotice) notify("Account synced", "success");
    setStatus("Account connected");
  } catch (error) {
    clearAccountSession();
    renderAll();
    if (forceNotice) notify(error.message || "No active session found", "error");
    setStatus("Waiting for sign-in");
  } finally {
    state.account.loading = false;
    renderAccountCard();
    renderAccountBanner();
  }
}

async function fetchUserAccessToken() {
  const response = await accountFetchJson("/api/user/token", { credentials: "include" });
  const data = unwrapResponseData(response);
  if (typeof data === "string" && data.trim()) return data.trim();
  if (data && typeof data === "object") {
    const value = data.access_token || data.token || data.key;
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  throw new Error("Failed to get user access token");
}

async function loadAccountTokens() {
  try {
    const response = await accountFetchJson("/api/token/?p=0&size=100", { credentials: "include" });
    state.account.tokens = normalizeTokenList(unwrapResponseData(response));
  } catch (error) {
    state.account.tokens = [];
  }
  renderAccountTokenSelect();
}

async function refreshModels(forceNotice) {
  try {
    setStatus("Loading models...");
    if (state.settings.activeMode === "account") {
      const apiBase = normalizeGuestBase(`${normalizeAccountBase(state.settings.account.apiBase)}/v1`);
      const credential = currentChatCredential();
      if (!credential) {
        state.models.account = [];
        syncModelSelect();
        renderCredentialHint();
        setStatus("Waiting for account credential");
        return;
      }
      state.models.account = await fetchModelList(apiBase, credential);
    } else {
      const { apiBase, apiKey } = state.settings.guest;
      if (!apiBase || !apiKey) {
        state.models.guest = [];
        syncModelSelect();
        renderCredentialHint();
        setStatus("Waiting for guest configuration");
        return;
      }
      state.models.guest = await fetchModelList(apiBase, apiKey);
    }
    syncModelSelect();
    renderCredentialHint();
    setStatus("Models synced");
    if (forceNotice) notify("Model list refreshed", "success");
  } catch (error) {
    if (state.settings.activeMode === "account") {
      state.models.account = [];
    } else {
      state.models.guest = [];
    }
    syncModelSelect();
    renderCredentialHint();
    setStatus("Failed to load models");
    if (forceNotice) notify(error.message || "Failed to load models", "error");
  }
}
async function dispatchChatCompletion(assistantMessage, payloadMessages) {
  const { apiBase, apiKey, model, systemPrompt, temperature, maxTokens, stream } = currentChatContext();
  const preferResponses = shouldUseResponsesEndpoint(model);

  setRequestActive(true);
  setStatus(stream ? "Generating..." : "Waiting for model response...");
  const controller = new AbortController();
  state.request.controller = controller;

  const attempt = async (useResponses) => {
    const request = buildChatRequest({
      useResponses,
      apiBase,
      model,
      systemPrompt,
      temperature,
      maxTokens,
      stream,
      payloadMessages
    });

    const response = await apiFetch(request.apiBase, request.path, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
        ...(request.headers || {})
      },
      body: JSON.stringify(request.body),
      signal: controller.signal
    });
    if (!response.ok) throw await buildHttpError(response);

    if (!stream) {
      const payload = await response.json();
      assistantMessage.content = extractAssistantText(payload);
      return;
    }

    await consumeStream(response, (textChunk) => {
      assistantMessage.content += textChunk;
      persistThreads();
      renderThreadArea(false);
      scrollMessagesToBottom(false);
    });
  };

  try {
    await attempt(preferResponses);
  } catch (error) {
    if (!preferResponses && isEndpointUnsupportedError(error)) {
      await attempt(true);
      return;
    }
    throw error;
  }
}

function buildChatRequest({ useResponses, apiBase, model, systemPrompt, temperature, maxTokens, stream, payloadMessages }) {
  if (!useResponses) {
    const requestBody = {
      model,
      messages: systemPrompt ? [{ role: "system", content: systemPrompt }, ...payloadMessages] : payloadMessages,
      stream: Boolean(stream),
      temperature: sanitizeTemperature(temperature)
    };
    if (maxTokens) requestBody.max_tokens = Number(maxTokens);
    return {
      url: `${apiBase}/chat/completions`,
      apiBase,
      path: "/chat/completions",
      body: requestBody,
      headers: null
    };
  }

  const requestBody = {
    model,
    input: buildResponsesInput(systemPrompt, payloadMessages),
    stream: Boolean(stream),
    temperature: sanitizeTemperature(temperature)
  };
  if (maxTokens) requestBody.max_output_tokens = Number(maxTokens);
  return {
    url: `${apiBase}/responses`,
    apiBase,
    path: "/responses",
    body: requestBody,
    headers: { "OpenAI-Beta": "responses=experimental" }
  };
}
function buildResponsesInput(systemPrompt, payloadMessages) {
  const items = [];
  if (systemPrompt) {
    items.push({ role: "system", content: [{ type: "text", text: systemPrompt }] });
  }
  for (const message of payloadMessages) {
    if (!message || !message.content) continue;
    items.push({ role: message.role, content: [{ type: "text", text: message.content }] });
  }
  return items;
}

function shouldUseResponsesEndpoint(model) {
  const name = String(model || "").toLowerCase();
  return name.includes("codex");
}

function isEndpointUnsupportedError(error) {
  const message = String(error?.message || "");
  return /endpoint not supported/i.test(message) && /chat\/completions/i.test(message);
}

function stopStreaming() {
  if (!state.request.controller) return;
  state.request.controller.abort();
  setRequestActive(false);
  setStatus("Generation stopped");
  notify("Stopped current response", "success");
}

async function consumeStream(response, onTextChunk) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder("utf-8");
  let buffer = "";
  let receivedIncremental = false;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let boundary = buffer.indexOf("\n\n");
    while (boundary !== -1) {
      const rawEvent = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      const result = processSseEvent(rawEvent);
      if (result.incremental && result.text) receivedIncremental = true;
      if (result.text && (!result.completed || !receivedIncremental || result.incremental)) onTextChunk(result.text);
      boundary = buffer.indexOf("\n\n");
    }
  }
  if (buffer.trim()) {
    const result = processSseEvent(buffer);
    if (result.incremental && result.text) receivedIncremental = true;
    if (result.text && (!result.completed || !receivedIncremental || result.incremental)) onTextChunk(result.text);
  }
}

function processSseEvent(rawEvent) {
  const dataLines = rawEvent
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trim());
  if (!dataLines.length) return { text: "", incremental: false, completed: false };
  const data = dataLines.join("");
  if (!data || data === "[DONE]") return { text: "", incremental: false, completed: false };
  try {
    const payload = JSON.parse(data);
    const eventType = String(payload?.type || "");
    const textChunk = extractStreamText(payload);
    return {
      text: textChunk || "",
      incremental: /delta/i.test(eventType),
      completed: /completed|done/i.test(eventType)
    };
  } catch (error) {
    return { text: "", incremental: false, completed: false };
  }
}

function renderAll() {
  renderModeSummary();
  renderAccountCard();
  renderAccountTokenSelect();
  renderThreadSidebar();
  renderThreadArea();
  renderSettingsMode();
  renderAccountBanner();
  renderCredentialHint();
  syncFormFields();
  syncModelSelect();
}

function renderModeSummary() {
  const activeMode = state.settings.activeMode;
  const connected = Boolean(state.account.user && state.account.userAccessToken);
  el.modeSummary.innerHTML = activeMode === "account"
    ? `<strong>Account Mode</strong><p>${connected ? "Connected to the new-api account. You can use the account balance and tokens directly." : "Not signed in. Complete sign-in from the settings panel."}</p>`
    : `<strong>Guest Mode</strong><p>Call any OpenAI-compatible API by entering URL, key, and model manually.</p>`;
  el.topbarModeLabel.textContent = activeMode === "account" ? "Account Mode" : "Guest Mode";
}

function renderThreadSidebar() {
  el.threadCountLabel.textContent = String(state.threads.length);
  if (!state.threads.length) {
    el.threadList.innerHTML = `<div class="thread-item"><h4>No conversations yet</h4><p>Click New Chat or send your first message.</p></div>`;
    return;
  }
  el.threadList.innerHTML = state.threads.slice().sort((a, b) => b.updatedAt - a.updatedAt).map((thread) => {
    const activeClass = thread.id === state.activeThreadId ? "active" : "";
    const preview = thread.messages.find((item) => item.role === "assistant" && item.content.trim()) || thread.messages.find((item) => item.role === "user");
    return `
      <button class="thread-item ${activeClass}" type="button" data-thread-id="${thread.id}">
        <h4>${escapeHtml(thread.title || "New Conversation")}</h4>
        <p>${escapeHtml((preview?.content || "No content").slice(0, 70))}</p>
        <div class="thread-actions">
          <span>${formatDate(thread.updatedAt)}</span>
          <span class="thread-delete" data-thread-delete="${thread.id}">Delete</span>
        </div>
      </button>
    `;
  }).join("");
}

function renderThreadArea(scrollBottom = true) {
  const thread = getActiveThread();
  const messages = thread?.messages || [];
  el.welcomeState.classList.toggle("hidden", Boolean(messages.length));
  el.messageList.innerHTML = messages.map(renderMessageGroup).join("");
  el.conversationTitle.textContent = thread?.title || "New Chat";
  if (scrollBottom) scrollMessagesToBottom(true);
}

function renderMessageGroup(message) {
  const roleLabel = message.role === "user" ? "You" : "Assistant";
  const actions = message.role === "assistant"
    ? `<button class="mini-button" type="button" data-copy-message="${message.id}">Copy</button>`
    : "";
  return `
    <article class="message-group ${message.role}">
      <div class="message-meta">
        <span class="message-role">${roleLabel}</span>
        <div class="message-tools">${actions}</div>
      </div>
      <div class="message-bubble">
        ${message.content.trim() ? renderRichText(message.content) : '<p class="message-empty">Waiting for model output...</p>'}
      </div>
    </article>
  `;
}

function renderSettingsMode() {
  const activeMode = state.settings.activeMode;
  el.accountSection.classList.toggle("hidden", activeMode !== "account");
  el.guestSection.classList.toggle("hidden", activeMode !== "guest");
  Array.from(el.modeSwitch.querySelectorAll("[data-mode]")).forEach((button) => {
    button.classList.toggle("active", button.dataset.mode === activeMode);
  });
}

function renderAccountCard() {
  if (state.account.loading) {
    el.accountInfoCard.innerHTML = "<strong>Syncing account status...</strong><p>This checks the session, profile, and available tokens.</p>";
    return;
  }
  if (!state.account.user) {
    el.accountInfoCard.innerHTML = "<strong>Not signed in</strong><p>Enter new-api username and password, or click Check Session.</p>";
    return;
  }
  const user = state.account.user;
  el.accountInfoCard.innerHTML = `
    <strong>${escapeHtml(user.display_name || user.username || state.settings.account.username || "Current User")}</strong>
    <p>Group: ${escapeHtml(String(user.group || user.aff_code || "Default"))}</p>
    <p>Balance: ${formatQuota(user.quota)}</p>
    <p>Used: ${formatQuota(user.used_quota)}</p>
    <p>Personal tokens: ${state.account.tokens.length}</p>
  `;
}

function renderAccountTokenSelect() {
  const options = [{ id: USER_ACCESS_TOKEN_ID, label: "User Access Token (Default)" }].concat(
    state.account.tokens.map((token) => ({ id: String(token.id ?? token.key ?? token.name), label: formatTokenLabel(token) }))
  );
  el.accountTokenSelect.innerHTML = options.map((option) => `<option value="${escapeHtml(option.id)}">${escapeHtml(option.label)}</option>`).join("");
  const selected = state.settings.account.selectedTokenId || USER_ACCESS_TOKEN_ID;
  el.accountTokenSelect.value = options.some((option) => option.id === selected) ? selected : USER_ACCESS_TOKEN_ID;
}

function renderAccountBanner() {
  if (state.settings.activeMode !== "account") {
    el.accountBanner.classList.add("hidden");
    return;
  }
  const apiBase = normalizeAccountBase(state.settings.account.apiBase);
  if (!state.account.user) {
    el.accountBanner.classList.remove("hidden");
    el.accountBanner.innerHTML = apiBase === window.location.origin
      ? "Account mode is active. Sign in with the local new-api account and use your own balance and tokens."
      : "Account mode is active. Deploy chat and new-api on the same origin when possible, otherwise cross-site cookies may break the session.";
    return;
  }
  const credential = currentChatCredentialMeta();
  el.accountBanner.classList.remove("hidden");
  el.accountBanner.innerHTML = `Connected account <strong>${escapeHtml(state.account.user.display_name || state.account.user.username || "Current User")}</strong>. Current credential: <strong>${escapeHtml(credential.label)}</strong>.`;
}

function renderCredentialHint() {
  if (state.settings.activeMode === "account") {
    const credential = currentChatCredentialMeta();
    el.credentialHint.textContent = credential.value ? `Credential: ${credential.label}` : "Sign in first and sync the user access token";
    return;
  }
  const guest = state.settings.guest;
  el.credentialHint.textContent = `${guest.apiBase || "URL not set"} | ${guest.apiKey ? maskValue(guest.apiKey) : "Key not set"}`;
}

function syncFormFields() {
  el.accountBaseInput.value = state.settings.account.apiBase;
  el.accountUsernameInput.value = state.settings.account.username || "";
  el.guestApiBaseInput.value = state.settings.guest.apiBase;
  el.guestApiKeyInput.value = state.settings.guest.apiKey;
  el.guestModelInput.value = state.settings.guest.model;
  el.temperatureInput.value = String(activeModeSettings().temperature ?? 0.7);
  el.maxTokensInput.value = String(activeModeSettings().maxTokens ?? "");
  el.systemPromptInput.value = activeModeSettings().systemPrompt || "";
  el.streamToggle.checked = Boolean(activeModeSettings().stream);
}

function syncModelSelect() {
  const models = state.settings.activeMode === "account" ? state.models.account : state.models.guest;
  const currentModel = activeModeSettings().model || "";
  const options = models.length ? models : (currentModel ? [currentModel] : []);
  if (!options.length) {
    el.modelSelect.innerHTML = `<option value="">No models available</option>`;
    el.modelSelect.value = "";
    return;
  }
  el.modelSelect.innerHTML = options.map((model) => `<option value="${escapeHtml(model)}">${escapeHtml(model)}</option>`).join("");
  const selected = options.includes(currentModel) ? currentModel : options[0];
  activeModeSettings().model = selected;
  if (state.settings.activeMode === "guest") {
    state.settings.guest.model = selected;
    el.guestModelInput.value = selected;
  }
  el.modelSelect.value = selected;
  persistSettings();
}

function setRequestActive(active) {
  state.request.active = active;
  if (!active) state.request.controller = null;
  el.sendButton.disabled = active;
  el.stopButton.disabled = !active;
}

function setStatus(text) {
  el.statusPill.textContent = text;
}

function openSettingsPanel() {
  el.settingsPanel.classList.add("open");
  el.settingsPanel.setAttribute("aria-hidden", "false");
  el.panelBackdrop.classList.add("visible");
}

function closeSettingsPanel() {
  el.settingsPanel.classList.remove("open");
  el.settingsPanel.setAttribute("aria-hidden", "true");
  el.panelBackdrop.classList.remove("visible");
}

function toggleSidebar(open) {
  el.sidebar.classList.toggle("open", open);
  el.sidebarBackdrop.classList.toggle("visible", open);
}

function notify(message, tone = "info") {
  const toast = document.createElement("div");
  toast.className = `toast ${tone}`;
  toast.textContent = message;
  el.toastStack.appendChild(toast);
  window.setTimeout(() => toast.remove(), 2800);
}

function hydrateModeSettings() {
  renderSettingsMode();
  syncFormFields();
  renderModeSummary();
  renderAccountBanner();
}

function validateBeforeSend() {
  if (state.settings.activeMode === "account") {
    if (!state.account.user) return { ok: false, message: "Sign in to the new-api account first" };
    if (!currentChatCredential()) return { ok: false, message: "No usable credential is available for this account" };
  } else if (!state.settings.guest.apiBase || !state.settings.guest.apiKey || !activeModeSettings().model) {
    return { ok: false, message: "In Guest Mode, fill in URL, key, and model first" };
  }
  if (!activeModeSettings().model) return { ok: false, message: "Select a model first" };
  return { ok: true };
}

function ensureActiveThread(firstPrompt) {
  let thread = getActiveThread();
  if (thread) return thread;
  thread = {
    id: createId("thread"),
    title: makeThreadTitle(firstPrompt),
    createdAt: Date.now(),
    updatedAt: Date.now(),
    messages: []
  };
  state.threads.push(thread);
  state.activeThreadId = thread.id;
  return thread;
}

function deleteThread(threadId) {
  state.threads = state.threads.filter((thread) => thread.id !== threadId);
  if (state.activeThreadId === threadId) state.activeThreadId = state.threads[0]?.id || null;
  persistThreads();
  persistActiveThreadId();
  renderAll();
}

function touchThread(thread, fallbackTitle) {
  thread.updatedAt = Date.now();
  if (!thread.title || thread.title === "New Chat") thread.title = makeThreadTitle(fallbackTitle);
}

function buildChatMessages(messages) {
  return messages.map((message) => ({ role: message.role, content: message.content }));
}

function currentChatContext() {
  if (state.settings.activeMode === "account") {
    return {
      apiBase: normalizeGuestBase(`${normalizeAccountBase(state.settings.account.apiBase)}/v1`),
      apiKey: currentChatCredential(),
      model: state.settings.account.model,
      systemPrompt: state.settings.account.systemPrompt,
      temperature: state.settings.account.temperature,
      maxTokens: state.settings.account.maxTokens,
      stream: state.settings.account.stream
    };
  }
  return {
    apiBase: state.settings.guest.apiBase,
    apiKey: state.settings.guest.apiKey,
    model: state.settings.guest.model,
    systemPrompt: state.settings.guest.systemPrompt,
    temperature: state.settings.guest.temperature,
    maxTokens: state.settings.guest.maxTokens,
    stream: state.settings.guest.stream
  };
}

function currentChatCredential() {
  if (state.settings.activeMode !== "account") return state.settings.guest.apiKey;
  const selectedId = state.settings.account.selectedTokenId || USER_ACCESS_TOKEN_ID;
  if (selectedId === USER_ACCESS_TOKEN_ID) return state.account.userAccessToken;
  const token = state.account.tokens.find((item) => String(item.id ?? item.key ?? item.name) === selectedId);
  return token?.key || state.account.userAccessToken;
}

function currentChatCredentialMeta() {
  if (state.settings.activeMode !== "account") {
    return { label: "Guest Mode API Key", value: state.settings.guest.apiKey };
  }
  const selectedId = state.settings.account.selectedTokenId || USER_ACCESS_TOKEN_ID;
  if (selectedId === USER_ACCESS_TOKEN_ID) {
    return { label: "User Access Token", value: state.account.userAccessToken };
  }
  const token = state.account.tokens.find((item) => String(item.id ?? item.key ?? item.name) === selectedId);
  return { label: token ? formatTokenLabel(token) : "Personal token", value: token?.key || "" };
}

function activeModeSettings() {
  return state.settings[state.settings.activeMode];
}

function getActiveThread() {
  return state.threads.find((thread) => thread.id === state.activeThreadId) || null;
}

function findMessageById(messageId) {
  for (const thread of state.threads) {
    const message = thread.messages.find((item) => item.id === messageId);
    if (message) return message;
  }
  return null;
}

function clearAccountSession() {
  state.account.user = null;
  state.account.userAccessToken = "";
  state.account.tokens = [];
  state.models.account = [];
  state.settings.account.selectedTokenId = USER_ACCESS_TOKEN_ID;
  persistSettings();
}
async function fetchModelList(apiBase, apiKey) {
  const response = await apiFetch(apiBase, "/models", { headers: { Authorization: `Bearer ${apiKey}` } });
  if (!response.ok) throw await buildHttpError(response);
  const payload = await response.json();
  const data = unwrapResponseData(payload);
  const models = Array.isArray(data) ? data : Array.isArray(payload.data) ? payload.data : [];
  return models.map((item) => item.id || item.name || item.model).filter(Boolean).sort((a, b) => a.localeCompare(b));
}

async function apiFetch(apiBase, path, options = {}) {
  const headers = new Headers(options.headers || {});
  const target = buildApiTarget(apiBase, path);
  return fetch(target.url, {
    ...options,
    headers: mergeHeaders(headers, target.headers)
  });
}

function buildApiTarget(apiBase, path) {
  if (shouldUseGatewayProxy(apiBase)) {
    return {
      url: "/__chat_gateway_proxy",
      headers: {
        "X-Target-Base": apiBase,
        "X-Target-Path": path
      }
    };
  }
  return { url: `${apiBase}${path}`, headers: null };
}

function mergeHeaders(baseHeaders, extraHeaders) {
  const headers = new Headers(baseHeaders || {});
  if (extraHeaders) {
    for (const [key, value] of Object.entries(extraHeaders)) headers.set(key, value);
  }
  return headers;
}

function shouldUseGatewayProxy(apiBase) {
  if (state.settings.activeMode !== "guest") return false;
  try {
    const target = new URL(apiBase);
    const current = new URL(window.location.origin);
    return target.origin !== current.origin || (current.protocol === "https:" && target.protocol === "http:");
  } catch (error) {
    return true;
  }
}

async function postAccountLogin(apiBase, body) {
  const response = await fetch(`${apiBase}/api/user/login`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
  if (!response.ok) throw await buildHttpError(response);
  const payload = await safeParseJson(response);
  if (payload && payload.success === false) throw new Error(extractErrorMessage(payload, "Sign-in failed"));
  return payload;
}

function applyLoginPayload(payload) {
  const data = unwrapResponseData(payload);
  if (!data || typeof data !== "object") return;
  const token = extractTokenValue(data);
  if (typeof token === "string" && token.trim()) {
    state.account.userAccessToken = token.trim();
  }
  const user = data.user && typeof data.user === "object"
    ? data.user
    : data.account && typeof data.account === "object"
      ? data.account
      : data.profile && typeof data.profile === "object"
        ? data.profile
        : data;
  if (user && (user.id !== undefined || user.username || user.display_name)) {
    state.account.user = user;
  }
}

async function accountFetchJson(path, options = {}) {
  const apiBase = normalizeAccountBase(state.settings.account.apiBase);
  const headers = new Headers(options.headers || {});
  if (state.account.userAccessToken && !headers.has("Authorization")) {
    headers.set("Authorization", `Bearer ${state.account.userAccessToken}`);
  }
  const response = await fetch(`${apiBase}${path}`, {
    credentials: "include",
    ...options,
    headers
  });
  if (!response.ok) throw await buildHttpError(response);
  const payload = await safeParseJson(response);
  if (payload && payload.success === false) throw new Error(extractErrorMessage(payload, "Request failed"));
  return payload;
}

async function buildHttpError(response) {
  const payload = await safeParseJson(response);
  if (payload !== null) {
    return new Error(extractErrorMessage(payload, `HTTP ${response.status}`));
  }
  const { text } = await readResponseBody(response);
  return new Error(extractErrorMessage(text, text || `HTTP ${response.status}`));
}

async function safeParseJson(response) {
  try {
    return await response.clone().json();
  } catch (error) {
    try {
      const { text } = await readResponseBody(response);
      return JSON.parse(text);
    } catch (parseError) {
      return null;
    }
  }
}

async function readResponseBody(response) {
  const clone = response.clone();
  const buffer = await clone.arrayBuffer();
  const contentType = clone.headers.get("Content-Type") || "";
  const charset = extractCharset(contentType) || "utf-8";
  const primary = decodeResponseText(buffer, charset);
  if (!primary.includes("\uFFFD")) return { text: primary, buffer };
  const fallbackEncoding = charset.toLowerCase() === "gbk" ? "utf-8" : "gbk";
  const fallback = decodeResponseText(buffer, fallbackEncoding);
  if (fallback && (!fallback.includes("\uFFFD") || fallback.replace(/\uFFFD/g, "").length >= primary.replace(/\uFFFD/g, "").length)) {
    return { text: fallback, buffer };
  }
  return { text: primary, buffer };
}

function extractCharset(contentType) {
  const match = /charset=([^;]+)/i.exec(contentType || "");
  return match ? match[1].trim().toLowerCase() : "";
}

function decodeResponseText(buffer, encoding) {
  try {
    return new TextDecoder(encoding, { fatal: false }).decode(buffer);
  } catch (error) {
    return new TextDecoder("utf-8").decode(buffer);
  }
}

function renderRichText(content) {
  const blocks = [];
  const codePattern = /```([\w-]+)?\n?([\s\S]*?)```/g;
  let lastIndex = 0;
  let match;
  while ((match = codePattern.exec(content)) !== null) {
    const textPart = content.slice(lastIndex, match.index);
    if (textPart.trim()) blocks.push(renderTextBlocks(textPart));
    const lang = match[1] ? `<div class="eyebrow">${escapeHtml(match[1])}</div>` : "";
    blocks.push(`<pre>${lang}<code>${escapeHtml(match[2].trim())}</code></pre>`);
    lastIndex = codePattern.lastIndex;
  }
  const tail = content.slice(lastIndex);
  if (tail.trim()) blocks.push(renderTextBlocks(tail));
  return blocks.join("") || '<p class="message-empty">No content</p>';
}

function renderTextBlocks(text) {
  return text.trim().split(/\n{2,}/).map((block) => {
    const lines = block.trim().split("\n");
    if (lines.every((line) => /^[-*]\s+/.test(line))) {
      return `<ul>${lines.map((line) => `<li>${renderInlineText(line.replace(/^[-*]\s+/, ""))}</li>`).join("")}</ul>`;
    }
    if (lines.every((line) => /^\d+\.\s+/.test(line))) {
      return `<ol>${lines.map((line) => `<li>${renderInlineText(line.replace(/^\d+\.\s+/, ""))}</li>`).join("")}</ol>`;
    }
    return `<p>${renderInlineText(block).replace(/\n/g, "<br>")}</p>`;
  }).join("");
}

function renderInlineText(text) {
  return escapeHtml(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[\s(])(https?:\/\/[^\s<]+)/g, '$1<a href="$2" target="_blank" rel="noreferrer">$2</a>');
}

function extractAssistantText(payload) {
  const data = unwrapResponseData(payload) || payload;
  return firstNonEmptyText([
    data?.output_text,
    data?.choices?.[0]?.message?.content,
    data?.choices?.[0]?.message,
    data?.choices?.[0]?.delta?.content,
    data?.output,
    data?.content,
    data?.summary,
    data?.response
  ]);
}

function extractStreamText(payload) {
  const data = unwrapResponseData(payload) || payload;
  if (data && typeof data === "object") {
    if (typeof data.delta === "string" && data.type && data.type.includes("output_text.delta")) return data.delta;
    if (typeof data.text === "string" && data.type && data.type.includes("output_text.delta")) return data.text;
    if (typeof data.delta === "string" && data.type && data.type.includes("text_delta")) return data.delta;
  }
  return firstNonEmptyText([
    data?.delta,
    data?.choices?.[0]?.delta?.content,
    data?.choices?.[0]?.message?.content,
    data?.output?.[0]?.content?.[0]?.text_delta,
    data?.output?.[0]?.content,
    data?.content,
    data?.response,
    data?.item,
    data?.output_text
  ]);
}
function firstNonEmptyText(candidates) {
  for (const candidate of candidates) {
    const text = extractTextValue(candidate).trim();
    if (text) return text;
  }
  return "";
}
function extractTextValue(node) {
  if (node === null || node === undefined) return "";
  if (typeof node === "string") return node;
  if (typeof node === "number" || typeof node === "boolean") return String(node);
  if (Array.isArray(node)) return node.map((item) => extractTextValue(item)).filter(Boolean).join("");
  if (typeof node !== "object") return "";

  if (typeof node.delta === "string") return node.delta;
  if (typeof node.text === "string") return node.text;
  if (node.text && typeof node.text === "object") {
    const nestedText = extractTextValue(node.text.value ?? node.text.text ?? node.text.content);
    if (nestedText) return nestedText;
  }
  if (typeof node.value === "string") return node.value;

  const knownContainers = [
    node.output_text,
    node.content,
    node.contents,
    node.output,
    node.message,
    node.messages,
    node.item,
    node.items,
    node.summary,
    node.response
  ];
  for (const value of knownContainers) {
    const text = extractTextValue(value);
    if (text) return text;
  }

  return "";
}
function unwrapResponseData(payload) {
  if (!payload || typeof payload !== "object") return payload;
  return payload.data !== undefined ? payload.data : payload;
}

function normalizeTokenList(data) {
  if (Array.isArray(data)) return data;
  if (Array.isArray(data?.items)) return data.items;
  if (Array.isArray(data?.list)) return data.list;
  return [];
}

function extractErrorMessage(payload, fallback) {
  if (!payload) return fallback || "Request failed";
  if (typeof payload === "string") return payload;
  if (payload.error && typeof payload.error === "object") {
    const nested = payload.error.message || payload.error.msg || payload.error.error;
    if (nested) return coerceMessage(nested, fallback);
  }
  const candidate = payload.message ?? payload.msg ?? payload.error;
  return coerceMessage(candidate, fallback);
}

function coerceMessage(value, fallback) {
  if (typeof value === "string") return value;
  if (value !== undefined && value !== null) {
    try {
      return JSON.stringify(value);
    } catch (error) {
      return String(value);
    }
  }
  return fallback || "Request failed";
}

function extractTokenValue(data) {
  const direct = data.access_token || data.accessToken || data.token || data.key;
  if (typeof direct === "string" && direct.trim()) return direct.trim();
  const container = data.token || data.access || data.auth || data.credential;
  if (container && typeof container === "object") {
    const nested = container.access_token || container.accessToken || container.token || container.key || container.value;
    if (typeof nested === "string" && nested.trim()) return nested.trim();
  }
  return "";
}

function createMessage(role, content) {
  return { id: createId("msg"), role, content };
}

function createId(prefix) {
  return `${prefix}_${Date.now()}_${Math.random().toString(16).slice(2, 10)}`;
}

function makeThreadTitle(text) {
  const normalized = (text || "").replace(/\s+/g, " ").trim();
  return normalized ? normalized.slice(0, 28) : "New Chat";
}

function autoResizeTextarea(textarea) {
  textarea.style.height = "auto";
  textarea.style.height = `${Math.min(textarea.scrollHeight, 240)}px`;
}

function scrollMessagesToBottom(force) {
  const threshold = 120;
  const nearBottom = el.messageSurface.scrollHeight - el.messageSurface.scrollTop - el.messageSurface.clientHeight < threshold;
  if (force || nearBottom) {
    el.messageSurface.scrollTo({ top: el.messageSurface.scrollHeight, behavior: force ? "smooth" : "auto" });
  }
}

function formatQuota(value) {
  if (value === null || value === undefined || value === "") return "Unknown";
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return String(value);
  return numeric.toLocaleString("zh-CN");
}

function formatDate(timestamp) {
  if (!timestamp) return "";
  return new Intl.DateTimeFormat("zh-CN", {
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  }).format(timestamp);
}

function formatTokenLabel(token) {
  const name = token.name || token.id || "Unnamed token";
  const remain = token.remain_quota ?? token.remainQuota;
  return remain !== undefined ? `${name} | Balance ${formatQuota(remain)}` : String(name);
}

function maskValue(value) {
  if (!value) return "";
  if (value.length <= 8) return `${value.slice(0, 2)}***`;
  return `${value.slice(0, 4)}...${value.slice(-4)}`;
}

function defaultGuestBase() {
  return `${window.location.origin}/v1`;
}

function normalizeGuestBase(value) {
  const raw = (value || "").trim();
  if (!raw) return defaultGuestBase();
  try {
    const url = new URL(raw);
    url.hash = "";
    url.search = "";
    url.pathname = url.pathname === "/" ? "/v1" : url.pathname.replace(/\/+$/, "");
    return url.toString().replace(/\/$/, "");
  } catch (error) {
    return raw.replace(/\/+$/, "");
  }
}

function normalizeAccountBase(value) {
  const raw = (value || "").trim();
  if (!raw) return window.location.origin;
  try {
    const url = new URL(raw);
    url.hash = "";
    url.search = "";
    url.pathname = "";
    return url.toString().replace(/\/$/, "");
  } catch (error) {
    return raw.replace(/\/+$/, "");
  }
}

function sanitizeTemperature(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return 0.7;
  return Math.max(0, Math.min(2, numeric));
}

function sanitizeMaxTokens(value) {
  const normalized = String(value || "").trim();
  if (!normalized) return "";
  const numeric = Number(normalized);
  if (!Number.isInteger(numeric) || numeric <= 0) return "";
  return String(numeric);
}

function clampActiveThread() {
  if (state.activeThreadId && !state.threads.some((thread) => thread.id === state.activeThreadId)) {
    state.activeThreadId = state.threads[0]?.id || null;
  }
}

function loadSettings() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEYS.settings) || "null");
    if (!saved || typeof saved !== "object") return JSON.parse(JSON.stringify(defaultSettings));
    return {
      activeMode: saved.activeMode === "account" ? "account" : "guest",
      guest: { ...defaultSettings.guest, ...(saved.guest || {}) },
      account: { ...defaultSettings.account, ...(saved.account || {}) }
    };
  } catch (error) {
    return JSON.parse(JSON.stringify(defaultSettings));
  }
}

function loadThreads() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEYS.threads) || "[]");
    return Array.isArray(saved) ? saved : [];
  } catch (error) {
    return [];
  }
}

function persistSettings() {
  localStorage.setItem(STORAGE_KEYS.settings, JSON.stringify(state.settings));
}

function persistThreads() {
  localStorage.setItem(STORAGE_KEYS.threads, JSON.stringify(state.threads));
  renderThreadSidebar();
}

function persistActiveThreadId() {
  if (state.activeThreadId) {
    localStorage.setItem(STORAGE_KEYS.activeThreadId, state.activeThreadId);
  } else {
    localStorage.removeItem(STORAGE_KEYS.activeThreadId);
  }
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}



