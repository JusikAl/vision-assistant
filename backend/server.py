
import asyncio
import csv
import io
import json
import logging
import math
import os
import threading
import time

from datetime import datetime, timezone
from pathlib import Path

import torch

from fastapi import (
    FastAPI,
    File,
    HTTPException,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)

from PIL import Image, UnidentifiedImageError
from ultralytics import YOLO

from depth_service import DepthService, DEPTH_MODEL_ID
from depth_calibration import calibrate_distance
from depth_stabilizer import DepthStabilizer
from safety_service import SafetyService


# =====================================
# APPLICATION
# =====================================

app = FastAPI(
    title="AI Navigation Assistant",
    version="1.4.0",
)

logger = logging.getLogger("uvicorn.error")

BASE_DIR = Path(__file__).resolve().parent


# =====================================
# CONFIGURATION
# =====================================

DEFAULT_MODEL_PATH = (
    BASE_DIR
    / "experiments"
    / "runs"
    / "yolo26n_full"
    / "weights"
    / "best.pt"
)

MODEL_PATH = Path(
    os.getenv(
        "YOLO_MODEL",
        str(DEFAULT_MODEL_PATH),
    )
)

if not MODEL_PATH.is_absolute():
    MODEL_PATH = BASE_DIR / MODEL_PATH

MODEL_PATH = MODEL_PATH.resolve()

CONFIDENCE = float(
    os.getenv("YOLO_CONF", "0.25")
)

IMAGE_SIZE = int(
    os.getenv("YOLO_IMGSZ", "512")
)

DEPTH_ENABLED = (
    os.getenv("DEPTH_ENABLED", "true").lower()
    in ("true", "1", "yes")
)

DEPTH_SMOOTHING = (
    os.getenv("DEPTH_SMOOTHING", "true").lower()
    in ("true", "1", "yes")
)

SAFETY_ENABLED = (
    os.getenv("SAFETY_ENABLED", "true").lower()
    in ("true", "1", "yes")
)

SAFETY_MIN_CONF = float(
    os.getenv("SAFETY_MIN_CONF", "0.50")
)

DEVICE = (
    0 if torch.cuda.is_available()
    else "cpu"
)


# =====================================
# OPTIONAL LEGACY DEPTH CSV
# =====================================

DEPTH_TEST_CSV = os.getenv(
    "DEPTH_TEST_CSV", ""
).strip()

DEPTH_TEST_MODE = os.getenv(
    "DEPTH_TEST_MODE", "unspecified"
)

DEPTH_TEST_CLASS = os.getenv(
    "DEPTH_TEST_CLASS", ""
).strip()

DEPTH_TEST_DISTANCE_M = os.getenv(
    "DEPTH_TEST_DISTANCE_M", ""
).strip()

csv_lock = threading.Lock()

CSV_FIELDS = [
    "timestamp_utc",
    "mode",
    "actual_distance_m",
    "class_name",
    "confidence",
    "bbox",
    "raw_distance_m",
    "calibrated_distance_m",
    "stabilized_distance_m",
    "yolo_ms",
    "depth_ms",
    "processing_ms",
]


def get_experiment_path():
    if not DEPTH_TEST_CSV:
        return None

    path = Path(DEPTH_TEST_CSV)

    if not path.is_absolute():
        path = BASE_DIR / path

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    return path


EXPERIMENT_PATH = get_experiment_path()


def get_ground_truth_distance():
    try:
        value = float(DEPTH_TEST_DISTANCE_M)

        if math.isfinite(value) and value > 0:
            return value
    except (ValueError, TypeError):
        pass

    return None


def record_experiment(result):
    if EXPERIMENT_PATH is None:
        return

    rows = []

    for detection in result["detections"]:
        if (
            DEPTH_TEST_CLASS
            and detection["class_name"] != DEPTH_TEST_CLASS
        ):
            continue

        rows.append({
            "timestamp_utc": datetime.now(
                timezone.utc
            ).isoformat(),
            "mode": DEPTH_TEST_MODE,
            "actual_distance_m": get_ground_truth_distance(),
            "class_name": detection["class_name"],
            "confidence": detection["confidence"],
            "bbox": json.dumps(detection["bbox"]),
            "raw_distance_m": detection.get(
                "raw_distance_m"
            ),
            "calibrated_distance_m": detection.get(
                "calibrated_distance_m"
            ),
            "stabilized_distance_m": detection.get(
                "distance_m"
            ),
            "yolo_ms": result.get("yolo_ms"),
            "depth_ms": result.get("depth_ms"),
            "processing_ms": result.get("processing_ms"),
        })

    if not rows:
        return

    try:
        with csv_lock:
            exists = (
                EXPERIMENT_PATH.exists()
                and EXPERIMENT_PATH.stat().st_size > 0
            )

            with EXPERIMENT_PATH.open(
                "a",
                newline="",
                encoding="utf-8",
            ) as file:
                writer = csv.DictWriter(
                    file,
                    fieldnames=CSV_FIELDS,
                )

                if not exists:
                    writer.writeheader()

                writer.writerows(rows)

    except OSError:
        logger.exception(
            "Could not write experiment CSV"
        )


# =====================================
# LOAD MODELS
# =====================================

if not MODEL_PATH.is_file():
    raise FileNotFoundError(
        f"YOLO model not found: {MODEL_PATH}"
    )

logger.info(
    "Loading YOLO: %s",
    MODEL_PATH,
)

model = YOLO(str(MODEL_PATH))

logger.info(
    "YOLO classes: %s",
    len(model.names),
)

depth_service = None

if DEPTH_ENABLED:
    depth_service = DepthService()


safety_service = SafetyService(
    min_confidence=0.50,
    center_left=0.35,
    center_right=0.65,
    include_low_priority=True,
)


inference_lock = asyncio.Lock()


# =====================================
# HELPERS
# =====================================

def valid_distance(value):
    if value is None:
        return None

    try:
        value = float(value)
    except (TypeError, ValueError):
        return None

    if not math.isfinite(value):
        return None

    if value <= 0:
        return None

    return value


# =====================================
# YOLO + DEPTH INFERENCE
# =====================================

def predict_image(image_bytes: bytes) -> dict:
    with Image.open(io.BytesIO(image_bytes)) as opened:
        image = opened.convert("RGB")

    # ---------- YOLO ----------

    started = time.perf_counter()

    results = model.predict(
        source=image,
        conf=CONFIDENCE,
        imgsz=IMAGE_SIZE,
        device=DEVICE,
        max_det=100,
        verbose=False,
    )

    if torch.cuda.is_available():
        torch.cuda.synchronize()

    yolo_ms = round(
        (time.perf_counter() - started) * 1000,
        2,
    )

    detections = []

    for result in results:
        for box in result.boxes:
            class_id = int(box.cls[0])

            detections.append({
                "class_name": result.names[class_id],
                "confidence": round(
                    float(box.conf[0]),
                    3,
                ),
                "bbox": [
                    round(float(v), 2)
                    for v in box.xyxy[0].tolist()
                ],
            })

    # ---------- DEPTH ----------
    # Existing depth logic is unchanged.
    # Safety does not use these distances.

    depth_ms = None

    if depth_service is not None:
        depth_map, depth_ms = (
            depth_service.predict(image)
        )

        for detection in detections:
            raw_distance = valid_distance(
                depth_service.object_distance(
                    depth_map,
                    detection["bbox"],
                )
            )

            calibrated = None

            if raw_distance is not None:
                calibrated = valid_distance(
                    calibrate_distance(raw_distance)
                )

            detection["raw_distance_m"] = (
                round(raw_distance, 3)
                if raw_distance is not None
                else None
            )

            detection["calibrated_distance_m"] = (
                round(calibrated, 3)
                if calibrated is not None
                else None
            )

            detection["distance_m"] = (
                round(calibrated, 2)
                if calibrated is not None
                else None
            )

    else:
        for detection in detections:
            detection["raw_distance_m"] = None
            detection["calibrated_distance_m"] = None
            detection["distance_m"] = None

    return {
        "detections": detections,
        "image_width": image.width,
        "image_height": image.height,
        "inference_ms": yolo_ms,
        "yolo_ms": yolo_ms,
        "depth_ms": depth_ms,
        "depth_enabled": (
            depth_service is not None
        ),
        "depth_smoothing": False,
        "processing_device": str(DEVICE),
    }


# =====================================
# ASYNC ANALYSIS
# =====================================

async def analyze(
    image_bytes: bytes,
    stabilizer=None,
) -> dict:
    started = time.perf_counter()

    async with inference_lock:
        result = await asyncio.to_thread(
            predict_image,
            image_bytes,
        )

    # ---------- DEPTH STABILIZATION ----------

    if (
        stabilizer is not None
        and depth_service is not None
    ):
        result["detections"] = stabilizer.update(
            result["detections"]
        )

        result["depth_smoothing"] = True

    # ---------- SAFETY ----------
    # Uses YOLO classes, bounding boxes
    # and confidence ONLY.

    if SAFETY_ENABLED:
        result["safety_alerts"] = (
            safety_service.evaluate(
                detections=result["detections"],
                image_width=result["image_width"],
                image_height=result["image_height"],
            )
        )
    else:
        result["safety_alerts"] = []

    result["processing_ms"] = round(
        (time.perf_counter() - started) * 1000,
        2,
    )

    record_experiment(result)

    return result


# =====================================
# HEALTH CHECK
# =====================================

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "device": str(DEVICE),
        "gpu": (
            torch.cuda.get_device_name(0)
            if torch.cuda.is_available()
            else None
        ),
        "model": MODEL_PATH.name,
        "model_path": str(MODEL_PATH),
        "classes_count": len(model.names),
        "classes": model.names,
        "confidence": CONFIDENCE,
        "image_size": IMAGE_SIZE,
        "depth_enabled": (
            depth_service is not None
        ),
        "depth_model": (
            DEPTH_MODEL_ID
            if depth_service is not None
            else None
        ),
        "depth_smoothing": DEPTH_SMOOTHING,
        "safety_enabled": SAFETY_ENABLED,
        "safety_min_confidence": SAFETY_MIN_CONF,
        "experiment": {
            "enabled": EXPERIMENT_PATH is not None,
            "csv": (
                str(EXPERIMENT_PATH)
                if EXPERIMENT_PATH
                else None
            ),
        },
    }


# =====================================
# HTTP DETECTION
# =====================================

@app.post("/detect")
async def detect(
    file: UploadFile = File(...)
):
    image_bytes = await file.read()

    if not image_bytes:
        raise HTTPException(
            status_code=400,
            detail="Empty image",
        )

    try:
        return await analyze(image_bytes)

    except (
        UnidentifiedImageError,
        OSError,
        ValueError,
    ) as exc:
        raise HTTPException(
            status_code=400,
            detail="Invalid image",
        ) from exc


# =====================================
# WEBSOCKET LIVE DETECTION
# =====================================

@app.websocket("/ws/detect")
async def live_detect(
    websocket: WebSocket
):
    await websocket.accept()

    logger.info(
        "WebSocket client connected"
    )

    stabilizer = (
        DepthStabilizer()
        if (
            DEPTH_SMOOTHING
            and depth_service is not None
        )
        else None
    )

    try:
        while True:
            image_bytes = (
                await websocket.receive_bytes()
            )

            result = await analyze(
                image_bytes,
                stabilizer=stabilizer,
            )

            await websocket.send_text(
                json.dumps(
                    result,
                    separators=(",", ":"),
                )
            )

    except WebSocketDisconnect:
        logger.info(
            "Detection client disconnected"
        )

    except Exception:
        logger.exception(
            "WebSocket detection failed"
        )

        try:
            await websocket.close(code=1011)
        except RuntimeError:
            pass
