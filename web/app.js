const $ = (id) => document.getElementById(id);

let lastTokPerSecond = null;
let conversation = [];
let statusSource = null;
let previousExpertStates = new Map();

function setText(id, value) {
  $(id).textContent = value == null || value === "" ? "-" : String(value);
}

function fmtGiB(value) {
  return value == null ? "-" : `${Number(value).toFixed(2)} GiB`;
}

function renderConversation() {
  const root = $("messages");
  root.innerHTML = "";
  if (conversation.length === 0) {
    const empty = document.createElement("div");
    empty.className = "emptyState";
    empty.textContent = "No messages yet";
    root.appendChild(empty);
    return;
  }
  for (const message of conversation) {
    const row = document.createElement("article");
    row.className = `message ${message.role}`;
    const role = document.createElement("div");
    role.className = "role";
    role.textContent = message.role === "assistant" ? "Assistant" : "You";
    const content = document.createElement("div");
    content.className = "messageText";
    content.textContent = message.content;
    row.append(role, content);
    root.appendChild(row);
  }
  root.scrollTop = root.scrollHeight;
}

async function fetchJson(url, options) {
  const response = await fetch(url, options);
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || response.statusText);
  return body;
}

function appendAssistantDelta(index, delta) {
  conversation[index].content += delta;
  renderConversation();
}

function setStatusOffline(label = "Offline") {
  $("status").textContent = label;
  $("status").classList.remove("ready");
}

function renderStats(stats) {
  $("status").textContent = stats.server.pid ? "Ready" : "Offline";
  $("status").classList.toggle("ready", Boolean(stats.server.pid));
  setText("pid", stats.server.pid);
  setText("rss", fmtGiB(stats.server.rss_gib));
  setText("cpu", `${Number(stats.server.cpu_percent || 0).toFixed(1)}%`);
  setText("freeMem", stats.system.memory_free_percent == null ? "-" : `${stats.system.memory_free_percent}%`);
  setText("swap", fmtGiB(stats.system.swap.used_gib));
  setText("disk", fmtGiB(stats.system.disk.available_gib));
  setText("expertBudget", fmtGiB(stats.model.expert_budget_gib));
  setText("ctx", stats.model.ctx);
  $("endpoint").textContent = `${stats.model.base_url.replace("http://", "")} · SSD streaming`;
  if (lastTokPerSecond == null) setText("tokps", "-");
}

function renderExpertActivity(activity) {
  if (!activity) return;
  setText("activeRequests", activity.active_requests);
  setText("lastCacheRead", activity.last_cached_tokens);
  setText("lastCacheWrite", activity.last_cache_write_tokens);
  setText("cachePressure", `${Math.round(Number(activity.pressure || 0) * 100)}%`);
  $("activityMode").textContent = activity.exact_events ? "Exact" : "Observed";
  const root = $("expertNodes");
  root.innerHTML = "";
  const nextStates = new Map();
  for (const node of activity.nodes || []) {
    const previous = previousExpertStates.get(node.id) || "idle";
    let transition = "";
    if (previous === "idle" && node.state !== "idle") transition = "enter";
    if (previous !== "idle" && node.state === "idle") transition = "leave";
    nextStates.set(node.id, node.state);
    const item = document.createElement("div");
    item.className = `expertNode ${node.state} ${transition}`.trim();
    item.title = `${node.label}: ${transition ? `${transition} ` : ""}${node.state}`;
    item.style.setProperty("--strength", Number(node.strength || 0));
    root.appendChild(item);
  }
  previousExpertStates = nextStates;
}

function renderStatusEvent(event) {
  if (!event || event.type !== "status") return;
  renderStats(event.stats);
  renderExpertActivity(event.expert_cache);
}

async function refreshStats() {
  try {
    renderStats(await fetchJson("/api/stats"));
  } catch (error) {
    setStatusOffline();
  }
}

function connectStatusStream() {
  if (!window.EventSource) {
    refreshStats();
    setInterval(refreshStats, 2000);
    return;
  }
  statusSource = new EventSource("/api/status-stream");
  statusSource.onmessage = (message) => {
    try {
      renderStatusEvent(JSON.parse(message.data));
    } catch (error) {
      setStatusOffline("Status error");
    }
  };
  statusSource.onerror = () => {
    setStatusOffline("Reconnecting");
  };
}

async function runPrompt(event) {
  event.preventDefault();
  const button = $("sendButton");
  const prompt = $("prompt").value.trim();
  if (!prompt) return;
  button.disabled = true;
  conversation.push({ role: "user", content: prompt });
  renderConversation();
  $("prompt").value = "";
  const started = new Date();
  try {
    const requestMessages = conversation.slice();
    const assistantIndex = conversation.length;
    conversation.push({ role: "assistant", content: "" });
    renderConversation();
    const response = await fetch("/api/chat-stream", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: requestMessages,
        max_tokens: Number($("maxTokens").value || 256),
        reasoning_effort: $("reasoning").value,
      }),
    });
    if (!response.ok || !response.body) {
      const body = await response.json().catch(() => ({}));
      throw new Error(body.error || response.statusText);
    }
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let finalEvent = null;
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        const event = JSON.parse(line);
        if (event.type === "delta") {
          appendAssistantDelta(assistantIndex, event.content);
        } else if (event.type === "done") {
          finalEvent = event;
        } else if (event.type === "error") {
          throw new Error(event.error || "stream failed");
        }
      }
    }
    if (buffer.trim()) {
      const event = JSON.parse(buffer);
      if (event.type === "delta") appendAssistantDelta(assistantIndex, event.content);
      else if (event.type === "done") finalEvent = event;
      else if (event.type === "error") throw new Error(event.error || "stream failed");
    }
    const result = finalEvent || { tok_per_s: 0, tokens: 0, elapsed_s: 0, cached_tokens: 0, cache_write_tokens: 0 };
    lastTokPerSecond = result.tok_per_s;
    setText("tokps", result.tok_per_s.toFixed(2));
    setText("tokens", result.tokens);
    setText("latency", `${result.elapsed_s.toFixed(2)} s`);
    setText("cachedTokens", result.cached_tokens);
    setText("cacheWriteTokens", result.cache_write_tokens);
    if (result.stats) renderStats(result.stats);
  } catch (error) {
    if (conversation[conversation.length - 1]?.role === "assistant" &&
        conversation[conversation.length - 1].content === "") {
      conversation[conversation.length - 1].content = `Error: ${error.message}`;
    } else {
      conversation.push({ role: "assistant", content: `Error: ${error.message}` });
    }
    renderConversation();
  } finally {
    button.disabled = false;
  }
}

$("chatForm").addEventListener("submit", runPrompt);
$("resetButton").addEventListener("click", () => {
  conversation = [];
  lastTokPerSecond = null;
  setText("tokps", "-");
  setText("tokens", "-");
  setText("latency", "-");
  setText("cachedTokens", "-");
  setText("cacheWriteTokens", "-");
  renderConversation();
});
renderConversation();
connectStatusStream();
