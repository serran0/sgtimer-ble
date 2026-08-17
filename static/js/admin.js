// Bump alongside __version__ in server.py on every release. Baked into this
// file (not fetched) so it reflects whatever JS the browser is actually
// running — a stale cached admin.js would otherwise report the live
// server's version instead of its own, defeating the point of the check.
const UI_BUILD = "1.2.0";

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
const pairBtn = document.getElementById("pairBtn");
const unpairBtn = document.getElementById("unpairBtn");
const deviceHint = document.getElementById("deviceHint");
const aliasInput = document.getElementById("aliasInput");
const setAliasBtn = document.getElementById("setAliasBtn");
const clearAliasBtn = document.getElementById("clearAliasBtn");
const clearTitleBtn = document.getElementById("clearTitleBtn");
const titleScale = document.getElementById("titleScale");
const statsScale = document.getElementById("statsScale");
const tickerScale = document.getElementById("tickerScale");
const applySizesBtn = document.getElementById("applySizesBtn");
const resetSizesBtn = document.getElementById("resetSizesBtn");
const pairingOverlay = document.getElementById("pairingOverlay");
const pairingDevice = document.getElementById("pairingDevice");
const pairingHint = document.getElementById("pairingHint");
const pairingCode = document.getElementById("pairingCode");
const pairingPin = document.getElementById("pairingPin");
const pairingCountdown = document.getElementById("pairingCountdown");
const pairingAcceptBtn = document.getElementById("pairingAcceptBtn");
const pairingRejectBtn = document.getElementById("pairingRejectBtn");

let offset = 0;
const PAGE_SIZE = 20;
let currentConnectedDevice = null;
let pendingPairing = null;
let pairingTicker = null;
let knownAliases = {};
let sizeDefaults = { title_scale: 100, stats_scale: 100, ticker_scale: 100 };

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
        updateDeviceButtons();
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

    case "PAIRING_STARTED":
      log(`🔐 Pairing with ${msg.name || msg.addr} — confirm on the timer too.`);
      break;

    case "PAIRING_REQUEST":
      showPairingPrompt(msg);
      break;

    case "PAIRING_RESULT":
      hidePairingPrompt();
      if (msg.ok)
        log(`✅ Paired with ${msg.name || msg.addr} (${msg.status})`);
      else log(`❌ Pairing failed: ${msg.message}`);
      break;

    case "PAIRING_CANCELLED":
      hidePairingPrompt();
      log(`⚠️ Pairing cancelled: ${msg.reason}`);
      break;

    case "PAIRING_REQUIRED":
      log(`🔐 ${msg.message}`);
      break;

    case "CONNECT_RETRY":
      log(
        `⏳ Connect attempt ${msg.attempt}/${msg.attempts} failed — retrying ` +
          `(the timer is released a few seconds after pairing)`
      );
      break;

    case "UNPAIRED":
      log(`🔓 Forgot pairing for ${msg.name || msg.addr}`);
      break;

    case "ALIAS_UPDATE": {
      const key = (msg.addr || "").toUpperCase();
      if (msg.alias) knownAliases[key] = msg.alias;
      else delete knownAliases[key];
      renderDeviceOptions();
      break;
    }

    case "DISPLAY_SETTINGS":
      applySizeInputs(msg.settings);
      break;

    case "ERROR":
      log(`❌ ${msg.message}`);
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
        } catch (e) {
          log("⚠️ Failed to refresh sessions after stop: " + e.message);
        }
      }, 1000);
      break;

    case "SHOT_DETECTED":
      log(`#${msg.num} - ${msg.time.toFixed(2)}s`);
      break;

    case "TITLE_UPDATE":
      // "" is a real title (meaning none), so compare without truthiness
      if (msg.title !== undefined && titleInput.value.trim() !== msg.title) {
        titleInput.value = msg.title;
        log(msg.title ? `📝 Title updated: ${msg.title}` : "📝 Title cleared");
      }
      break;

    default:
      break;
  }
};

// ───────────── Device Controls ─────────────
// Timers seen in the most recent scan, address -> {name, paired}.
let scannedDevices = new Map();

// The dropdown lists scanned timers *and* every timer that has been named,
// so saved ones can be identified and renamed without scanning first — a
// timer already in a connection does not advertise and would otherwise
// disappear from the list entirely.
function renderDeviceOptions() {
  const previous = deviceSelect.value || localStorage.getItem("lastDeviceAddr");
  deviceSelect.innerHTML = "";
  const listed = new Set();

  const addOption = (addr, name, { paired, seen }) => {
    const key = addr.toUpperCase();
    if (listed.has(key)) return;
    listed.add(key);

    const alias = aliasFor(addr);
    // Lead with the operator's name; keep the BLE name so a renamed timer is
    // still identifiable against the hardware in front of you.
    const shown = alias ? `${alias} — ${name || "Unknown"}` : name || "Unknown";
    const pairState = paired === false ? " 🔐 not paired" : "";
    const seenState = seen ? "" : " · saved";

    const opt = document.createElement("option");
    opt.value = addr;
    opt.textContent = `${shown} (${addr})${pairState}${seenState}`;
    opt.dataset.name = name || "";
    deviceSelect.appendChild(opt);
  };

  scannedDevices.forEach((d, addr) =>
    addOption(addr, d.name, { paired: d.paired, seen: true })
  );
  Object.keys(knownAliases).forEach((addr) =>
    addOption(addr, null, { paired: null, seen: false })
  );

  if (previous) deviceSelect.value = previous;
  refreshAliasInput();
  updateDeviceButtons();
}

async function scanDevices() {
  log("📡 Scanning for compatible devices...");
  const res = await fetch("/devices");
  const data = await res.json();

  scannedDevices = new Map();
  data.devices.forEach((d) => {
    if (d.alias) knownAliases[d.address.toUpperCase()] = d.alias;
    scannedDevices.set(d.address, { name: d.name, paired: d.paired });
  });

  renderDeviceOptions();
  log(`Found ${data.devices.length} device(s).`);
  if (!data.devices.length)
    log("⚠️ No timers found — switch the timer on and scan again.");
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

  try {
    const res = await fetch("/connect", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ address: addr, name }),
    });
    const data = await res.json().catch(() => ({}));
    if (data.status === "failed")
      log(`❌ Connect failed: ${data.error || "unknown error"}`);
  } catch (e) {
    log("❌ Error connecting: " + e.message);
  }
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
  try {
    const res = await fetch("/disconnect", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ address: addr }),
    });
    const data = await res.json().catch(() => ({}));
    if (data.status === "still_connected") {
      log(`⚠️ Disconnect did not take effect${data.error ? `: ${data.error}` : "."}`);
      return; // still connected — do not pretend otherwise
    }
    if (data.status === "not connected") log("ℹ️ That device was not connected.");
  } catch (e) {
    log("❌ Error disconnecting: " + e.message);
    return;
  }

  currentConnectedDevice = null;
  localStorage.removeItem("lastDeviceAddr");
  updateDeviceButtons();
}

// ───────────── Device Names (aliases) ─────────────
// Timers all advertise as SG-SST4…, so a serial number is the only thing
// separating them by default. An alias is stored on the server, not in this
// browser, so every screen and machine sees the same name.
function aliasFor(addr) {
  return addr ? knownAliases[addr.toUpperCase()] || null : null;
}

function labelFor(addr, name) {
  return aliasFor(addr) || name || addr;
}

function selectedAddress() {
  return deviceSelect.value || localStorage.getItem("lastDeviceAddr") || null;
}

function refreshAliasInput() {
  const addr = selectedAddress();
  aliasInput.value = aliasFor(addr) || "";
  aliasInput.placeholder = addr
    ? "e.g. Stage 3 — left bay"
    : "Select a timer first";
}

async function loadAliases() {
  try {
    const res = await fetch("/aliases");
    const data = await res.json();
    knownAliases = data.aliases || {};
    renderDeviceOptions();
  } catch (e) {
    log("⚠️ Could not load saved timer names: " + e.message);
  }
}

async function saveAlias(alias) {
  const addr = selectedAddress();
  if (!addr) {
    log("⚠️ No timer selected — press 🔍 Scan and pick one first.");
    return;
  }
  try {
    const res = await fetch("/alias", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ address: addr, alias }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      log(`⚠️ Could not save the name: ${data.detail || `HTTP ${res.status}`}`);
      return;
    }
    log(
      data.alias
        ? `💾 Named ${addr} "${data.alias}"`
        : `💾 Cleared the saved name for ${addr}`
    );
  } catch (e) {
    log("❌ Error saving the name: " + e.message);
  }
}

// ───────────── Display Text Size ─────────────
async function loadDisplaySettings() {
  try {
    const res = await fetch("/display_settings");
    const data = await res.json();
    if (data.defaults) sizeDefaults = data.defaults;
    applySizeInputs(data.settings);
  } catch (e) {
    log("⚠️ Could not load display sizes: " + e.message);
  }
}

function applySizeInputs(settings) {
  if (!settings) return;
  titleScale.value = settings.title_scale;
  statsScale.value = settings.stats_scale;
  tickerScale.value = settings.ticker_scale;
}

async function saveDisplaySettings(settings) {
  try {
    const res = await fetch("/display_settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(settings),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      log(`⚠️ Could not apply sizes: ${data.detail || `HTTP ${res.status}`}`);
      return;
    }
    applySizeInputs(data.settings);
    log(
      `🔠 Display sizes applied — title ${data.settings.title_scale}%, ` +
        `stats ${data.settings.stats_scale}%, ticker ${data.settings.ticker_scale}%`
    );
  } catch (e) {
    log("❌ Error applying sizes: " + e.message);
  }
}

setAliasBtn.addEventListener("click", () => saveAlias(aliasInput.value.trim()));
clearAliasBtn.addEventListener("click", () => {
  aliasInput.value = "";
  saveAlias("");
});
aliasInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") saveAlias(aliasInput.value.trim());
});

applySizesBtn.addEventListener("click", () =>
  saveDisplaySettings({
    title_scale: titleScale.value,
    stats_scale: statsScale.value,
    ticker_scale: tickerScale.value,
  })
);
resetSizesBtn.addEventListener("click", () => saveDisplaySettings(sizeDefaults));

// ───────────── Pairing ─────────────
// The timer asks for the same confirmation on its own screen; this dialog is
// the client half of that ceremony.
const PAIRING_HINTS = {
  confirm_pin_match: "Check that the code below matches the one on the timer, then confirm on both.",
  display_pin: "Enter the code below on the timer to finish pairing.",
  provide_pin: "Type the code shown on the timer.",
  confirm_only: "Confirm the pairing request here and on the timer.",
};

function showPairingPrompt(msg) {
  pendingPairing = msg;

  pairingDevice.textContent = `${msg.name || "Timer"} (${msg.addr})`;
  pairingHint.textContent =
    PAIRING_HINTS[msg.kind] || "Confirm the pairing request on the timer.";

  const needsPin = msg.kind === "provide_pin";
  pairingCode.hidden = !msg.pin;
  pairingCode.textContent = msg.pin || "";
  pairingPin.hidden = !needsPin;
  pairingPin.value = "";

  pairingOverlay.hidden = false;
  (needsPin ? pairingPin : pairingAcceptBtn).focus();

  log(
    `🔐 Pairing confirmation requested for ${msg.name || msg.addr}` +
      (msg.pin ? ` — code ${msg.pin}` : "")
  );

  // Mirror the timer's own 60 s pairing window.
  let left = Math.round(msg.timeout || 60);
  const tick = () => {
    pairingCountdown.textContent = left > 0 ? `Expires in ${left}s` : "Expired";
    if (left-- <= 0) clearInterval(pairingTicker);
  };
  clearInterval(pairingTicker);
  tick();
  pairingTicker = setInterval(tick, 1000);
}

function hidePairingPrompt() {
  pendingPairing = null;
  clearInterval(pairingTicker);
  pairingTicker = null;
  pairingOverlay.hidden = true;
  pairingCountdown.textContent = "";
}

async function answerPairing(accept) {
  if (!pendingPairing) return;
  const body = { address: pendingPairing.addr, accept };
  if (accept && pendingPairing.kind === "provide_pin") {
    const pin = pairingPin.value.trim();
    if (!pin) {
      log("⚠️ Enter the code shown on the timer first.");
      return;
    }
    body.pin = pin;
  }

  hidePairingPrompt();
  try {
    const res = await fetch("/pair/confirm", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) log(`⚠️ Could not send confirmation: HTTP ${res.status}`);
    else log(accept ? "✅ Pairing confirmed — waiting for the timer..." : "✖ Pairing rejected.");
  } catch (e) {
    log("❌ Error confirming pairing: " + e.message);
  }
}

// Pair/Forget need a device selected. The buttons deliberately stay
// clickable without one: a disabled button fires no event at all, which
// looks exactly like a broken button. Instead every click answers, and a
// hint next to the dropdown always states what the app thinks is selected.
function updateDeviceButtons() {
  const addr = deviceSelect.value || localStorage.getItem("lastDeviceAddr");
  // A remembered address is not a connection: say which one this is, so the
  // hint can never read as "connected" while the server says otherwise.
  if (currentConnectedDevice) {
    const named = aliasFor(currentConnectedDevice);
    deviceHint.textContent = named
      ? `Connected: ${named} (${currentConnectedDevice})`
      : `Connected: ${currentConnectedDevice}`;
  } else if (addr) {
    const named = aliasFor(addr);
    deviceHint.textContent = named
      ? `Selected: ${named} (${addr}) — not connected`
      : `Selected: ${addr} — not connected`;
  } else {
    deviceHint.textContent = "No timer selected — press 🔍 Scan";
  }
  deviceHint.classList.toggle("warn", !currentConnectedDevice);
}

async function pairDevice() {
  const addr = deviceSelect.value || localStorage.getItem("lastDeviceAddr");
  if (!addr) {
    log("⚠️ No device selected — press 🔍 Scan and pick your timer first.");
    return;
  }
  const selected = deviceSelect.options[deviceSelect.selectedIndex];
  log("🔐 Enable pairing mode on the timer (Settings → Bluetooth → Pairing mode), then confirm here.");

  try {
    const res = await fetch("/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ address: addr, name: selected ? selected.dataset.name : null }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) log(`❌ Pairing failed: ${data.detail || `HTTP ${res.status}`}`);
    else if (data.status === "already_paired") log("ℹ️ This timer is already paired.");
  } catch (e) {
    log("❌ Error pairing: " + e.message);
  }
}

async function unpairDevice() {
  const addr = deviceSelect.value || localStorage.getItem("lastDeviceAddr");
  if (!addr) {
    log("⚠️ No device selected — press 🔍 Scan and pick your timer first.");
    return;
  }
  try {
    const res = await fetch("/unpair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ address: addr }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) log(`❌ Could not forget device: ${data.detail || `HTTP ${res.status}`}`);
  } catch (e) {
    log("❌ Error forgetting device: " + e.message);
  }
}

pairingAcceptBtn.addEventListener("click", () => answerPairing(true));
pairingRejectBtn.addEventListener("click", () => answerPairing(false));
pairingPin.addEventListener("keydown", (e) => {
  if (e.key === "Enter") answerPairing(true);
});

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

deviceSelect.addEventListener("change", () => {
  updateDeviceButtons();
  refreshAliasInput();
});
updateDeviceButtons();
log(`🧭 Admin UI build ${UI_BUILD}`);
loadAliases();
loadDisplaySettings();

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
// A blank title is a valid choice — it hides the title on the overlay — so
// this no longer refuses to send an empty value.
async function setTitle(newTitle) {
  try {
    const res = await fetch("/set_title", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: newTitle }),
    });
    if (!res.ok) {
      log("⚠️ Failed to update title");
      return;
    }
    log(newTitle ? `✅ Title updated: ${newTitle}` : "✅ Title cleared — the overlay shows no title.");
  } catch (e) {
    log("Error setting title: " + e.message);
  }
}

setTitleBtn.addEventListener("click", () => setTitle(titleInput.value.trim()));
clearTitleBtn.addEventListener("click", () => {
  titleInput.value = "";
  setTitle("");
});

// ───────────── Auto-Fill Title & Connection Status ─────────────
fetch("/get_title")
  .then((r) => r.json())
  .then((d) => {
    if (d.title !== undefined) titleInput.value = d.title;
  });

fetch("/status")
  .then((r) => r.json())
  .then((data) => {
    // Confirm the JS the browser is running actually matches the server it
    // talks to, rather than trusting the console.log at startup blindly.
    if (data.version && data.version !== UI_BUILD) {
      log(
        `⚠️ Version mismatch: this page is build ${UI_BUILD} but the server ` +
          `is v${data.version} — hard-refresh (Ctrl+F5) to load the current UI.`
      );
    } else if (data.version) {
      log(`✅ UI build ${UI_BUILD} matches the server.`);
    }

    // a ceremony may have been raised before this page was opened
    if (data.pending_pairing) showPairingPrompt(data.pending_pairing);
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
      currentConnectedDevice = null;
      log(
        lastAddr
          ? "ℹ️ No device currently connected — press 🔗 Connect to reconnect."
          : "ℹ️ No device currently connected."
      );
    }
    updateDeviceButtons();
  })
  .catch((e) => log("⚠️ Could not fetch connection status: " + e.message));

// ───────────── Helper: Update Dropdown ─────────────
function updateDeviceDropdown(addr, name = null) {
  if (!addr) return;
  // Fold it into the known list rather than replacing the list, so other
  // scanned and saved timers stay selectable.
  const existing = scannedDevices.get(addr) || {};
  scannedDevices.set(addr, {
    name: name || existing.name || null,
    paired: existing.paired ?? null,
  });
  renderDeviceOptions();
  deviceSelect.value = addr;
  refreshAliasInput();
  updateDeviceButtons();
}

// ───────────── Restore Last Connected Device ─────────────
const lastAddr = localStorage.getItem("lastDeviceAddr");
if (lastAddr) {
  // Remembered, not connected — /status below reports what is actually live.
  updateDeviceDropdown(lastAddr, "Last used");
  log(`💾 Last used device: ${lastAddr} (not connected yet)`);
}

// ───────────── Buttons ─────────────
scanBtn.addEventListener("click", scanDevices);
connectBtn.addEventListener("click", connectDevice);
disconnectBtn.addEventListener("click", disconnectDevice);
pairBtn.addEventListener("click", pairDevice);
unpairBtn.addEventListener("click", unpairDevice);
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
