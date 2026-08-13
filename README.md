👉 [Download from Releases](https://github.com/serran0/sgtimer-ble/releases)

Talk to Timur

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

Once bonded, the timer reconnects on its own; the watchdog never re-prompts
mid-stage. Use **Forget** if the timer was reset or has forgotten this PC —
that clears the stale bond so you can pair again from scratch.

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
