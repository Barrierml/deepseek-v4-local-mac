const $ = (id) => document.getElementById(id);

let lastTokPerSecond = null;
let conversation = [];

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

async function refreshStats() {
  try {
    renderStats(await fetchJson("/api/stats"));
  } catch (error) {
    $("status").textContent = "Offline";
    $("status").classList.remove("ready");
  }
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
    const result = await fetchJson("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: conversation,
        max_tokens: Number($("maxTokens").value || 256),
        reasoning_effort: $("reasoning").value,
      }),
    });
    lastTokPerSecond = result.tok_per_s;
    setText("tokps", result.tok_per_s.toFixed(2));
    setText("tokens", result.tokens);
    setText("latency", `${result.elapsed_s.toFixed(2)} s`);
    setText("cachedTokens", result.cached_tokens);
    setText("cacheWriteTokens", result.cache_write_tokens);
    conversation.push({ role: "assistant", content: result.content });
    renderConversation();
    renderStats(result.stats);
  } catch (error) {
    conversation.push({ role: "assistant", content: `Error: ${error.message}` });
    renderConversation();
  } finally {
    button.disabled = false;
    await refreshStats();
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
refreshStats();
setInterval(refreshStats, 2000);
