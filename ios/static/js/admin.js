// ───────────── In-app detection ─────────────
const isInApp = new URLSearchParams(location.search).get("inapp") === "1";

// ───────────── UI Elements ─────────────
const scanBtn = document.getElementById("scanBtn");
const connectBtn = document.getElementById("connectBtn");
const disconnectBtn = document.getElementById("disconnectBtn");
const deviceSelect = document.getElementById("deviceSelect");
const logDiv = document.getElementById("log");
const sessionsList = document.getElementById("sessionsList");
const loadMoreBtn = document.getElementById("loadMoreBtn");
const refreshBtn = document.getElementById("refreshSessionsBtn");
const titleInput = document.getElementById("titleInput");
const setTitleBtn = document.getElementById("setTitleBtn");

let offset = 0;
const PAGE_SIZE = 20;
let currentConnectedDevice = null;

// ───────────── Logging Helper ─────────────
function log(msg) {
  const t = new Date().toLocaleTimeString();
  logDiv.textContent += `[${t}] ${msg}\n`;
  logDiv.scrollTop = logDiv.scrollHeight;
}

// ───────────── WebSocket Setup ─────────────
const wsUrl =
  (location.protocol === "https:" ? "wss:" : "ws:") + "//" + location.host + "/ws";
const ws = new WebSocket(wsUrl);

ws.onopen = () => log("🔗 WebSocket connected");
ws.onclose = () => log("❌ WebSocket disconnected");

// ───────────── Handle Broadcast Messages ─────────────
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);

  switch (msg.type) {
    case "SERVER_HELLO": {
      const prev = sessionStorage.getItem("serverGen");
      if (prev && prev !== String(msg.serverGen)) {
        sessionStorage.setItem("serverGen", String(msg.serverGen));
        location.reload();
        return;
      }
      sessionStorage.setItem("serverGen", String(msg.serverGen));
      break;
    }

    case "RELOAD":
      location.reload();
      return;

    case "SETTINGS_UPDATE":
      applySettings(msg);
      break;

    case "LENS_CHANGED":
      updateLensButtons(msg.lensId);
      break;

    case "DEVICE_CONNECTED": {
      if (currentConnectedDevice && currentConnectedDevice === msg.addr) return;

      const name = msg.name || "Unknown";
      const model = msg.model ? `${msg.model}` : "Unknown Model";
      const apiVer = msg.api_version && msg.api_version !== "?"
        ? `, API v${msg.api_version}`
        : "";

      setTimeout(() => {
        currentConnectedDevice = msg.addr;
        log(`✅ Device connected: ${name} (${model}${apiVer})`);
        localStorage.setItem("lastDeviceAddr", msg.addr);
        updateDeviceDropdown(msg.addr, name);
      }, 500);
      break;
    }

    case "DEVICE_DISCONNECTED": {
      const name = msg.name || "Unknown";
      const model = msg.model ? `${msg.model}` : "Unknown Model";
      const apiVer = msg.api_version && msg.api_version !== "?"
        ? `, API v${msg.api_version}`
        : "";

      setTimeout(() => {
        log(`⚠️ Device disconnected: ${name} (${model}${apiVer})`);
        currentConnectedDevice = null;
        localStorage.removeItem("lastDeviceAddr");
      }, 500);
      break;
    }

    case "WATCHDOG": {
      const name = msg.name || "Unknown";
      const model = msg.model ? ` - ${msg.model}` : "";
      const apiVer = msg.api_version && msg.api_version !== "?"
        ? ` — API v${msg.api_version}`
        : "";
      if (msg.status === "reconnected")
        log(`🟢 Watchdog reconnected: (${msg.addr}) ${name}${model}${apiVer}`);
      else if (msg.status === "disconnected")
        log(`🟡 Watchdog reconnecting: (${msg.addr}) ${name}${model}${apiVer}`);
      else log(`⚠️ Watchdog: ${msg.status}`);
      break;
    }

    case "SESSION_STARTED":
      log(`🏁 Session started (${msg.sess_id || "no id"})`);
      break;

    case "SESSION_SUSPENDED":
      log("⏸️ Session suspended (STANDBY)");
      break;

    case "SESSION_RESUMED":
      log("▶️ Session resumed");
      break;

    case "SESSION_STOPPED":
      log("⏹️ Session stopped — updating session list...");
      setTimeout(async () => {
        try {
          offset = 0;
          await loadSessions(false);
        } catch (e) {
          log("⚠️ Failed to refresh sessions after stop: " + e.message);
        }
      }, 1000);
      break;

    case "SHOT_DETECTED":
      log(`#${msg.num} - ${msg.time.toFixed(2)}s`);
      break;

    case "TITLE_UPDATE":
      if (msg.title && titleInput.value.trim() !== msg.title) {
        titleInput.value = msg.title;
        log(`📝 Title updated: ${msg.title}`);
      }
      break;

    default:
      break;
  }
};

// ───────────── Device Controls ─────────────
async function scanDevices() {
  log("📡 Scanning for compatible devices...");
  const res = await fetch("/devices");
  const data = await res.json();
  deviceSelect.innerHTML = "";
  data.devices.forEach((d) => {
    const opt = document.createElement("option");
    opt.value = d.address;
    opt.textContent = `${d.name || "Unknown"} (${d.address})`;
    opt.dataset.name = d.name || "";
    deviceSelect.appendChild(opt);
  });
  log(`Found ${data.devices.length} device(s).`);
}

async function connectDevice() {
  const addr = deviceSelect.value;
  const selectedOption = deviceSelect.options[deviceSelect.selectedIndex];
  const name = selectedOption ? selectedOption.dataset.name : null;

  if (!addr) {
    log("⚠️ No device selected for connection.");
    return;
  }

  if (currentConnectedDevice && currentConnectedDevice === addr) {
    log("ℹ️ Selected device is already connected.");
    return;
  }

  try {
    const res = await fetch("/status");
    const data = await res.json();
    if (data.connected && data.devices.length > 0) {
      const connected = data.devices.find((x) => x.connected);
      if (connected) {
        log("⚠️ Disconnect from current device first!");
        return;
      }
    }
  } catch (e) {
    log("⚠️ Could not verify connection status: " + e.message);
  }

  log(`Connecting to ${addr}...`);
  localStorage.setItem("lastDeviceAddr", addr);

  await fetch("/connect", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ address: addr, name }),
  });
}

async function disconnectDevice() {
  let addr = deviceSelect.value;
  if (!addr) {
    addr = localStorage.getItem("lastDeviceAddr");
    if (!addr) {
      log("⚠️ No device selected or stored to disconnect.");
      return;
    }
  }

  log(`Disconnecting from ${addr}...`);
  await fetch("/disconnect", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ address: addr }),
  });

  currentConnectedDevice = null;
  localStorage.removeItem("lastDeviceAddr");
}

// ───────────── Session Listing ─────────────
async function loadSessions(append = false) {
  if (!append) sessionsList.innerHTML = "";

  const res = await fetch(`/sessions?offset=${offset}&limit=${PAGE_SIZE}`);
  const j = await res.json();
  const list = j.sessions || [];

  for (const s of list) {
    const sessId = s.sess_id;
    const ts = Number(sessId);
    const date = new Date(ts * 1000);
    const formatted = `${date.getUTCFullYear()}-${String(
      date.getUTCMonth() + 1
    ).padStart(2, "0")}-${String(date.getUTCDate()).padStart(
      2,
      "0"
    )} ${String(date.getUTCHours()).padStart(2, "0")}:${String(
      date.getUTCMinutes()
    ).padStart(2, "0")}:${String(date.getUTCSeconds()).padStart(2, "0")}`;

    const shots = s.total_shots || 0;
    const best = s.best_split ? s.best_split.toFixed(2) : "0.00";
    const totalTime = s.total_time ? s.total_time.toFixed(2) : "—";

    const card = document.createElement("div");
    card.className = "session-card";
    card.dataset.sessId = sessId;

    card.innerHTML = `
      <div class="session-main">
        <div class="session-left">
          <div class="session-title">Session ${sessId} — ${formatted}</div>
          <div class="session-meta">
            Shots: <b>${shots}</b> — Time: <b>${totalTime}</b>s — Best Split: <b>${best}</b>
          </div>
        </div>
        <div class="session-actions">
          ${isInApp ? "" : `<a class="btn btn-small" href="/download/${sessId}">⬇ Download CSV</a>`}
        </div>
      </div>
    `;

    card.addEventListener("click", () => toggleSessionDetails(card, sessId));
    sessionsList.appendChild(card);
  }

  offset += list.length;
  loadMoreBtn.style.display = list.length === PAGE_SIZE ? "inline-block" : "none";
}

// ───────────── Expand/Collapse Session Details ─────────────
async function toggleSessionDetails(card, sessId) {
  document.querySelectorAll(".session-card.expanded").forEach((c) => {
    if (c !== card) {
      c.classList.remove("expanded");
      const details = c.querySelector(".session-extra");
      if (details) details.remove();
    }
  });

  if (card.classList.contains("expanded")) {
    card.classList.remove("expanded");
    const details = card.querySelector(".session-extra");
    if (details) details.remove();
    return;
  }

  const res = await fetch(`/download/${sessId}`);
  const csvText = await res.text();
  const lines = csvText.split("\n").slice(1).filter((l) => l.trim());
  const shots = lines
    .map((l) => {
      const p = l.split(",");
      if (p[0] !== "SHOT_DETECTED") return null;
      return {
        num: p[1],
        time: parseFloat(p[2]).toFixed(2).replace(/\.?0+$/, ""),
        split: p[3]
          ? parseFloat(p[3]).toFixed(2).replace(/\.?0+$/, "")
          : "",
      };
    })
    .filter(Boolean);

  const shotHTML = shots.length
    ? shots
        .map(
          (s) =>
            `<span class="shot-line">#${s.num} — Time: ${s.time}${
              s.split ? ` [Split: ${s.split}]` : ""
            }</span>`
        )
        .join(" ")
    : "<i>No shot data available</i>";

  const extra = document.createElement("div");
  extra.className = "session-extra";
  extra.innerHTML = `
    <hr class="session-divider">
    <div class="shot-container">${shotHTML}</div>
  `;

  card.appendChild(extra);
  card.classList.add("expanded");
}

// ───────────── Title Management ─────────────
setTitleBtn.addEventListener("click", async () => {
  const newTitle = titleInput.value.trim();
  if (!newTitle) return;
  try {
    const res = await fetch("/set_title", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: newTitle }),
    });
    if (res.ok) log(`✅ Title updated: ${newTitle}`);
    else log("⚠️ Failed to update title");
  } catch (e) {
    log("Error setting title: " + e.message);
  }
});

// ───────────── Settings ─────────────
function applySettings(d) {
  if (d.fps) {
    document.querySelectorAll(".fps-btn").forEach((b) => {
      b.classList.toggle("active", parseInt(b.dataset.fps) === d.fps);
    });
    const input = document.getElementById("syncDelayInput");
    if (input && typeof d.avSyncDelayMs === "number") input.value = d.avSyncDelayMs;
    const avDelayInput = document.getElementById("avDelayInput");
    if (avDelayInput && typeof d.avDelayMs === "number") avDelayInput.value = d.avDelayMs;
    const overlayDelayInput = document.getElementById("overlayDelayInput");
    if (overlayDelayInput && typeof d.overlayDelayMs === "number") overlayDelayInput.value = d.overlayDelayMs;
  }
  if (d.currentLensId) updateLensButtons(d.currentLensId);
  const resSelect = document.getElementById("streamResolutionSelect");
  if (resSelect && d.streamResolution) resSelect.value = d.streamResolution;
  const qualitySelect = document.getElementById("streamQualitySelect");
  if (qualitySelect && d.streamQuality) qualitySelect.value = d.streamQuality;
}

async function loadSettings() {
  try {
    const res = await fetch("/get_settings");
    if (!res.ok) return;
    const d = await res.json();
    applySettings(d);
  } catch (e) { /* non-iOS server */ }
}

document.getElementById("saveSettingsBtn")?.addEventListener("click", async () => {
  const fps = parseInt(document.querySelector(".fps-btn.active")?.dataset.fps || "30");
  const delay = parseInt(document.getElementById("syncDelayInput")?.value || "300");
  const avDelay = parseInt(document.getElementById("avDelayInput")?.value || "0");
  const overlayDelay = parseInt(document.getElementById("overlayDelayInput")?.value || "200");
  const streamResolution = document.getElementById("streamResolutionSelect")?.value || "720p";
  const streamQuality = document.getElementById("streamQualitySelect")?.value || "normal";
  try {
    const res = await fetch("/save_settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ fps, avSyncDelayMs: delay, avDelayMs: avDelay, overlayDelayMs: overlayDelay, streamResolution, streamQuality }),
    });
    if (res.ok) log(`✅ Settings saved (${fps} fps, ${delay}ms audio buffer, ${avDelay}ms A/V delay, ${overlayDelay}ms overlay, stream ${streamResolution}, quality ${streamQuality}) — reloading clients in 1s…`);
    else log("⚠️ Failed to save settings");
  } catch (e) {
    log("Error saving settings: " + e.message);
  }
});

document.querySelectorAll(".fps-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".fps-btn").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
  });
});

document.getElementById("settingsToggleBtn")?.addEventListener("click", () => {
  const sec = document.getElementById("serverSettingsSection");
  if (!sec) return;
  const visible = sec.style.display !== "none";
  sec.style.display = visible ? "none" : "block";
});

// ───────────── Lens Panel ─────────────
async function loadLenses() {
  try {
    const res = await fetch("/get_lenses");
    if (!res.ok) return;
    const d = await res.json();
    const container = document.getElementById("lensButtons");
    if (!container) return;
    container.innerHTML = "";
    d.lenses.forEach((l) => {
      const btn = document.createElement("button");
      btn.className = "lens-btn" + (l.id === d.current ? " active" : "");
      btn.dataset.lensId = l.id;
      btn.textContent = l.label;
      btn.addEventListener("click", async () => {
        await fetch("/set_lens", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id: l.id }),
        });
      });
      container.appendChild(btn);
    });
    document.getElementById("lensPanel").style.display =
      d.lenses.length > 1 ? "flex" : "none";
  } catch (e) {
    document.getElementById("lensPanel").style.display = "none";
  }
}

function updateLensButtons(activeLensId) {
  document.querySelectorAll(".lens-btn").forEach((b) => {
    b.classList.toggle("active", b.dataset.lensId === activeLensId);
  });
}

// ───────────── Clear All Sessions Modal ─────────────
document.getElementById("clearSessionsBtn")?.addEventListener("click", () => {
  const hasSessions = sessionsList && sessionsList.children.length > 0;
  if (!hasSessions) {
    log("🗑️ No sessions to clear.");
    return;
  }
  document.getElementById("clearModal").style.display = "flex";
});

document.getElementById("clearModal")?.addEventListener("click", (e) => {
  if (e.target === e.currentTarget) e.currentTarget.style.display = "none";
});

document.getElementById("modalCancelBtn")?.addEventListener("click", () => {
  document.getElementById("clearModal").style.display = "none";
});

document.getElementById("modalConfirmBtn")?.addEventListener("click", async () => {
  document.getElementById("clearModal").style.display = "none";
  try {
    const res = await fetch("/clear_sessions", { method: "POST" });
    if (res.ok) {
      log("🗑️ All sessions deleted.");
      sessionsList.innerHTML = "";
      offset = 0;
      loadMoreBtn.style.display = "none";
    } else {
      log(`⚠️ Failed to clear sessions: HTTP ${res.status}`);
    }
  } catch (err) {
    log("❌ Error clearing sessions: " + (err?.message || err));
  }
});

// ───────────── Auto-Fill Title & Connection Status ─────────────
fetch("/get_title")
  .then((r) => r.json())
  .then((d) => {
    if (d.title) titleInput.value = d.title;
  });

fetch("/status")
  .then((r) => r.json())
  .then((data) => {
    if (data.connected && data.devices.length > 0) {
      const d = data.devices.find((x) => x.connected);
      currentConnectedDevice = d.address;
      const apiVer = d.api_version && d.api_version !== "?"
        ? ` — API v${d.api_version}`
        : "";
      log(`✅ Device connected: ${d.name} (${d.address})${apiVer}`);
      localStorage.setItem("lastDeviceAddr", d.address);
      updateDeviceDropdown(d.address, d.name);
    } else {
      log("ℹ️ No device currently connected.");
    }
  })
  .catch((e) => log("⚠️ Could not fetch connection status: " + e.message));

// ───────────── Helper: Update Dropdown ─────────────
function updateDeviceDropdown(addr, name = null) {
  if (!addr) return;
  deviceSelect.innerHTML = "";
  const opt = document.createElement("option");
  opt.value = addr;
  opt.textContent = `${name || "Connected Device"} (${addr})`;
  deviceSelect.appendChild(opt);
  deviceSelect.value = addr;
}

// ───────────── Restore Last Connected Device ─────────────
const lastAddr = localStorage.getItem("lastDeviceAddr");
if (lastAddr) {
  updateDeviceDropdown(lastAddr, "Last Connected");
  log(`💾 Restored last connected device: ${lastAddr}`);
}

// ───────────── Buttons ─────────────
scanBtn.addEventListener("click", scanDevices);
connectBtn.addEventListener("click", connectDevice);
disconnectBtn.addEventListener("click", disconnectDevice);
refreshBtn.addEventListener("click", () => {
  offset = 0;
  loadSessions(false);
  log("Session list refreshed.");
});
loadMoreBtn.addEventListener("click", () => loadSessions(true));

// ───────────── Initialize ─────────────
loadSettings();
loadLenses();
loadSessions();
