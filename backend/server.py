
import asyncio
import io
import json
import logging
import os
import time
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


app = FastAPI(
    title="AI Vision Assistant",
    version="1.1.0",
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
    os.getenv("YOLO_MODEL", str(DEFAULT_MODEL_PATH))
)

if not MODEL_PATH.is_absolute():
    MODEL_PATH = BASE_DIR / MODEL_PATH

MODEL_PATH = MODEL_PATH.resolve()

CONFIDENCE = float(os.getenv("YOLO_CONF", "0.25"))
IMAGE_SIZE = int(os.getenv("YOLO_IMGSZ", "512"))

DEPTH_ENABLED = (
    os.getenv("DEPTH_ENABLED", "true").lower()
    in ("true", "1", "yes")
)

DEVICE = 0 if torch.cuda.is_available() else "cpu"

# =====================================
# LOAD MODELS
# =====================================

if not MODEL_PATH.is_file():
    raise FileNotFoundError(
        f"YOLO model not found: {MODEL_PATH}"
    )

logger.info("Loading YOLO: %s", MODEL_PATH)
logger.info("Device: %s", DEVICE)

model = YOLO(str(MODEL_PATH))

logger.info("YOLO classes: %s", len(model.names))

depth_service = None

if DEPTH_ENABLED:
    depth_service = DepthService()

inference_lock = asyncio.Lock()


# =====================================
# IMAGE PREDICTION
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
                    float(box.conf[0]), 3
                ),
                "bbox": [
                    round(float(value), 2)
                    for value in box.xyxy[0].tolist()
                ],
            })

    # ---------- DEPTH ----------

    depth_ms = None

    if depth_service is not None:

        depth_map, depth_ms = depth_service.predict(
            image
        )

        for detection in detections:

            raw_distance = depth_service.object_distance(
                depth_map,
                detection["bbox"],
            )

            detection["raw_distance_m"] = (
                round(raw_distance, 2)
                if raw_distance is not None
                else None
            )

            detection["distance_m"] = (
                calibrate_distance(raw_distance)
            )

    else:
        for detection in detections:
            detection["raw_distance_m"] = None
            detection["distance_m"] = None

    return {
        "detections": detections,
        "image_width": image.width,
        "image_height": image.height,
        "inference_ms": yolo_ms,
        "yolo_ms": yolo_ms,
        "depth_ms": depth_ms,
        "depth_enabled": DEPTH_ENABLED,
        "processing_device": str(DEVICE),
    }


# =====================================
# ASYNC ANALYSIS
# =====================================

async def analyze(image_bytes: bytes) -> dict:

    started = time.perf_counter()

    async with inference_lock:
        result = await asyncio.to_thread(
            predict_image,
            image_bytes,
        )

    result["processing_ms"] = round(
        (time.perf_counter() - started) * 1000,
        2,
    )

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
        "depth_enabled": DEPTH_ENABLED,
        "depth_model": (
            DEPTH_MODEL_ID if DEPTH_ENABLED else None
        ),
    }


# =====================================
# HTTP DETECTION
# =====================================

@app.post("/detect")
async def detect(file: UploadFile = File(...)):

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
# WEBSOCKET REAL-TIME DETECTION
# =====================================

@app.websocket("/ws/detect")
async def live_detect(websocket: WebSocket):

    await websocket.accept()

    logger.info("WebSocket client connected")

    try:
        while True:

            image_bytes = await websocket.receive_bytes()

            result = await analyze(image_bytes)

            await websocket.send_text(
                json.dumps(
                    result,
                    separators=(",", ":"),
                )
            )

    except WebSocketDisconnect:
        logger.info("Detection client disconnected")

    except Exception:
        logger.exception("WebSocket detection failed")

        try:
            await websocket.close(code=1011)
        except RuntimeError:
            pass
