#!/usr/bin/env python3
__version__ = "1.2.1"

import configparser
import asyncio
import json
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
from pairing import PairingManager, PairingError, pairing_required

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
ALIASES_FILE = os.path.join(BASE_DIR, "aliases.json")
DISPLAY_FILE = os.path.join(BASE_DIR, "display.json")

# Create base folders on startup
os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(ARCHIVE_ROOT, exist_ok=True)
if not os.path.exists(TITLE_FILE):
    with open(TITLE_FILE, "w") as f:
        f.write("SG Timer")

# ─────────────────────────────────────────────
# Ensure settings.ini exists (create or extract default)
# ─────────────────────────────────────────────
import configparser

SETTINGS_FILE = os.path.join(BASE_DIR, "settings.ini")
DEFAULT_SETTINGS = """[network]
host = 0.0.0.0
port = 8080
"""

try:
    # Check if it already exists
    if not os.path.exists(SETTINGS_FILE):
        if getattr(sys, "frozen", False):
            # Running as EXE → try to copy bundled one from _MEIPASS
            possible_src = os.path.join(sys._MEIPASS, "settings.ini")
            if os.path.exists(possible_src):
                shutil.copy(possible_src, SETTINGS_FILE)
                print(f"✅ Extracted default settings.ini from bundle → {SETTINGS_FILE}")
            else:
                # Fallback → create new file with defaults
                with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
                    f.write(DEFAULT_SETTINGS)
                print(f"✅ Created new default settings.ini → {SETTINGS_FILE}")
        else:
            # Running from source → create default file
            with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
                f.write(DEFAULT_SETTINGS)
            print(f"✅ Created new default settings.ini → {SETTINGS_FILE}")
    else:
        print(f"ℹ️ Using existing settings.ini at {SETTINGS_FILE}")
except Exception as e:
    print(f"⚠️ Could not initialize settings.ini: {e}")

# ─────────────────────────────────────────────
# BLE service details
# ─────────────────────────────────────────────
SERVICE_UUID = "7520ffff-14d2-4cda-8b6b-697c554c9311"
EVENT_UUID = "75200001-14d2-4cda-8b6b-697c554c9311"
API_VERSION_UUID = "7520fffe-14d2-4cda-8b6b-697c554c9311"  # ✅ Corrected UUID
NAME_PREFIX = "SG-SST"

# Attempts allowed when opening the GATT link right after pairing, while the
# stack releases the link the pairing ceremony used.
CONNECT_ATTEMPTS = 4
CONNECT_RETRY_DELAY = 2.0

# ─────────────────────────────────────────────
# Device aliases and display settings
# ─────────────────────────────────────────────
# Both live next to the exe alongside title.txt, so they survive upgrades and
# are shared by every browser that opens the UI — a font size or a timer name
# set on the operator's laptop still applies to the display screen.

# Font sizes are stored as a percentage of the stylesheet's own vw-based
# sizes rather than absolute values: the overlay has to stay readable on
# whatever screen it is projected onto, and a fixed px size would break that.
DEFAULT_DISPLAY = {"title_scale": 100, "stats_scale": 100, "ticker_scale": 100}
SCALE_MIN, SCALE_MAX = 25, 400


def _load_json(path: str, default: dict) -> dict:
    try:
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                return data
    except Exception as e:
        print(f"⚠️ Could not read {os.path.basename(path)}: {e}")
    return dict(default)


def _save_json(path: str, data: dict) -> None:
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        print(f"⚠️ Could not write {os.path.basename(path)}: {e}")


aliases: Dict[str, str] = _load_json(ALIASES_FILE, {})
display_settings: Dict[str, int] = {**DEFAULT_DISPLAY, **_load_json(DISPLAY_FILE, {})}


def alias_for(addr: str) -> Optional[str]:
    """The operator's name for a timer, if one was set."""
    return aliases.get((addr or "").upper()) or None


def display_name(addr: str, name: Optional[str]) -> str:
    """Alias if there is one, otherwise the BLE name."""
    return alias_for(addr) or name or addr


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
        # send current title (may legitimately be blank) and appearance
        if os.path.exists(TITLE_FILE):
            with open(TITLE_FILE, encoding="utf-8") as f:
                title = f.read().strip()
                await ws.send_json({"type": "TITLE_UPDATE", "title": title})
        await ws.send_json({"type": "DISPLAY_SETTINGS", "settings": display_settings})

        # send retained session state if any
        if session_state.get("sess_id"):
            await ws.send_json({"type": "SESSION_SYNC", "state": session_state})
        elif last_session_state:
            await ws.send_json({"type": "SESSION_SYNC", "state": last_session_state})

        # a pairing confirmation may already be waiting — replay it so a
        # freshly opened admin page can still answer it
        req = pairing_mgr.pending()
        if req:
            await ws.send_json({"type": "PAIRING_REQUEST", **req})

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


# Handles the Bluetooth pairing ceremony the timer requires from API 3.2 on,
# forwarding the confirmation code to the admin UI.
pairing_mgr = PairingManager(broadcast)

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

# BLEDevice objects kept from the last scan, keyed by address.
#
# Connecting by address string makes bleak wait for an advertisement before
# it will even try, and a BLE peripheral stops advertising while it is in a
# connection — so once the timer is holding the link (as it does right after
# pairing) that path can never succeed, no matter how often it is retried.
# A BLEDevice carries the address bleak actually needs, letting it connect
# to a timer that is not advertising instead of demanding a power cycle.
discovered: Dict[str, object] = {}


def _explain_connect_failure(err: Exception, had_ble_device: bool) -> str:
    """Add the missing context to bleak's 'device was not found'.

    That error means no advertisement arrived, which usually means the timer
    is already in a connection rather than switched off.
    """
    text = str(err)
    if "was not found" in text.lower() and not had_ble_device:
        return (
            f"{text} — the timer is not advertising. It stops advertising "
            "while connected to something else, so disconnect it there (or "
            "power-cycle it), then press Scan before connecting."
        )
    return text


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
        self.paired: Optional[bool] = None
        self.last_error: Optional[str] = None
        self.ble_device = None
        self.alias = alias_for(addr)
        self._stale_clients: list = []
        self.os_link_held = False
        self._pairing_hint_sent = False

    @property
    def label(self) -> str:
        """What to call this timer in logs and broadcasts."""
        return self.alias or self.name

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

    async def pair(self) -> dict:
        """Run the pairing ceremony, asking the operator to confirm the code."""
        await broadcast({
            "type": "PAIRING_STARTED",
            "addr": self.addr,
            "name": self.label,
            "model": self.model,
        })
        try:
            result = await pairing_mgr.pair(self.addr, self.name, client=self.client)
        except PairingError as e:
            self.paired = False
            await broadcast({
                "type": "PAIRING_RESULT",
                "ok": False,
                "addr": self.addr,
                "name": self.label,
                "message": str(e),
            })
            raise

        self.paired = result.get("paired")
        self._pairing_hint_sent = False
        print(f"🔐 Pairing {result['status']}: {self.name} ({self.addr})")
        await broadcast({
            "type": "PAIRING_RESULT",
            "ok": True,
            "addr": self.addr,
            "name": self.label,
            "status": result["status"],
            "detail": result.get("detail"),
        })
        return result

    async def _resolve_target(self):
        """Return the best handle to connect with: a BLEDevice if we have one.

        Falls back to the bare address, which only works while the timer is
        advertising — so scan once first if this device was never seen in
        this session.
        """
        if self.ble_device is None:
            self.ble_device = discovered.get(self.addr)
        if self.ble_device is None:
            try:
                async with scan_lock:
                    for d in await BleakScanner.discover(timeout=4.0):
                        if d.address:
                            discovered[d.address] = d
                self.ble_device = discovered.get(self.addr)
            except Exception as e:
                print(f"⚠️ Could not scan before connecting: {e}")
        return self.ble_device or self.addr

    async def _open_link(self):
        """Bring up the GATT link: connect, read API version, subscribe."""
        # Never leave a previous handle behind: the timer serves one client,
        # and an orphaned BleakClient keeps holding that slot.
        if self.client is not None:
            await self._drop_link()

        self.client = BleakClient(self.ble_device or self.addr)
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
            # An unbonded link is reported here first — let the caller pair
            # and retry instead of hiding it behind "Unavailable".
            if pairing_required(e):
                raise
            print(f"⚠️ Could not read API version: {e}")
            self.api_version = "Unavailable"

        await self.client.start_notify(EVENT_UUID, self.handle_event)

    async def _open_link_with_retries(self, attempts: int = CONNECT_ATTEMPTS):
        """Open the GATT link, retrying while the Bluetooth stack settles.

        Straight after pairing, Windows may still be holding the link the
        ceremony used, and the timer accepts only one client — so the first
        attempt can be refused through no fault of ours.
        """
        last_error = None
        for attempt in range(1, attempts + 1):
            try:
                await self._open_link()
                return
            except Exception as e:
                last_error = e
                await self._drop_link()
                if attempt == attempts:
                    break
                delay = CONNECT_RETRY_DELAY * attempt
                print(f"⏳ Connect attempt {attempt}/{attempts} failed ({e}) — retrying in {delay:.0f}s")
                await broadcast({
                    "type": "CONNECT_RETRY",
                    "addr": self.addr,
                    "name": self.label,
                    "attempt": attempt,
                    "attempts": attempts,
                    "message": str(e),
                })
                await asyncio.sleep(delay)
        raise last_error

    async def _drop_link(self):
        """Tear down a half-open link before retrying.

        Clears the handle either way. If the disconnect fails the client is
        remembered instead of discarded — a forgotten client still holds the
        timer's only connection slot, which made a later Disconnect look like
        it did nothing.
        """
        client, self.client = self.client, None
        if client is not None:
            try:
                await client.disconnect()
            except Exception as e:
                print(f"⚠️ Could not drop half-open link: {e}")
                self._stale_clients.append(client)
        self.connected = False

    async def _release_stale_clients(self) -> None:
        """Retry disconnecting handles that would not go down earlier."""
        stale, self._stale_clients = self._stale_clients, []
        for client in stale:
            try:
                await client.disconnect()
            except Exception as e:
                print(f"⚠️ A stale connection would not close: {e}")

    async def connect(self, allow_pairing: bool = True, just_paired: bool = False) -> bool:
        """Connect to BLE device and subscribe for events.

        From BLE API 3.2 the timer only serves a bonded link, so pair first
        when the host has no bond yet, and pair-then-retry if the timer
        refuses the attributes of an unbonded connection.
        """
        try:
            if self.client and self.client.is_connected:
                return True

            # Resolve once, before any pairing: the timer is most likely to be
            # advertising now, and after pairing it may go quiet.
            await self._resolve_target()

            # A caller that has just run the ceremony gets the same settle
            # allowance as one that paired inside this call.
            paired_now = just_paired
            if allow_pairing:
                self.paired = await pairing_mgr.is_paired(self.addr)
                if self.paired is False:
                    print(f"🔐 No bond for {self.name} ({self.addr}) — pairing first")
                    await self.pair()
                    paired_now = True

            try:
                # A freshly paired timer needs a few seconds before it will
                # accept a client again; an already bonded one should answer
                # straight away, so only retry when we just paired.
                await self._open_link_with_retries(
                    CONNECT_ATTEMPTS if paired_now else 1
                )
            except Exception as e:
                # Pairing once more cannot help if we just did it.
                if paired_now or not (allow_pairing and pairing_required(e)):
                    raise
                print(f"🔐 Timer requires pairing: {e}")
                await self._drop_link()
                await self.pair()
                await self._open_link_with_retries()

            self.os_link_held = False
            print(f"✅ Connected to {self.name} ({self.addr}) [{self.model}] API v{self.api_version}")

            await broadcast({
                "type": "DEVICE_CONNECTED",
                "addr": self.addr,
                "name": self.label,
                "model": self.model,
                "api_version": self.api_version,
                "paired": self.paired,
            })

            if not self._wd_task or self._wd_task.done():
                self._stop = False
                self._wd_task = asyncio.create_task(self._watchdog())
            return True

        except Exception as e:
            self.connected = False
            self.last_error = _explain_connect_failure(e, bool(self.ble_device))
            await broadcast({"type": "ERROR", "message": f"connect failed: {self.last_error}"})
            return False

    async def disconnect(self) -> bool:
        """Manually stop notifications and drop the link.

        Unsubscribing and disconnecting are attempted independently: a
        failing stop_notify must not skip the disconnect itself, which is
        what previously left the timer connected while the UI reported
        otherwise.
        """
        self._stop = True
        if self._wd_task and not self._wd_task.done():
            self._wd_task.cancel()

        # Anything left over from a retried connect holds the timer's single
        # slot just as firmly as the current handle does.
        await self._release_stale_clients()

        client, self.client = self.client, None
        still_connected = False

        if client is not None:
            try:
                if client.is_connected:
                    await client.stop_notify(EVENT_UUID)
            except Exception as e:
                print(f"⚠️ Could not stop notifications: {e}")

            try:
                await client.disconnect()
            except Exception as e:
                self.last_error = str(e)
                print(f"⚠️ Disconnect failed: {e}")

            try:
                still_connected = bool(client.is_connected)
            except Exception:
                still_connected = False

        # bleak closing its GATT session does not necessarily end the OS-level
        # connection — the timer can still show a client attached while the
        # app believes it disconnected. Ask the stack to let go as well.
        os_status = None
        try:
            os_status = await pairing_mgr.release_link(self.addr, settle=0)
        except Exception as e:
            print(f"⚠️ Could not release the OS-level link: {e}")

        # Two distinct facts: whether we still hold a GATT session, and
        # whether the radio link is up at all. Our session can be closed while
        # the timer still shows a client attached, so keep them apart.
        self.os_link_held = bool(
            os_status
            and os_status.upper().endswith("CONNECTED")
            and "DIS" not in os_status.upper()
        )
        if os_status:
            print(f"ℹ️ Windows reports the timer as {os_status} after disconnect")
        if self.os_link_held:
            self.last_error = (
                "Windows still reports a connection to the timer. Another app "
                "may be holding it, or the bond keeps it open — use Forget to "
                "drop the pairing if it persists."
            )

        self.connected = still_connected
        if still_connected:
            # Put the client back: it is still the live handle to the timer.
            self.client = client
            print(f"⚠️ {self.name} ({self.addr}) is still connected after disconnect")
        else:
            print(f"⚠️ Disconnected from {self.name} ({self.addr}) [{self.model}]")

        await broadcast({
            "type": "DEVICE_DISCONNECTED" if not still_connected else "ERROR",
            "addr": self.addr,
            "name": self.label,
            "model": self.model,
            "api_version": self.api_version,
            "os_link_held": self.os_link_held,
            "message": "Disconnect did not take effect — the timer still "
                       "reports a connection" if still_connected else None,
        })
        if self.os_link_held:
            await broadcast({
                "type": "LINK_STILL_HELD",
                "addr": self.addr,
                "name": self.label,
                "message": self.last_error,
            })
        return not (still_connected or self.os_link_held)

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
                        "name": self.label,
                        "model": self.model,
                        "api_version": self.api_version,
                    })
                    try:
                        # Never pop a pairing prompt from the watchdog — a
                        # silent reconnect must not hijack the operator's
                        # screen mid-stage. Tell them to re-pair instead.
                        if await self.connect(allow_pairing=False):
                            await broadcast({
                                "type": "WATCHDOG",
                                "status": "reconnected",
                                "addr": self.addr,
                                "name": self.label,
                                "model": self.model,
                                "api_version": self.api_version,
                            })
                        elif not self._pairing_hint_sent and self.last_error and pairing_required(
                            Exception(self.last_error)
                        ):
                            self._pairing_hint_sent = True
                            await broadcast({
                                "type": "PAIRING_REQUIRED",
                                "addr": self.addr,
                                "name": self.label,
                                "message": "The timer no longer accepts this "
                                "connection — enable pairing mode on the timer "
                                "and press Pair.",
                            })
                    except Exception as e:
                        await broadcast({
                            "type": "WATCHDOG",
                            "status": f"retry_failed:{e}",
                            "addr": self.addr,
                            "name": self.label,
                        })
            except asyncio.CancelledError:
                break
            except Exception as e:
                await broadcast({
                    "type": "WATCHDOG",
                    "status": f"error:{e}",
                    "addr": self.addr,
                    "name": self.label,
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
            # Keep the BLEDevice: it lets us reconnect later even once the
            # timer has stopped advertising.
            discovered[d.address] = d
            code = d.name[7].upper() if len(d.name) > 7 else "?"
            model = "SG Timer Sport" if code == "A" else "SG Timer GO" if code == "B" else "Unknown Model"
            # Bond state is reported from what we already know rather than
            # queried here: asking the stack means opening a device object
            # per hit, and a scan must never hold a link to the timer.
            dm = devices.get(d.address)
            results.append({
                "name": d.name,
                "alias": alias_for(d.address),
                "label": display_name(d.address, d.name),
                "address": d.address,
                "model": model,
                "paired": dm.paired if dm else None,
            })
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
    ok = await dm.connect()
    return {
        "status": "connected" if ok else "failed",
        "address": addr,
        "name": dm.name,
        "alias": dm.alias,
        "label": dm.label,
        "model": dm.model,
        "api_version": dm.api_version,
        "paired": dm.paired,
        "error": None if ok else dm.last_error,
    }

# ─────────────────────────────────────────────
# Pairing (BLE API 3.2 requires a bonded link)
# ─────────────────────────────────────────────
def _device_for(addr: Optional[str], name: Optional[str] = None) -> "DeviceManager":
    """Fetch the manager for an address, creating one if we never saw it."""
    if not addr:
        raise HTTPException(400, "Missing address")
    dm = devices.get(addr)
    if not dm:
        dm = DeviceManager(addr, name or addr)
        devices[addr] = dm
    return dm


@app.post("/pair")
async def pair_device(body: dict):
    """Pair with a timer and bring the link up.

    Pairing is only ever a means to an end, so the connection follows
    automatically rather than leaving the operator to press Connect as a
    separate step. Pass ``connect: false`` to pair only.
    """
    dm = _device_for(body.get("address"), body.get("name"))
    try:
        result = await dm.pair()
    except PairingError as e:
        raise HTTPException(409, str(e))

    connected = None
    if body.get("connect", True):
        connected = await dm.connect(just_paired=True)

    return {
        "address": dm.addr,
        "name": dm.name,
        "alias": dm.alias,
        "connected": connected,
        "connect_error": None if connected is not False else dm.last_error,
        **result,
    }


@app.post("/pair/confirm")
async def confirm_pairing(body: dict):
    """Answer the pending ceremony — the confirmation done in the app."""
    accept = bool(body.get("accept", True))
    if not pairing_mgr.confirm(body.get("address"), accept, body.get("pin")):
        raise HTTPException(404, "No pairing confirmation is pending")
    return {"status": "accepted" if accept else "rejected"}


@app.get("/pair/pending")
async def pending_pairing(address: Optional[str] = None):
    """The ceremony currently awaiting an answer, if any."""
    return {"pending": pairing_mgr.pending(address)}


@app.post("/unpair")
async def unpair_device(body: dict):
    """Forget the bond, so the timer can be paired again from scratch."""
    addr = body.get("address")
    if not addr:
        raise HTTPException(400, "Missing address")
    dm = devices.get(addr)
    try:
        result = await pairing_mgr.unpair(addr, client=dm.client if dm else None)
    except PairingError as e:
        raise HTTPException(409, str(e))
    if dm:
        dm.paired = False
    await broadcast({"type": "UNPAIRED", "addr": addr, "name": dm.name if dm else addr})
    return {"address": addr, **result}


@app.post("/disconnect")
async def disconnect_device(body: dict):
    addr = body.get("address")
    dm = devices.get(addr)
    if not dm:
        return {"status": "not connected"}
    ok = await dm.disconnect()
    return {
        "status": "disconnected" if ok else "still_connected",
        "address": addr,
        "error": None if ok else dm.last_error,
    }

# ─────────────────────────────────────────────
# Title Management
# ─────────────────────────────────────────────
@app.get("/get_title")
def get_title():
    """Return current saved title. An empty string is a valid title."""
    if not os.path.exists(TITLE_FILE):
        return {"title": "SG Timer"}
    with open(TITLE_FILE, encoding="utf-8") as f:
        title = f.read().strip()
    return {"title": title}

@app.post("/set_title")
async def set_title(body: dict):
    """Set and broadcast the competition title.

    A blank title is allowed and means "show no title at all" — the display
    hides the element rather than reserving space for it.
    """
    title = (body.get("title") or "").strip()
    with open(TITLE_FILE, "w", encoding="utf-8") as f:
        f.write(title)
    await broadcast({"type": "TITLE_UPDATE", "title": title})
    return {"status": "ok", "title": title}


# ─────────────────────────────────────────────
# Display appearance
# ─────────────────────────────────────────────
@app.get("/display_settings")
def get_display_settings():
    """Font scales currently applied to the display overlay."""
    return {"settings": display_settings, "defaults": DEFAULT_DISPLAY}


@app.post("/display_settings")
async def set_display_settings(body: dict):
    """Update one or more font scales, as a percentage of the default size."""
    updated = dict(display_settings)
    for key in DEFAULT_DISPLAY:
        if key not in body or body[key] is None:
            continue
        try:
            value = int(round(float(body[key])))
        except (TypeError, ValueError):
            raise HTTPException(400, f"{key} must be a number")
        if not SCALE_MIN <= value <= SCALE_MAX:
            raise HTTPException(
                400, f"{key} must be between {SCALE_MIN} and {SCALE_MAX}"
            )
        updated[key] = value

    display_settings.update(updated)
    _save_json(DISPLAY_FILE, display_settings)
    await broadcast({"type": "DISPLAY_SETTINGS", "settings": display_settings})
    return {"status": "ok", "settings": display_settings}


# ─────────────────────────────────────────────
# Device aliases
# ─────────────────────────────────────────────
@app.get("/aliases")
def get_aliases():
    """Every saved timer name, keyed by address."""
    return {"aliases": aliases}


@app.post("/alias")
async def set_alias(body: dict):
    """Name a timer, or clear the name by sending an empty string."""
    addr = (body.get("address") or "").strip().upper()
    if not addr:
        raise HTTPException(400, "Missing address")
    alias = (body.get("alias") or "").strip()

    if alias:
        aliases[addr] = alias
    else:
        aliases.pop(addr, None)
    _save_json(ALIASES_FILE, aliases)

    # Keep any live manager's display name in step with the new alias.
    dm = devices.get(addr) or next(
        (d for a, d in devices.items() if a.upper() == addr), None
    )
    if dm:
        dm.alias = alias or None

    await broadcast({"type": "ALIAS_UPDATE", "addr": addr, "alias": alias or None})
    return {"status": "ok", "address": addr, "alias": alias or None}

@app.get("/status")
async def get_status():
    """Return the current BLE connection state."""
    connected_devices = []
    for addr, dm in devices.items():
        connected_devices.append(
            {
                "address": addr,
                "name": dm.name,
                "alias": dm.alias,
                "label": dm.label,
                "model": dm.model,
                "api_version": dm.api_version,
                "connected": bool(dm.client and dm.client.is_connected),
                # the radio link can outlive our GATT session
                "os_link_held": dm.os_link_held,
                "paired": dm.paired,
            }
        )
    return {
        "connected": any(d["connected"] for d in connected_devices),
        "devices": connected_devices,
        "pending_pairing": pairing_mgr.pending(),
        "version": __version__,
    }

# ─────────────────────────────────────────────
# Mount static files
# ─────────────────────────────────────────────
class RevalidatingStaticFiles(StaticFiles):
    """Serve the UI with 'no-cache' so an upgraded build is never shadowed by
    a stale admin page in the operator's browser.

    The server and the UI ship in the same exe, so a cached admin.js from an
    older release can leave new buttons wired to nothing. 'no-cache' still
    allows caching — it just forces an ETag revalidation, so refreshes stay
    cheap (304) while always matching the running server.
    """

    def file_response(self, *args, **kwargs):
        response = super().file_response(*args, **kwargs)
        response.headers["Cache-Control"] = "no-cache"
        return response


app.mount("/", RevalidatingStaticFiles(directory=STATIC_DIR, html=True), name="static")

if __name__ == "__main__":
    import uvicorn
    import configparser

    print(f"Starting SG Timer BLE Server v{__version__}...")

    # ───────────── Load settings.ini ─────────────
    config = configparser.ConfigParser()
    settings_path = os.path.join(BASE_DIR, "settings.ini")
    host = "0.0.0.0"
    port = 8080

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
