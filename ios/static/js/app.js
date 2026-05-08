// ───────────── WebSocket Setup ─────────────
const wsUrl = (location.protocol === "https:" ? "wss:" : "ws:") + "//" + location.host + "/ws";
const ws = new WebSocket(wsUrl);

// ───────────── UI Elements ─────────────
const indicator = document.getElementById("connectionIndicator");
const firstShotDiv = document.getElementById("firstShot");
const bestSplitDiv = document.getElementById("bestSplit");
const totalTimeDiv = document.getElementById("totalTime");
const totalShotsDiv = document.getElementById("totalShots");
const shotsDiv = document.getElementById("shots");
const statusDiv = document.getElementById("status");
const titleDiv = document.getElementById("competitionTitle");

// ───────────── State Variables ─────────────
let sessId = localStorage.getItem("sessId") || null;
let shots = JSON.parse(localStorage.getItem("shots_" + sessId) || "[]");
let bestSplit = parseFloat(localStorage.getItem("bestSplit_" + sessId)) || 0;
let totalTime = parseFloat(localStorage.getItem("totalTime_" + sessId)) || 0;
let totalShots = parseInt(localStorage.getItem("totalShots_" + sessId)) || 0;
let firstShotTime = parseFloat(localStorage.getItem("firstShotTime_" + sessId)) || 0;
let currentSessionState = localStorage.getItem("session_state") || "STOPPED";

// ───────────── UI Helpers ─────────────
function updateStatus(state) {
  currentSessionState = state;
  localStorage.setItem("session_state", state);

  statusDiv.textContent =
    state === "LIVE" ? "LIVE" :
    state === "STANDBY" ? "STANDBY" :
    "STOPPED";

  statusDiv.className =
    state === "LIVE" ? "live" :
    state === "STANDBY" ? "standby" :
    "stopped";
}

function updateStatsDisplay() {
  firstShotDiv.textContent = `First Shot - ${firstShotTime.toFixed(2)}`;
  bestSplitDiv.textContent = `Best Split - ${bestSplit.toFixed(2)}`;
  totalTimeDiv.textContent = `Total Time - ${totalTime.toFixed(2)}`;
  totalShotsDiv.textContent = `Total Shots - ${totalShots}`;
}

// ───────────── Shared rendering helper ─────────────
function renderShot(shotNum, shotTime, prevTime) {
  // Container to hold shot and split (split below)
  const container = document.createElement("div");
  container.style.display = "flex";
  container.style.flexDirection = "column";
  container.style.alignItems = "flex-end";

  const shotElement = document.createElement("div");
  shotElement.classList.add("shot-line");
  shotElement.textContent = `#${shotNum} - ${shotTime.toFixed(2)}`;
  container.appendChild(shotElement);

  if (prevTime !== undefined) {
    const splitElement = document.createElement("div");
    splitElement.classList.add("split-line");
    splitElement.textContent = `Split ${(shotTime - prevTime).toFixed(2)}`;
    container.appendChild(splitElement);
  }

  shotsDiv.prepend(container); // 🟢 newest shots always appear on top

  while (shotsDiv.childElementCount > 30) {
    shotsDiv.removeChild(shotsDiv.lastChild);
  }
}

// ───────────── Restore full shot list ─────────────
function restoreShotList() {
  shotsDiv.innerHTML = "";
  if (!shots || shots.length === 0) return;

  // Render oldest to newest, but prepend each — newest ends up on top
  for (let i = 0; i < shots.length; i++) {
    const s = shots[i];
    const prev = i > 0 ? shots[i - 1] : undefined;
    renderShot(s.num, s.time, prev ? prev.time : undefined);
  }
}

// ───────────── On Load ─────────────
(async () => {
  updateStatus(currentSessionState);
  updateStatsDisplay();
  restoreShotList();

  try {
    const res = await fetch("/status");
    const data = await res.json();
    if (data.connected && data.devices.length > 0) {
      const d = data.devices.find(x => x.connected);
      indicator.classList.remove("disconnected", "standby");
      indicator.classList.add("connected");
      console.log(`Device already connected: ${d.name} (${d.address})`);
    } else {
      indicator.classList.remove("connected", "standby");
      indicator.classList.add("disconnected");
      console.log("No device currently connected.");
    }
  } catch (e) {
    console.warn("Failed to get initial connection status:", e);
  }
})();

// ───────────── Initial Title Load ─────────────
fetch("/get_title")
  .then(r => r.json())
  .then(d => {
    if (d.title) titleDiv.textContent = d.title;
  });

// ───────────── WebSocket Connection Events ─────────────
ws.onopen = async () => {
  console.log("WebSocket connected to server");
  indicator.classList.remove("connected", "standby");
  indicator.classList.add("disconnected");

  try {
    const res = await fetch("/status");
    const data = await res.json();
    if (data.connected && data.devices.length > 0) {
      const d = data.devices.find(x => x.connected);
      if (d) {
        indicator.classList.remove("disconnected", "standby");
        indicator.classList.add("connected");
        console.log(`Active device: ${d.name} (${d.address})`);
      }
    } else {
      indicator.classList.remove("connected", "standby");
      indicator.classList.add("disconnected");
      console.log("No device currently connected.");
    }
  } catch (e) {
    console.warn("Failed to get connection status:", e);
  }

  updateStatsDisplay();
  updateStatus(localStorage.getItem("session_state") || "STOPPED");
  restoreShotList();
};

ws.onclose = () => {
  indicator.classList.remove("connected", "standby");
  indicator.classList.add("disconnected");
  updateStatus("STOPPED");
};

// ───────────── WebSocket Message Handling ─────────────
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);

  if (msg.type === "DEVICE_CONNECTED") {
    indicator.classList.remove("disconnected", "standby");
    indicator.classList.add("connected");
    return;
  }

  if (msg.type === "DEVICE_DISCONNECTED") {
    indicator.classList.remove("connected", "standby");
    indicator.classList.add("disconnected");
    return;
  }

  if (msg.type === "WATCHDOG") {
    if (msg.status === "disconnected") {
      indicator.classList.remove("connected");
      indicator.classList.add("standby");
    } else if (msg.status === "reconnected") {
      indicator.classList.remove("standby", "disconnected");
      indicator.classList.add("connected");
    }
    return;
  }

  switch (msg.type) {
    case "TITLE_UPDATE":
      if (msg.title) titleDiv.textContent = msg.title;
      break;

    case "SESSION_STARTED":
      sessId = msg.sess_id || Date.now().toString();
      localStorage.setItem("sessId", sessId);

      shots = [];
      shotsDiv.innerHTML = "";
      bestSplit = 0;
      totalTime = 0;
      totalShots = 0;
      firstShotTime = 0;

      localStorage.setItem("bestSplit_" + sessId, bestSplit);
      localStorage.setItem("totalTime_" + sessId, totalTime);
      localStorage.setItem("totalShots_" + sessId, totalShots);
      localStorage.setItem("firstShotTime_" + sessId, firstShotTime);
      localStorage.setItem("shots_" + sessId, JSON.stringify(shots));

      updateStatsDisplay();
      updateStatus("LIVE");
      break;

    case "SHOT_DETECTED": {
      const shotNum = msg.num || (totalShots + 1);
      const shotTime = msg.time;

      totalShots = shotNum;
      totalTime = shotTime;
      if (totalShots === 1) firstShotTime = shotTime;

      if (shots.length > 0) {
        const prev = shots[shots.length - 1];
        const split = shotTime - prev.time;
        if (bestSplit === 0 || split < bestSplit) bestSplit = split;
      }

      shots.push(msg);

      localStorage.setItem("bestSplit_" + sessId, bestSplit);
      localStorage.setItem("totalTime_" + sessId, totalTime);
      localStorage.setItem("totalShots_" + sessId, totalShots);
      localStorage.setItem("firstShotTime_" + sessId, firstShotTime);
      localStorage.setItem("shots_" + sessId, JSON.stringify(shots));

      updateStatsDisplay();

      const prevTime = shots.length > 1 ? shots[shots.length - 2].time : undefined;
      renderShot(shotNum, shotTime, prevTime); // newest on top
      updateStatus("LIVE");
      break;
    }

    case "SESSION_SUSPENDED":
      updateStatus("STANDBY");
      break;

    case "SESSION_RESUMED":
      updateStatus("LIVE");
      break;

    case "SESSION_STOPPED":
      updateStatus("STOPPED");

      if (sessId) {
        localStorage.removeItem("bestSplit_" + sessId);
        localStorage.removeItem("totalTime_" + sessId);
        localStorage.removeItem("totalShots_" + sessId);
        localStorage.removeItem("firstShotTime_" + sessId);
        localStorage.removeItem("shots_" + sessId);
      }
      break;
  }
};
