#!/usr/bin/env python3
"""Diagnose why a paired SG timer refuses the next connection.

Run it on the Windows machine, in the same venv as the server, with the
server stopped so nothing else is holding the radio:

    python diagnose.py                 # picks the first SG timer it sees
    python diagnose.py AA:BB:CC:DD:EE:FF

It answers, in order:

  1. Is the timer advertising at all?
  2. What does Windows think — paired, and connected to whom?
  3. Can the OS itself read the timer's GATT table (bypassing bleak)?
  4. Can bleak connect, given the scanned device object?
  5. Can bleak connect, given only the address?

Step 3 is the decisive one. If Windows can read services while bleak
cannot, the problem is in how the app drives bleak. If Windows cannot read
them either, the link really is unavailable and the fix has to be to get
the connection dropped rather than to connect differently.

Everything is written to diagnose.log as well as the console.
"""

import asyncio
import logging
import sys
import traceback

LOG_FILE = "diagnose.log"

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s %(name)s %(levelname)s: %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, mode="w", encoding="utf-8")],
)

NAME_PREFIX = "SG-SST"
SERVICE_UUID = "7520ffff-14d2-4cda-8b6b-697c554c9311"
API_VERSION_UUID = "7520fffe-14d2-4cda-8b6b-697c554c9311"


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    logging.info(line)


def fail(label, err):
    say(f"  ✖ {label}: {type(err).__name__}: {err}")
    logging.exception(label)


def section(title):
    say("")
    say("=" * 62)
    say(title)
    say("=" * 62)


def address_to_int(address: str) -> int:
    for sep in (":", "-"):
        address = address.replace(sep, "")
    return int(address, 16)


async def main() -> int:
    section("0. Environment")
    say("  python  :", sys.version.split()[0], f"({sys.platform})")
    try:
        from bleak import BleakClient, BleakScanner
    except Exception as e:
        fail("bleak import", e)
        return 1

    try:
        from importlib.metadata import version

        say("  bleak   :", version("bleak"))
    except Exception:
        say("  bleak   : (version unknown)")

    winrt_ok = False
    if sys.platform == "win32":
        try:
            try:
                from winrt.windows.devices.bluetooth import (
                    BluetoothCacheMode,
                    BluetoothLEDevice,
                )
                from winrt.windows.devices.enumeration import DeviceInformation
            except ImportError:
                from bleak_winrt.windows.devices.bluetooth import (
                    BluetoothCacheMode,
                    BluetoothLEDevice,
                )
                from bleak_winrt.windows.devices.enumeration import DeviceInformation
            winrt_ok = True
            say("  winrt   : available")
        except Exception as e:
            fail("winrt import", e)
    else:
        say("  winrt   : not on Windows — steps 2 and 3 will be skipped")

    # ── 1. advertising? ──────────────────────────────────────────────────
    section("1. Scanning for 10s")
    wanted = sys.argv[1].upper() if len(sys.argv) > 1 else None
    found = {}
    try:
        for d in await BleakScanner.discover(timeout=10.0):
            if d.name and d.name.startswith(NAME_PREFIX):
                found[d.address.upper()] = d
                say(f"  • {d.name}  {d.address}")
    except Exception as e:
        fail("scan", e)

    if not found:
        say("  (no SG timers advertising)")
        say("")
        say("  A timer that is already in a connection does not advertise.")
        say("  If it is switched on and near, something is holding its link.")

    target_addr = wanted or (next(iter(found)) if found else None)
    ble_device = found.get(target_addr) if target_addr else None
    if not target_addr:
        say("\nNothing to test. Pass an address explicitly to continue.")
        return 1

    say(f"\n  target: {target_addr}"
        f"  (scanned object: {'yes' if ble_device else 'no — not advertising'})")

    # ── 2. what Windows thinks ───────────────────────────────────────────
    section("2. Windows' view of the device")
    device = None
    if winrt_ok:
        try:
            device = await BluetoothLEDevice.from_bluetooth_address_async(
                address_to_int(target_addr)
            )
            if device is None:
                say("  ✖ Windows has no record of this device at all.")
            else:
                say("  name             :", device.name)
                say("  connection status:", getattr(device.connection_status, "name",
                                                    device.connection_status))
                try:
                    info = await DeviceInformation.create_from_id_async(
                        device.device_information.id
                    )
                    p = info.pairing
                    say("  is_paired        :", p.is_paired)
                    say("  can_pair         :", p.can_pair)
                    say("  protection level :",
                        getattr(p.protection_level, "name", p.protection_level))
                except Exception as e:
                    fail("pairing info", e)
        except Exception as e:
            fail("from_bluetooth_address_async", e)

    # ── 3. can the OS read GATT without bleak? ───────────────────────────
    section("3. Reading GATT services directly through Windows (no bleak)")
    if winrt_ok and device is not None:
        try:
            result = await device.get_gatt_services_async(BluetoothCacheMode.UNCACHED)
            status = getattr(result.status, "name", result.status)
            say("  status  :", status)
            services = list(result.services or [])
            say("  services:", len(services))
            for s in services:
                say("    -", s.uuid)
            if any(str(s.uuid).lower() == SERVICE_UUID for s in services):
                say("\n  ✔ Windows CAN talk to the timer right now.")
                say("    => the link is usable; the problem is in how the app")
                say("       drives bleak, not the hardware.")
            elif status != "SUCCESS":
                say("\n  ✖ Windows CANNOT talk to the timer.")
                say("    => the link genuinely is not available. The fix has to")
                say("       be releasing the connection, not connecting harder.")
        except Exception as e:
            fail("get_gatt_services_async", e)
    else:
        say("  skipped")

    if device is not None:
        try:
            device.close()
        except Exception:
            pass

    # ── 4. bleak, with the scanned device object ─────────────────────────
    section("4. bleak connect using the scanned BLEDevice")
    if ble_device is None:
        say("  skipped — the timer is not advertising, so there is no object")
    else:
        await try_bleak(BleakClient, ble_device, "BLEDevice")

    # ── 5. bleak, with the bare address ──────────────────────────────────
    section("5. bleak connect using the address string")
    await try_bleak(BleakClient, target_addr, "address")

    # ── 6. does the connection actually end? ─────────────────────────────
    section("6. Does disconnecting really drop the link?")
    if winrt_ok:
        try:
            import gc

            probe = await BluetoothLEDevice.from_bluetooth_address_async(
                address_to_int(target_addr)
            )
            before = getattr(probe.connection_status, "name", "?") if probe else "?"
            if probe is not None:
                probe.close()
            probe = None
            gc.collect()
            await asyncio.sleep(2.0)

            probe = await BluetoothLEDevice.from_bluetooth_address_async(
                address_to_int(target_addr)
            )
            after = getattr(probe.connection_status, "name", "?") if probe else "?"
            if probe is not None:
                probe.close()
            probe = None
            gc.collect()

            say(f"  connection status before releasing handles: {before}")
            say(f"  connection status after  releasing handles: {after}")
            if after == "CONNECTED":
                say("")
                say("  ✖ Windows still holds the link with no handle of ours open.")
                say("    => something outside this app is keeping it: another")
                say("       program, or the Windows stack holding the bond open.")
                say("       Unpairing (Forget) is the reliable way to drop it.")
            else:
                say("\n  ✔ The link drops once our handles are released.")
        except Exception as e:
            fail("connection release probe", e)
    else:
        say("  skipped")

    section("Done")
    say(f"  Full debug log written to {LOG_FILE}")
    say("  Please send the output above plus that file.")
    return 0


async def try_bleak(BleakClient, target, label):
    client = BleakClient(target)
    try:
        say(f"  connecting via {label} ...")
        await client.connect()
        say("  ✔ connected:", client.is_connected)
        try:
            data = await client.read_gatt_char(API_VERSION_UUID)
            say("  ✔ API version:", bytes(data).decode("ascii", "replace"))
        except Exception as e:
            fail("read API version", e)
    except Exception as e:
        say(f"  ✖ connect via {label} failed:")
        say("   ", type(e).__name__, "-", e)
        logging.exception("connect via %s", label)
        for line in traceback.format_exc().splitlines()[-4:]:
            say("   ", line)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
