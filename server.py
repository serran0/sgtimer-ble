#!/usr/bin/env python3
__version__ = "1.0.1"

import configparser
import asyncio
import time
import os
import sys
import shutil
from datetime import datetime
from typing import Dict, Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from bleak import BleakScanner, BleakClient
from sessions_api import router as sessions_router

# ─────────────────────────────────────────────
# Cross-platform path setup (supports PyInstaller)
# ─────────────────────────────────────────────
if getattr(sys, "frozen", False):
    BASE_DIR = os.path.dirname(sys.executable)
    STATIC_DIR = os.path.join(sys._MEIPASS, "static")
else:
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))
    STATIC_DIR = os.path.join(BASE_DIR, "static")

DATA_DIR = os.path.join(BASE_DIR, "data")
ARCHIVE_ROOT = os.path.join(DATA_DIR, "archive")
TITLE_FILE = os.path.join(BASE_DIR, "title.txt")

# Create base folders on startup
os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(ARCHIVE_ROOT, exist_ok=True)
if not os.path.exists(TITLE_FILE):
    with open(TITLE_FILE, "w") as f:
        f.write("SG Timer")

# ─────────────────────────────────────────────
# BLE service details
# ─────────────────────────────────────────────
SERVICE_UUID = "7520ffff-14d2-4cda-8b6b-697c554c9311"
EVENT_UUID = "75200001-14d2-4cda-8b6b-697c554c9311"
API_VERSION_UUID = "7520fffe-14d2-4cda-8b6b-697c554c9311"  # ✅ Corrected UUID
NAME_PREFIX = "SG-SST"

EVENT_TYPES = {
    0x00: "SESSION_STARTED",
    0x01: "SESSION_SUSPENDED",
    0x02: "SESSION_RESUMED",
    0x03: "SESSION_STOPPED",
    0x04: "SHOT_DETECTED",
    0x05: "SESSION_SET_BEGIN",
}

# ─────────────────────────────────────────────
# FastAPI setup
# ─────────────────────────────────────────────
app = FastAPI(title="SG Timer BLE Server")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(sessions_router)

# ─────────────────────────────────────────────
# WebSocket hub
# ─────────────────────────────────────────────
class WsHub:
    def __init__(self):
        self.clients = set()

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.clients.add(ws)
        # send current title
        if os.path.exists(TITLE_FILE):
            with open(TITLE_FILE) as f:
                title = f.read().strip()
                await ws.send_json({"type": "TITLE_UPDATE", "title": title})

        # send retained session state if any
        if session_state.get("sess_id"):
            await ws.send_json({"type": "SESSION_SYNC", "state": session_state})
        elif last_session_state:
            await ws.send_json({"type": "SESSION_SYNC", "state": last_session_state})

    def disconnect(self, ws: WebSocket):
        self.clients.discard(ws)

    async def broadcast(self, msg: dict):
        dead = []
        for ws in list(self.clients):
            try:
                await ws.send_json(msg)
            except Exception:
                dead.append(ws)
        for d in dead:
            self.disconnect(d)


hub = WsHub()


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await hub.connect(ws)
    try:
        while True:
            await ws.receive_text()
    except (WebSocketDisconnect, Exception):
        hub.disconnect(ws)


async def broadcast(msg: dict):
    await hub.broadcast(msg)

# ─────────────────────────────────────────────
# Session State Retention
# ─────────────────────────────────────────────
session_state = {
    "active": False,
    "status": "STOPPED",
    "shots": [],
    "first_shot": 0.0,
    "best_split": 0.0,
    "total_time": 0.0,
    "sess_id": None,
}
last_session_state = None

# ─────────────────────────────────────────────
# Clear Sessions Endpoint
# ─────────────────────────────────────────────
@app.post("/clear_sessions")
async def clear_sessions():
    """
    Move all session CSV files to /data/archive/YYYY-MM-DD_HH-MM/
    and ensure archive structure always exists.
    """
    global last_session_state

    os.makedirs(ARCHIVE_ROOT, exist_ok=True)
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M")
    target_dir = os.path.join(ARCHIVE_ROOT, timestamp)
    os.makedirs(target_dir, exist_ok=True)

    moved = 0
    for fn in os.listdir(DATA_DIR):
        if fn.lower().endswith(".csv"):
            src = os.path.join(DATA_DIR, fn)
            dst = os.path.join(target_dir, fn)
            try:
                shutil.move(src, dst)
                moved += 1
            except Exception as e:
                print(f"⚠️ Could not move {fn}: {e}")

    last_session_state = None
    print(f"🗑️ Archived {moved} file(s) to {target_dir}")
    return {"status": "ok", "archived": moved, "archive_dir": target_dir}

# ─────────────────────────────────────────────
# BLE Device Manager with watchdog
# ─────────────────────────────────────────────
devices: Dict[str, "DeviceManager"] = {}
scan_lock = asyncio.Lock()


def be_u16(b, o): return (b[o] << 8) | b[o + 1]
def be_u32(b, o): return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]


class DeviceManager:
    """Handles BLE connection, events, and auto-reconnect watchdog."""

    def __init__(self, addr, name):
        self.addr = addr
        self.name = name
        self.client: Optional[BleakClient] = None
        self.connected = False
        self.sess_id = None
        self.csv_file = None
        self._stop = False
        self._wd_task: Optional[asyncio.Task] = None
        self.last_shot_time = None
        self.api_version = "?"
        self.model = self._get_model()

    def _get_model(self):
        """Extract model type from BLE name pattern."""
        if not self.name or len(self.name) < 8:
            return "Unknown Model"
        code = self.name[7].upper()
        if code == "A":
            return "SG Timer Sport"
        elif code == "B":
            return "SG Timer GO"
        return "Unknown Model"

    async def connect(self):
        """Connect to BLE device and subscribe for events."""
        try:
            if self.client and self.client.is_connected:
                return

            self.client = BleakClient(self.addr)
            await self.client.connect()
            self.connected = True

            # ───────────── Read API version correctly ─────────────
            try:
                await asyncio.sleep(0.5)
                data = await self.client.read_gatt_char(API_VERSION_UUID)
                if data:
                    decoded = ''.join(chr(b) for b in data if 32 <= b <= 126).strip()
                    self.api_version = decoded or "Unknown"
                else:
                    self.api_version = "Unknown"
            except Exception as e:
                print(f"⚠️ Could not read API version: {e}")
                self.api_version = "Unavailable"

            print(f"✅ Connected to {self.name} ({self.addr}) [{self.model}] API v{self.api_version}")

            await broadcast({
                "type": "DEVICE_CONNECTED",
                "addr": self.addr,
                "name": self.name,
                "model": self.model,
                "api_version": self.api_version,
            })

            await self.client.start_notify(EVENT_UUID, self.handle_event)

            if not self._wd_task or self._wd_task.done():
                self._stop = False
                self._wd_task = asyncio.create_task(self._watchdog())

        except Exception as e:
            self.connected = False
            await broadcast({"type": "ERROR", "message": f"connect failed: {e}"})


    async def disconnect(self):
        """Manually stop notifications and disconnect."""
        self._stop = True
        if self._wd_task and not self._wd_task.done():
            self._wd_task.cancel()
        try:
            if self.client and self.client.is_connected:
                await self.client.stop_notify(EVENT_UUID)
                await self.client.disconnect()
        except Exception:
            pass
        self.connected = False
        print(f"⚠️ Disconnected from {self.name} ({self.addr}) [{self.model}]")
        await broadcast({
            "type": "DEVICE_DISCONNECTED",
            "addr": self.addr,
            "name": self.name,
            "model": self.model,
            "api_version": self.api_version,
        })

    async def _watchdog(self):
        """Reconnect automatically if BLE link drops."""
        while not self._stop:
            await asyncio.sleep(5)
            try:
                if not self.client or not self.client.is_connected:
                    self.connected = False
                    await broadcast({
                        "type": "WATCHDOG",
                        "status": "disconnected",
                        "addr": self.addr,
                        "name": self.name,
                        "model": self.model,
                        "api_version": self.api_version,
                    })
                    try:
                        await self.connect()
                        await broadcast({
                            "type": "WATCHDOG",
                            "status": "reconnected",
                            "addr": self.addr,
                            "name": self.name,
                            "model": self.model,
                            "api_version": self.api_version,
                        })
                    except Exception as e:
                        await broadcast({
                            "type": "WATCHDOG",
                            "status": f"retry_failed:{e}",
                            "addr": self.addr,
                            "name": self.name,
                        })
            except asyncio.CancelledError:
                break
            except Exception as e:
                await broadcast({
                    "type": "WATCHDOG",
                    "status": f"error:{e}",
                    "addr": self.addr,
                    "name": self.name,
                })

    async def handle_event(self, _h, data: bytearray):
        """Parse BLE event notifications and broadcast."""
        global session_state, last_session_state

        b = bytearray(data)
        if not b:
            return

        event_id = b[1]
        etype = EVENT_TYPES.get(event_id, "UNKNOWN")
        msg = {"type": etype, "addr": self.addr}

        # ───────────── Session Start ─────────────
        if etype == "SESSION_STARTED":
            self.sess_id = be_u32(b, 2) or int(time.time())
            fn = os.path.join(DATA_DIR, f"{self.sess_id}.csv")
            self.csv_file = open(fn, "w", newline="")
            self.csv_file.write("event,shot_num,shot_time,split,ts_device\n")
            self.csv_file.flush()

            self.last_shot_time = None
            msg["sess_id"] = self.sess_id

            session_state = {
                "active": True,
                "status": "LIVE",
                "shots": [],
                "first_shot": 0.0,
                "best_split": 0.0,
                "total_time": 0.0,
                "sess_id": self.sess_id,
            }

        # ───────────── Shot Detected ─────────────
        elif etype == "SHOT_DETECTED":
            shot_num = be_u16(b, 6) + 1
            shot_time_ms = be_u32(b, 8)
            shot_time = shot_time_ms / 1000.0
            ts_device = shot_time_ms

            split_time = ""
            if self.last_shot_time is not None:
                split_time = shot_time - self.last_shot_time
            self.last_shot_time = shot_time

            msg.update(
                {"num": shot_num, "time": shot_time, "split": split_time if split_time != "" else None}
            )

            # Update memory session state
            if session_state.get("active"):
                session_state["shots"].append({"num": shot_num, "time": shot_time})
                session_state["total_time"] = shot_time
                if len(session_state["shots"]) == 1:
                    session_state["first_shot"] = shot_time
                elif len(session_state["shots"]) > 1:
                    split = shot_time - session_state["shots"][-2]["time"]
                    if session_state["best_split"] == 0 or split < session_state["best_split"]:
                        session_state["best_split"] = split

            # Write to CSV
            if self.csv_file:
                split_str = f"{split_time:.3f}" if split_time != "" else ""
                self.csv_file.write(
                    f"SHOT_DETECTED,{shot_num},{shot_time:.3f},{split_str},{ts_device}\n"
                )
                self.csv_file.flush()

        # ───────────── Session Stop ─────────────
        elif etype == "SESSION_STOPPED":
            if self.csv_file:
                self.csv_file.close()
                self.csv_file = None
            self.last_shot_time = None

            session_state["active"] = False
            session_state["status"] = "STOPPED"
            last_session_state = dict(session_state)

        await broadcast(msg)

# ─────────────────────────────────────────────
# REST Endpoints
# ─────────────────────────────────────────────
@app.get("/devices")
async def list_devices():
    """Scan and return devices with name, address, and model."""
    async with scan_lock:
        try:
            devs = await BleakScanner.discover(timeout=4.0)
        except Exception as e:
            raise HTTPException(500, f"BLE scan failed: {e}")

    results = []
    for d in devs:
        if d.name and d.name.startswith(NAME_PREFIX):
            code = d.name[7].upper() if len(d.name) > 7 else "?"
            model = "SG Timer Sport" if code == "A" else "SG Timer GO" if code == "B" else "Unknown Model"
            results.append({"name": d.name, "address": d.address, "model": model})
    return {"devices": results}

@app.post("/connect")
async def connect_device(body: dict):
    addr = body.get("address")
    name = body.get("name", None)
    if not addr:
        raise HTTPException(400, "Missing address")

    dm = devices.get(addr)
    if not dm:
        dm = DeviceManager(addr, name or addr)
        devices[addr] = dm
    else:
        dm.name = name or dm.name
    await dm.connect()
    return {
        "status": "connected",
        "address": addr,
        "name": dm.name,
        "model": dm.model,
        "api_version": dm.api_version,
    }

@app.post("/disconnect")
async def disconnect_device(body: dict):
    addr = body.get("address")
    dm = devices.get(addr)
    if not dm:
        return {"status": "not connected"}
    await dm.disconnect()
    return {"status": "disconnected", "address": addr}

# ─────────────────────────────────────────────
# Title Management
# ─────────────────────────────────────────────
@app.get("/get_title")
def get_title():
    """Return current saved title."""
    if not os.path.exists(TITLE_FILE):
        return {"title": "SG Timer"}
    with open(TITLE_FILE) as f:
        title = f.read().strip()
    return {"title": title}

@app.post("/set_title")
async def set_title(body: dict):
    """Set and broadcast new competition title."""
    title = body.get("title", "").strip()
    if not title:
        raise HTTPException(400, "Missing title")
    with open(TITLE_FILE, "w") as f:
        f.write(title)
    await broadcast({"type": "TITLE_UPDATE", "title": title})
    return {"status": "ok", "title": title}

@app.get("/status")
async def get_status():
    """Return the current BLE connection state."""
    connected_devices = []
    for addr, dm in devices.items():
        connected_devices.append(
            {
                "address": addr,
                "name": dm.name,
                "model": dm.model,
                "api_version": dm.api_version,
                "connected": bool(dm.client and dm.client.is_connected),
            }
        )
    return {
        "connected": any(d["connected"] for d in connected_devices),
        "devices": connected_devices,
    }

# ─────────────────────────────────────────────
# Mount static files
# ─────────────────────────────────────────────
app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")

if __name__ == "__main__":
    import uvicorn
    import configparser

    print(f"Starting SG Timer BLE Server v{__version__}...")

    # ───────────── Load settings.ini ─────────────
    config = configparser.ConfigParser()
    settings_path = os.path.join(BASE_DIR, "settings.ini")
    host = "0.0.0.0"
    port = 8000

    if os.path.exists(settings_path):
        config.read(settings_path)
        if "network" in config:
            host = config["network"].get("host", host)
            port = config["network"].getint("port", port)

    print(f"🌐 Running on http://{host}:{port}")

    # ───────────── Start server ─────────────
    if getattr(sys, "frozen", False):
        uvicorn.run(app, host=host, port=port, log_level="info")
    else:
        uvicorn.run("server:app", host=host, port=port, log_level="debug", reload=True)