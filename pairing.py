#!/usr/bin/env python3
"""BLE link-layer pairing (bonding) support for SG timers.

Firmware implementing BLE API 3.2 keeps the timer's GATT attributes behind a
bonded link. The attribute table in the public BT API document has no pairing
characteristic — the code the timer shows on screen is part of the Bluetooth
pairing ceremony itself, so it has to be answered by the host Bluetooth stack
rather than by a GATT write.

On Windows the ceremony is driven here with WinRT custom pairing: the request
is surfaced to the admin UI (with the numeric code when the timer asks for a
match confirmation) and the operator's answer is what accepts or rejects it,
mirroring the confirmation done on the timer itself. bleak's own
``BleakClient.pair()`` cannot be used for this — it hardcodes the ConfirmOnly
ceremony and accepts every request without asking anyone.

Other platforms fall back to bleak's pairing where it exists.
"""

import asyncio
import sys
from typing import Dict, Optional, Tuple

# Seconds the operator gets to answer. The timer itself leaves pairing mode
# 60 s after it is enabled, so there is no point waiting longer than that.
PAIRING_TIMEOUT = 60.0

# Windows keeps the LE link the pairing ceremony used open after PairAsync
# returns. The timer serves a single client, so that leftover link is enough
# to make the next connect fail; wait for the stack to drop it.
RELEASE_SETTLE = 3.0

IS_WINDOWS = sys.platform == "win32"

# WinRT is imported the same way bleak does it, so PyInstaller picks up the
# very same modules bleak already pulls into the bundle.
_WINRT_ERROR: Optional[str] = None
if IS_WINDOWS:
    try:
        if sys.version_info >= (3, 12):
            from winrt.windows.devices.bluetooth import BluetoothLEDevice
            from winrt.windows.devices.enumeration import (
                DeviceInformation,
                DevicePairingKinds,
                DevicePairingResultStatus,
                DeviceUnpairingResultStatus,
            )
        else:
            from bleak_winrt.windows.devices.bluetooth import BluetoothLEDevice
            from bleak_winrt.windows.devices.enumeration import (
                DeviceInformation,
                DevicePairingKinds,
                DevicePairingResultStatus,
                DeviceUnpairingResultStatus,
            )
    except Exception as e:  # pragma: no cover - depends on the host
        _WINRT_ERROR = str(e)


def _address_to_int(address: str) -> int:
    """Convert 'AA:BB:CC:DD:EE:FF' to the integer WinRT expects."""
    for sep in (":", "-"):
        address = address.replace(sep, "")
    return int(address, 16)


def _enum_name(value) -> str:
    """Best-effort readable name for a WinRT enum value."""
    return getattr(value, "name", None) or str(value)


def pairing_required(err: Exception) -> bool:
    """True when a BLE failure looks like 'the link is not bonded yet'.

    Windows reports this as access denied / unreachable rather than as a clean
    GATT insufficient-authentication error, so match on the usual wordings.
    """
    text = str(err).lower()
    return any(
        marker in text
        for marker in (
            "insufficient authentication",
            "insufficient encryption",
            "not paired",
            "access is denied",
            "access denied",
            "unreachable",
            "0x80070005",
            "0x80070015",
        )
    )


class PairingError(Exception):
    """Raised when a pairing attempt cannot be started or does not succeed."""


class PendingPairing:
    """A ceremony waiting for the operator's answer in the admin UI."""

    def __init__(self, addr: str, name: str, kind: str, pin: Optional[str]):
        self.addr = addr
        self.name = name
        self.kind = kind
        self.pin = pin
        self.future: "asyncio.Future[Tuple[bool, Optional[str]]]" = (
            asyncio.get_running_loop().create_future()
        )

    def as_dict(self) -> dict:
        return {
            "addr": self.addr,
            "name": self.name,
            "kind": self.kind,
            "pin": self.pin,
            "timeout": PAIRING_TIMEOUT,
        }


class PairingManager:
    """Drives pairing ceremonies and routes confirmations from the UI."""

    def __init__(self, broadcast):
        self._broadcast = broadcast
        self._pending: Dict[str, PendingPairing] = {}
        self._locks: Dict[str, asyncio.Lock] = {}

    # ───────────── UI-facing helpers ─────────────
    def pending(self, addr: Optional[str] = None) -> Optional[dict]:
        """The ceremony awaiting an answer, for a given device or any device."""
        if addr:
            req = self._pending.get(addr)
        else:
            req = next(iter(self._pending.values()), None)
        return req.as_dict() if req else None

    def confirm(self, addr: Optional[str], accept: bool, pin: Optional[str] = None) -> bool:
        """Answer a pending ceremony. Returns False if there was none."""
        if addr:
            req = self._pending.get(addr)
        else:
            req = next(iter(self._pending.values()), None)
        if not req or req.future.done():
            return False
        req.future.set_result((accept, pin))
        return True

    def _lock(self, addr: str) -> asyncio.Lock:
        return self._locks.setdefault(addr, asyncio.Lock())

    # ───────────── Platform entry points ─────────────
    async def is_paired(self, addr: str) -> Optional[bool]:
        """Bond state of a device, or None when the platform cannot tell us."""
        if not (IS_WINDOWS and not _WINRT_ERROR):
            return None
        try:
            info = await self._device_information(addr)
            return bool(info.pairing.is_paired)
        except Exception:
            return None

    async def pair(self, addr: str, name: Optional[str] = None, client=None) -> dict:
        """Run a pairing ceremony, prompting the operator to confirm the code."""
        async with self._lock(addr):
            if IS_WINDOWS:
                if _WINRT_ERROR:
                    raise PairingError(f"WinRT pairing unavailable: {_WINRT_ERROR}")
                return await self._pair_winrt(addr, name or addr)
            return await self._pair_fallback(addr, name or addr, client)

    async def unpair(self, addr: str, client=None) -> dict:
        """Drop the bond so the next connect can pair from scratch."""
        async with self._lock(addr):
            if IS_WINDOWS and not _WINRT_ERROR:
                info = await self._device_information(addr)
                result = await info.pairing.unpair_async()
                status = _enum_name(result.status)
                ok = result.status in (
                    DeviceUnpairingResultStatus.UNPAIRED,
                    DeviceUnpairingResultStatus.ALREADY_UNPAIRED,
                )
                if not ok:
                    raise PairingError(f"Could not unpair: {status}")
                return {"status": "unpaired", "detail": status}

            if client is not None:
                try:
                    await client.unpair()
                    return {"status": "unpaired", "detail": "bleak"}
                except Exception as e:
                    raise PairingError(f"Could not unpair: {e}") from e
            raise PairingError("Unpairing is not supported on this platform")

    # ───────────── Windows (WinRT custom pairing) ─────────────
    async def _device_information(self, addr: str):
        device = await BluetoothLEDevice.from_bluetooth_address_async(
            _address_to_int(addr)
        )
        if device is None:
            raise PairingError(
                "Timer not found by the Bluetooth stack — make sure it is "
                "switched on and in range, then scan again"
            )
        try:
            # A fresh DeviceInformation is required: the one hanging off the
            # device object keeps reporting stale pairing state.
            return await DeviceInformation.create_from_id_async(
                device.device_information.id
            )
        finally:
            try:
                device.close()
            except Exception:
                pass

    async def _release_link(self, addr: str, settle: float = RELEASE_SETTLE) -> None:
        """Drop the connection the pairing ceremony leaves behind.

        Windows stays connected to the timer once pairing completes, and the
        timer only serves one client at a time — so without this the next
        connect is refused until the timer is power-cycled. Disposing every
        BluetoothLEDevice reference is what makes the stack let go.
        """
        try:
            device = await BluetoothLEDevice.from_bluetooth_address_async(
                _address_to_int(addr)
            )
            if device is not None:
                device.close()
        except Exception as e:
            print(f"⚠️ Could not release the link after pairing: {e}")
        if settle:
            await asyncio.sleep(settle)

    async def _pair_winrt(self, addr: str, name: str) -> dict:
        info = await self._device_information(addr)
        pairing = info.pairing

        if pairing.is_paired:
            return {"status": "already_paired", "paired": True}
        if not pairing.can_pair:
            raise PairingError(
                "Windows reports this timer cannot be paired — enable "
                "Settings → Bluetooth → Pairing mode on the timer and retry"
            )

        loop = asyncio.get_running_loop()
        custom = pairing.custom
        # Accept every ceremony the timer might pick. Combining the flags can
        # yield a plain int depending on the projection, so coerce it back.
        ceremonies = DevicePairingKinds(
            int(DevicePairingKinds.CONFIRM_ONLY)
            | int(DevicePairingKinds.CONFIRM_PIN_MATCH)
            | int(DevicePairingKinds.DISPLAY_PIN)
            | int(DevicePairingKinds.PROVIDE_PIN)
        )
        kind_names = {
            DevicePairingKinds.CONFIRM_ONLY: "confirm_only",
            DevicePairingKinds.CONFIRM_PIN_MATCH: "confirm_pin_match",
            DevicePairingKinds.DISPLAY_PIN: "display_pin",
            DevicePairingKinds.PROVIDE_PIN: "provide_pin",
        }

        def on_pairing_requested(_sender, args):
            # Runs on a WinRT thread. Take a deferral so the ceremony stays
            # open while the operator answers, then hop onto the event loop.
            deferral = args.get_deferral()
            loop.call_soon_threadsafe(
                lambda: asyncio.ensure_future(
                    self._answer_request(addr, name, args, deferral, kind_names)
                )
            )

        token = custom.add_pairing_requested(on_pairing_requested)
        try:
            result = await custom.pair_async(ceremonies)
        except Exception as e:
            raise PairingError(f"Pairing failed: {e}") from e
        finally:
            custom.remove_pairing_requested(token)
            self._pending.pop(addr, None)

        status = _enum_name(result.status)
        paired = result.status in (
            DevicePairingResultStatus.PAIRED,
            DevicePairingResultStatus.ALREADY_PAIRED,
        )
        if not paired:
            raise PairingError(_explain_failure(status))

        # Hand the timer back before anyone tries to open a GATT link to it.
        await self._release_link(addr)

        return {
            "status": "paired",
            "paired": True,
            "detail": status,
            "protection_level": _enum_name(result.protection_level_used),
        }

    async def _answer_request(self, addr, name, args, deferral, kind_names) -> None:
        """Surface a ceremony to the UI and apply the operator's answer."""
        try:
            kind = kind_names.get(args.pairing_kind, _enum_name(args.pairing_kind))
            try:
                pin = args.pin or None
            except Exception:
                pin = None

            req = PendingPairing(addr, name, kind, pin)
            self._pending[addr] = req
            await self._broadcast({"type": "PAIRING_REQUEST", **req.as_dict()})

            try:
                accept, entered_pin = await asyncio.wait_for(
                    req.future, PAIRING_TIMEOUT
                )
            except asyncio.TimeoutError:
                accept, entered_pin = False, None
                await self._broadcast(
                    {
                        "type": "PAIRING_CANCELLED",
                        "addr": addr,
                        "name": name,
                        "reason": "No confirmation within "
                        f"{int(PAIRING_TIMEOUT)}s",
                    }
                )
            finally:
                self._pending.pop(addr, None)

            if accept:
                _accept(args, entered_pin or pin)
        except Exception as e:
            print(f"⚠️ Pairing request handling failed: {e}")
        finally:
            try:
                deferral.complete()
            except Exception:
                pass

    # ───────────── Other platforms ─────────────
    async def _pair_fallback(self, addr: str, name: str, client) -> dict:
        """Best effort elsewhere: macOS pairs implicitly, BlueZ needs an agent."""
        if sys.platform == "darwin":
            return {
                "status": "os_managed",
                "paired": None,
                "detail": "macOS pairs on first encrypted read; confirm on the timer",
            }
        if client is None:
            raise PairingError("Connect to the timer before pairing on this platform")

        # No ceremony is routed through us here, so tell the operator what to
        # do rather than raising a prompt this end cannot answer.
        await self._broadcast(
            {
                "type": "PAIRING_REQUIRED",
                "addr": addr,
                "name": name,
                "message": "Confirm the pairing request on the timer "
                "(and in your desktop's Bluetooth agent, if it asks).",
            }
        )
        try:
            # bleak >= 1.0 always returns None here and raises on failure
            # instead of returning False, so success is "no exception" —
            # not a check of the awaited value.
            await client.pair()
        except Exception as e:
            raise PairingError(f"Pairing failed: {e}") from e
        return {"status": "paired", "paired": True, "detail": "bleak"}


def _accept(args, pin: Optional[str]) -> None:
    """Accept a ceremony, passing the PIN when the projection wants one."""
    if pin:
        try:
            args.accept(pin)
            return
        except TypeError:
            pass
    args.accept()


def _explain_failure(status: str) -> str:
    """Turn a WinRT pairing status into something an operator can act on."""
    hints = {
        "REJECTED_BY_HANDLER": "Pairing was rejected here",
        "PAIRING_CANCELED": "Pairing was cancelled or timed out — the timer "
        "leaves pairing mode 60s after it is enabled",
        "AUTHENTICATION_TIMEOUT": "The timer did not confirm in time",
        "AUTHENTICATION_FAILURE": "The codes did not match",
        "CONNECTION_REJECTED": "The timer rejected the connection — it may "
        "already remember its maximum number of clients",
        "FAILED": "Pairing failed — enable Settings → Bluetooth → Pairing "
        "mode on the timer and retry within 60s",
        "NOT_READY_TO_PAIR": "The timer is not in pairing mode — enable "
        "Settings → Bluetooth → Pairing mode and retry within 60s",
    }
    return hints.get(status, f"Pairing failed: {status}")
