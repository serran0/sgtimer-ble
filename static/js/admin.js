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
    case "DEVICE_CONNECTED": {
      if (currentConnectedDevice && currentConnectedDevice === msg.addr) return;

      const name = msg.name || "Unknown";
      const model = msg.model ? ` - ${msg.model}` : "";
      setTimeout(() => {
        currentConnectedDevice = msg.addr;
        const apiVer = msg.api_version ? ` — API v${msg.api_version}` : "";
        log(`✅ Device connected: ${name}${model} (${msg.addr})${apiVer}`);
        localStorage.setItem("lastDeviceAddr", msg.addr);
        updateDeviceDropdown(msg.addr, name);
      }, 500);
      break;
    }

    case "DEVICE_DISCONNECTED": {
      const name = msg.name || "Unknown";
      const model = msg.model ? ` - ${msg.model}` : "";
      setTimeout(() => {
        const apiVer = msg.api_version ? ` — API v${msg.api_version}` : "";
        log(`⚠️ Device disconnected: ${name}${model} (${msg.addr})${apiVer}`);
        currentConnectedDevice = null;
        localStorage.removeItem("lastDeviceAddr");
      }, 500);
      break;
    }

    case "WATCHDOG": {
      const name = msg.name || "Unknown";
      const model = msg.model ? ` - ${msg.model}` : "";
      const apiVer = msg.api_version ? ` — API v${msg.api_version}` : "";
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
      // Small delay before reloading sessions so CSV is fully written
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
          <a class="btn btn-small" href="/download/${sessId}">⬇ Download CSV</a>
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
      const apiVer = d.api_version ? ` — API v${d.api_version}` : "";
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

// ───────────── Clear All Sessions Button ─────────────
document.addEventListener("DOMContentLoaded", () => {
  const clearBtn = document.getElementById("clearSessionsBtn");
  if (!clearBtn) return;
  const sessionsList = document.getElementById("sessionsList");
  const loadMoreBtn = document.getElementById("loadMoreBtn");
  let hoverTimer = null;
  let isClearing = false;

  clearBtn.classList.add("inactive");
  clearBtn.classList.remove("armed");

  const safeLog = (msg) => {
    try {
      log(msg);
    } catch {
      console.log(msg);
    }
  };

  clearBtn.addEventListener("mouseenter", () => {
    if (isClearing) return;
    hoverTimer = setTimeout(() => {
      if (!isClearing) {
        clearBtn.classList.add("armed");
        clearBtn.classList.remove("inactive");
      }
    }, 5000);
  });

  clearBtn.addEventListener("mouseleave", () => {
    clearTimeout(hoverTimer);
    if (!isClearing) {
      clearBtn.classList.remove("armed");
      clearBtn.classList.add("inactive");
    }
  });

  clearBtn.addEventListener("click", async (e) => {
    e.preventDefault();
    if (!clearBtn.classList.contains("armed") || isClearing) {
      safeLog("ℹ️ Hover 5 seconds to enable Clear Sessions button.");
      return;
    }

    const hasSessions = sessionsList && sessionsList.children.length > 0;
    if (!hasSessions) {
      safeLog("🗑️ Past Sessions already cleared.");
      clearBtn.classList.remove("armed");
      clearBtn.classList.add("inactive");
      return;
    }

    isClearing = true;
    clearBtn.textContent = "⏳ Clearing...";
    clearBtn.classList.remove("armed");
    clearBtn.classList.add("inactive");

    try {
      const res = await fetch("/clear_sessions", { method: "POST" });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        const folder = data.archive_dir ? data.archive_dir.split("/").pop() : "(unknown)";
        safeLog(`🗑️ All sessions archived to /archive/${folder}`);
        if (sessionsList) sessionsList.innerHTML = "";
        if (typeof offset !== "undefined") offset = 0;
        if (loadMoreBtn) loadMoreBtn.style.display = "none";
      } else {
        safeLog(`⚠️ Failed to clear sessions: HTTP ${res.status}`);
      }
    } catch (err) {
      safeLog("❌ Error clearing sessions: " + (err?.message || err));
    } finally {
      clearBtn.textContent = "🗑️ Clear All Sessions";
      clearBtn.classList.remove("armed");
      clearBtn.classList.add("inactive");
      isClearing = false;
    }
  });
});

// ───────────── Initialize ─────────────
loadSessions();
