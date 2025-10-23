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
    case "DEVICE_CONNECTED":
      if (currentConnectedDevice && currentConnectedDevice === msg.addr) return;

      setTimeout(() => {
        currentConnectedDevice = msg.addr;
        log(`✅ Device connected: ${msg.name || msg.addr}`);
        localStorage.setItem("lastDeviceAddr", msg.addr);
        updateDeviceDropdown(msg.addr, msg.name);
      }, 500);
      break;

    case "DEVICE_DISCONNECTED":
      setTimeout(() => {
        log("⚠️ Device disconnected");
        currentConnectedDevice = null;
        localStorage.removeItem("lastDeviceAddr");
      }, 500);
      break;

    case "WATCHDOG":
      if (msg.status === "reconnected") log("🟢 Watchdog reconnected device");
      else if (msg.status === "disconnected") log("🟡 Watchdog reconnecting...");
      else log(`⚠️ Watchdog: ${msg.status}`);
      break;

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
      // Removed extra confirmation message for cleaner console
    } catch (e) {
      log("⚠️ Failed to refresh sessions after stop: " + e.message);
    }
  }, 1000);
  break;




    case "SHOT_DETECTED":
      log(`#${msg.num} - ${msg.time.toFixed(2)}s`);
      break;

    case "TITLE_UPDATE":
      // Only update the field silently if another client changed it
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
    opt.textContent = `${d.name} (${d.address})`;
    deviceSelect.appendChild(opt);
  });
  log(`Found ${data.devices.length} device(s).`);
}

async function connectDevice() {
  const addr = deviceSelect.value;
  if (!addr) {
    log("⚠️ No device selected for connection.");
    return;
  }

  // Prevent connecting to the same device again
  if (currentConnectedDevice && currentConnectedDevice === addr) {
    log("ℹ️ Selected device is already connected.");
    return;
  }

  // Check if another device is connected
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

  // Show instantly
  log(`Connecting to ${addr}...`);
  localStorage.setItem("lastDeviceAddr", addr);

  // Then actually connect
  await fetch("/connect", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ address: addr }),
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

  // Show instantly
  log(`Disconnecting from ${addr}...`);

  // Then perform the disconnect
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
  const res = await fetch(`/sessions?offset=${offset}&limit=${PAGE_SIZE}`);
  const j = await res.json();
  const list = j.sessions || [];
  if (!append) sessionsList.innerHTML = "";

  for (const s of list) {
    const sessId = s.sess_id;
    // Treat sessId (Unix timestamp) as already local-time-corrected from device
    const ts = Number(sessId);
    const date = new Date(ts * 1000);

    // Extract UTC parts directly (device-adjusted)
    const year = date.getUTCFullYear();
    const month = String(date.getUTCMonth() + 1).padStart(2, "0");
    const day = String(date.getUTCDate()).padStart(2, "0");
    const hours = String(date.getUTCHours()).padStart(2, "0");
    const minutes = String(date.getUTCMinutes()).padStart(2, "0");
    const seconds = String(date.getUTCSeconds()).padStart(2, "0");

const formatted = `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
    const shots = s.total_shots || 0;
    const best = s.best_split ? s.best_split.toFixed(2) : "0.00";
    const totalTime = s.total_time ? s.total_time.toFixed(2) : "—";

    const card = document.createElement("div");
    card.className = "session-card";
    card.innerHTML = `
      <div class="session-main">
        <div class="session-title">
          Session ${sessId} — ${formatted}
        </div>
        <div class="session-meta">
          <span>Shots: <b>${shots}</b> - Time: <b>${totalTime}</b>s</span>
          <span>Best Split: <b>${best}</b></span>
        </div>
      </div>
      <div class="session-actions">
        <a class="btn btn-small" href="/download/${sessId}">⬇ Download CSV</a>
      </div>`;
    sessionsList.appendChild(card);
  }

  offset += list.length;
  if (offset === 0 && list.length <= PAGE_SIZE) {
  loadMoreBtn.style.display = "none";
} else if (list.length === PAGE_SIZE) {
  loadMoreBtn.style.display = "inline-block";
}
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
      log(`✅ Device connected: ${d.name} (${d.address})`);
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


// --- Clear All Sessions (robust wiring) ---
document.addEventListener("DOMContentLoaded", () => {
  const clearBtn = document.getElementById("clearSessionsBtn");
  const sessionsList = document.getElementById("sessionsList");
  const loadMoreBtn = document.getElementById("loadMoreBtn");

  // guard: if element missing, do nothing
  if (!clearBtn) return;

  let hoverTimer = null;
  let isClearing = false;

  // ensure initial state
  clearBtn.classList.add("inactive");
  clearBtn.classList.remove("armed");

  function safeLog(msg) {
    // your existing log() if present; fall back to console
    try { log(msg); } catch { console.log(msg); }
  }

  clearBtn.addEventListener("mouseenter", () => {
    if (isClearing) return;                 // don't arm while clearing
    // Start 5s arming timer; keep it visually inactive until we arm
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

  // Not armed yet? show info
  if (!clearBtn.classList.contains("armed") || isClearing) {
    safeLog("ℹ️ Hover 5 seconds to enable Clear Sessions button.");
    return;
  }

  // Check if there are any sessions to clear
  const hasSessions = sessionsList && sessionsList.children.length > 0;
  if (!hasSessions) {
    safeLog("🗑️ Past Sessions already cleared.");
    clearBtn.classList.remove("armed");
    clearBtn.classList.add("inactive");
    return;
  }

  // Enter clearing state (disable + gray)
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
      // clear UI
      if (sessionsList) sessionsList.innerHTML = "";
      if (typeof offset !== "undefined") offset = 0;
      if (loadMoreBtn) loadMoreBtn.style.display = "none";
    } else {
      safeLog(`⚠️ Failed to clear sessions: HTTP ${res.status}`);
    }
  } catch (err) {
    safeLog("❌ Error clearing sessions: " + (err?.message || err));
  } finally {
    // Reset to safe inactive state and label
    clearBtn.textContent = "🗑️ Clear All Sessions";
    clearBtn.classList.remove("armed");
    clearBtn.classList.add("inactive");
    isClearing = false;
  }
});

});


// ───────────── Initialize ─────────────
loadSessions();
