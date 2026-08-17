👉 [Download from Releases](https://github.com/serran0/sgtimer-ble/releases)

Talk to Timur

## Requirements

Python 3.10–3.14 (any of these works — `bleak`'s WinRT backend no longer
splits behavior by Python version). `pip install -r requirements.txt` pulls
prebuilt wheels for every pinned dependency, including compiled ones
(`pydantic-core`, `watchfiles`, and Windows' own `winrt-*` packages) — no
Rust or C++ toolchain needed on a plain machine.

## Pairing (BLE API 3.2 and newer)

Newer SG timer firmware only serves its data over a **bonded** Bluetooth link,
and the bond has to be confirmed on the timer *and* here. The confirmation is
part of the Bluetooth pairing ceremony itself — there is no pairing
characteristic in the BLE attribute table — so the server drives the ceremony
through the host Bluetooth stack (WinRT custom pairing on Windows).

To pair a timer:

1. On the timer: **Settings → Bluetooth → Pairing mode → On**. It stays open
   for 60 seconds.
2. In the admin panel: **Scan**, pick the timer, then press **Pair**
   (or just press **Connect** — an unpaired timer is paired automatically).
3. A dialog shows the confirmation code. Check that it matches the code on the
   timer, then confirm in **both** places.

Pairing connects the timer as soon as it succeeds — there is no need to press
**Connect** afterwards. (`POST /pair` accepts `connect: false` to pair only.)

Once bonded, the timer reconnects on its own; the watchdog never re-prompts
mid-stage. Use **Forget** if the timer was reset or has forgotten this PC —
that clears the stale bond so you can pair again from scratch.

A timer that is already in a connection stops advertising, and it usually
holds the link straight after pairing. Because of that the server always
connects using the `BLEDevice` kept from the last scan rather than the bare
address — connecting by address makes bleak wait for an advertisement that
a busy timer will never send, which is why pairing used to be followed by a
mandatory power cycle. **Scan before pairing** so that object exists.

### Endpoints

| Endpoint | Purpose |
| --- | --- |
| `POST /pair` | Start a ceremony — `{"address": "...", "name": "..."}` |
| `POST /pair/confirm` | Answer it — `{"address": "...", "accept": true, "pin": "..."}` |
| `GET /pair/pending` | The ceremony awaiting an answer, if any |
| `POST /unpair` | Drop the bond — `{"address": "..."}` |

`/devices`, `/connect` and `/status` also report a `paired` flag (`null` when
the platform cannot tell).

WebSocket clients receive `PAIRING_STARTED`, `PAIRING_REQUEST` (carries the
code), `PAIRING_RESULT`, `PAIRING_CANCELLED`, `PAIRING_REQUIRED` and
`UNPAIRED`. A pending request is replayed to newly connected clients, so
reloading the admin page mid-ceremony does not lose the prompt.

## Naming timers

Every SG timer advertises as `SG-SST4…` plus a serial number, which makes a
rack of them hard to tell apart. The admin panel's **Timer name** field sets
an alias per Bluetooth address, stored server-side in `aliases.json` next to
the exe — so the name is the same on every browser and machine, and shows up
in the device list, the connection hint and the console.

Named timers stay listed in the dropdown (marked `· saved`) even when they
are not currently advertising, so they can be identified and renamed without
scanning first.

## Display appearance

**Main Title** may be left blank — the overlay then hides the title entirely
rather than reserving space for it. Use **Clear** or just submit an empty
field.

**Display Text Size** sets three independent scales: the main title, the
session stats block, and the shot/split ticker. They are percentages of the
stylesheet's own sizes, which are `vw`-based — so the overlay keeps scaling
with whatever screen it is projected onto instead of being pinned to one
resolution. Settings live in `display.json` next to the exe, are shared by
every connected display, and apply live over the websocket.

## Overlay inactivity clear (display page)

`index.html` normally keeps showing a session's stats until the next
`SESSION_STARTED`, including after `SESSION_SUSPENDED` or `SESSION_STOPPED` —
useful right after a run, but stale if the next shooter is a while off. After
60 seconds in a non-LIVE state with no new session, the overlay blanks the
times/shot list on screen. The underlying data is kept in JS memory (not
cleared, not just localStorage), so a late `SESSION_RESUMED` restores exactly
where it left off. The clear never fires while LIVE, so a slow shooter
mid-string is unaffected.
