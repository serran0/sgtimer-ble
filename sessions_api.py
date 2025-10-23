import os
import csv
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

DATA_DIR = "data"
os.makedirs(DATA_DIR, exist_ok=True)

router = APIRouter()


@router.get("/sessions")
def list_sessions(offset: int = 0, limit: int = 20):
    """
    List recorded sessions with:
      - total shots
      - total time (last shot time)
      - duration (from first to last shot)
      - best split (minimum time difference between shots)
    """
    files = [f for f in os.listdir(DATA_DIR) if f.endswith(".csv")]
    files.sort(reverse=True)
    sliced = files[offset:offset + limit]
    results = []

    for fn in sliced:
        total_shots = 0
        best_split = 0.0
        total_time = 0.0
        duration = 0.0
        first_ts = None
        last_ts = None
        last_shot_ts = None

        path = os.path.join(DATA_DIR, fn)

        try:
            with open(path, newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    if row["event"] == "SHOT_DETECTED":
                        total_shots += 1
                        try:
                            ts_device = int(row.get("ts_device", "0"))
                            shot_time = float(row.get("shot_time", "0"))
                            if first_ts is None:
                                first_ts = ts_device
                            last_ts = ts_device
                            total_time = shot_time

                            # compute best split (min delta)
                            if last_shot_ts is not None:
                                split = (ts_device - last_shot_ts) / 1000.0
                                if best_split == 0.0 or (0 < split < best_split):
                                    best_split = split
                            last_shot_ts = ts_device

                        except ValueError:
                            continue

            if first_ts is not None and last_ts is not None:
                duration = (last_ts - first_ts) / 1000.0

        except Exception as e:
            print(f"Error reading {fn}: {e}")
            continue

        results.append({
            "sess_id": fn.replace(".csv", ""),
            "total_shots": total_shots,
            "best_split": round(best_split, 2),
            "total_time": round(total_time, 2),
            "duration": round(duration, 2),
            "file": fn
        })

    return {"sessions": results, "offset": offset, "limit": limit}


@router.get("/download/{sess_id}")
def download_session(sess_id: str):
    """Download a specific session CSV file."""
    path = os.path.join(DATA_DIR, f"{sess_id}.csv")
    if not os.path.exists(path):
        raise HTTPException(404, "Session not found")
    return FileResponse(path, filename=f"{sess_id}.csv", media_type="text/csv")
