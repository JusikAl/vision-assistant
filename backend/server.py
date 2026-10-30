
import asyncio
import io
import json
import time
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, WebSocket, WebSocketDisconnect
from PIL import Image
from ultralytics import YOLO

app = FastAPI()

MODEL_PATH = Path(__file__).resolve().parent / "yolo26n.pt"
model = YOLO(str(MODEL_PATH))

inference_lock = asyncio.Lock()


def predict_image(image_bytes: bytes):
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")

    results = model.predict(
        image,
        conf=0.35,
        imgsz=640,
        verbose=False,
    )

    detections = []

    for result in results:
        for box in result.boxes:
            detections.append({
                "class_name": result.names[int(box.cls[0])],
                "confidence": round(float(box.conf[0]), 3),
                "bbox": [
                    round(float(x), 2)
                    for x in box.xyxy[0].tolist()
                ],
            })

    return {
        "detections": detections,
        "image_width": image.width,
        "image_height": image.height,
    }


async def analyze(image_bytes: bytes):
    start = time.perf_counter()

    async with inference_lock:
        result = await asyncio.to_thread(
            predict_image, image_bytes
        )

    result["processing_ms"] = round(
        (time.perf_counter() - start) * 1000, 2
    )

    return result


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/detect")
async def detect(file: UploadFile = File(...)):
    image_bytes = await file.read()
    return await analyze(image_bytes)


@app.websocket("/ws/detect")
async def live_detect(websocket: WebSocket):
    await websocket.accept()

    try:
        while True:
            frame = await websocket.receive_bytes()
            result = await analyze(frame)

            await websocket.send_text(
                json.dumps(result)
            )

    except WebSocketDisconnect:
        print("Client disconnected")
    except Exception as e:
        print(f"WebSocket error: {e}")
        await websocket.close()
