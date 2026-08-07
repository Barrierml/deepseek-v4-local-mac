const $ = (id) => document.getElementById(id);

let lastTokPerSecond = null;

function setText(id, value) {
  $(id).textContent = value == null || value === "" ? "-" : String(value);
}

function fmtGiB(value) {
  return value == null ? "-" : `${Number(value).toFixed(2)} GiB`;
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
  button.disabled = true;
  $("output").textContent = "";
  $("lastRun").textContent = "Running";
  const started = new Date();
  try {
    const result = await fetchJson("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        prompt: $("prompt").value,
        max_tokens: Number($("maxTokens").value || 256),
        reasoning_effort: $("reasoning").value,
      }),
    });
    lastTokPerSecond = result.tok_per_s;
    setText("tokps", result.tok_per_s.toFixed(2));
    setText("tokens", result.tokens);
    setText("latency", `${result.elapsed_s.toFixed(2)} s`);
    $("output").textContent = result.content;
    $("lastRun").textContent = started.toLocaleTimeString();
    renderStats(result.stats);
  } catch (error) {
    $("output").textContent = error.message;
    $("lastRun").textContent = "Failed";
  } finally {
    button.disabled = false;
    await refreshStats();
  }
}

$("chatForm").addEventListener("submit", runPrompt);
refreshStats();
setInterval(refreshStats, 2000);
