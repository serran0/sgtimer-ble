#!/usr/bin/env python3
__version__ = "0.8.3"

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
# Cross-platform path setup (PyInstaller compatible)
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
API_VERSION_UUID = "7520fffe-14d2-4cda-8b6b-697c554c9311"   # ✅ Corrected UUID
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
# WebSocket Hub
# ─────────────────────────────────────────────
class WsHub:
    def __init__(self):
        self.clients = set()

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.clients.add(ws)
        if os.path.exists(TITLE_FILE):
            with open(TITLE_FILE) as f:
                title = f.read().strip()
                await ws.send_json({"type": "TITLE_UPDATE", "title": title})

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
# BLE Device Manager
# ─────────────────────────────────────────────
devices: Dict[str, "DeviceManager"] = {}
scan_lock = asyncio.Lock()

def be_u16(b, o): return (b[o] << 8) | b[o + 1]
def be_u32(b, o): return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]

class DeviceManager:
    def __init__(self, addr, name):
        self.addr = addr
        self.name = name
        self.client: Optional[BleakClient] = None
        self.connected = False
        self.model = self._get_model()
        self.api_version = "?"

    def _get_model(self):
        if not self.name or len(self.name) < 8:
            return "Unknown Model"
        code = self.name[7].upper()
        return "SG Timer Sport" if code == "A" else "SG Timer GO" if code == "B" else "Unknown Model"

    async def connect(self):
        try:
            self.client = BleakClient(self.addr)
            await self.client.connect()
            self.connected = True

            # Read API version (proper UUID)
            try:
                data = await self.client.read_gatt_char(API_VERSION_UUID)
                if data:
                    version = ''.join(chr(b) for b in data if 32 <= b <= 126).strip()
                    self.api_version = version or "Unknown"
                else:
                    self.api_version = "Unknown"
            except Exception as e:
                print(f"⚠️ Failed to read API version: {e}")
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

        except Exception as e:
            self.connected = False
            print(f"❌ Connection failed: {e}")
            await broadcast({"type": "ERROR", "message": f"connect failed: {e}"})

    async def disconnect(self):
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

    async def handle_event(self, _h, data: bytearray):
        b = bytearray(data)
        if not b:
            return

        event_id = b[1]
        etype = {
            0x00: "SESSION_STARTED",
            0x01: "SESSION_SUSPENDED",
            0x02: "SESSION_RESUMED",
            0x03: "SESSION_STOPPED",
            0x04: "SHOT_DETECTED",
        }.get(event_id, "UNKNOWN")

        msg = {"type": etype, "addr": self.addr}

        if etype == "SESSION_STARTED":
            self.sess_id = be_u32(b, 2) or int(time.time())
            fn = os.path.join(DATA_DIR, f"{self.sess_id}.csv")
            self.csv_file = open(fn, "w", newline="")
            self.csv_file.write("event,shot_num,shot_time,split,ts_device\n")
            self.csv_file.flush()
            msg["sess_id"] = self.sess_id

        elif etype == "SHOT_DETECTED":
            shot_num = be_u16(b, 6) + 1
            shot_time_ms = be_u32(b, 8)
            shot_time = shot_time_ms / 1000.0
            msg.update({"num": shot_num, "time": shot_time})
            if hasattr(self, "csv_file") and self.csv_file:
                self.csv_file.write(f"SHOT_DETECTED,{shot_num},{shot_time:.3f},,\n")
                self.csv_file.flush()

        elif etype == "SESSION_STOPPED":
            if hasattr(self, "csv_file") and self.csv_file:
                self.csv_file.close()
                self.csv_file = None

        await broadcast(msg)

# ─────────────────────────────────────────────
# REST Endpoints
# ─────────────────────────────────────────────
@app.get("/devices")
async def list_devices():
    async with scan_lock:
        devs = await BleakScanner.discover(timeout=4.0)

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
# Static Mount + Startup
# ─────────────────────────────────────────────
app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")

if __name__ == "__main__":
    import uvicorn
    print(f"Starting SG Timer BLE Server v{__version__}...")
    uvicorn.run("server:app", host="0.0.0.0", port=8000, log_level="info")
