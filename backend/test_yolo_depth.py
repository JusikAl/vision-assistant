
import time
from pathlib import Path

from depth_calibration import calibrate_distance

import cv2
import numpy as np
import torch
from PIL import Image
from ultralytics import YOLO
from transformers import (
    AutoImageProcessor,
    AutoModelForDepthEstimation,
)

BASE_DIR = Path(__file__).resolve().parent
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

# Use the original YOLO model for comparison.
YOLO_PATH = BASE_DIR / "yolo26n.pt"

DEPTH_ID = (
    "depth-anything/"
    "Depth-Anything-V2-Metric-Outdoor-Small-hf"
)

print("Loading YOLO...")
yolo = YOLO(str(YOLO_PATH))

print("Loading Depth...")
processor = AutoImageProcessor.from_pretrained(DEPTH_ID)
depth_model = AutoModelForDepthEstimation.from_pretrained(
    DEPTH_ID
).to(DEVICE).eval()

image = Image.open(BASE_DIR / "test.jpg").convert("RGB")

# YOLO inference
start = time.perf_counter()
results = yolo.predict(
    source=image,
    conf=0.25,
    imgsz=512,
    device=0 if DEVICE == "cuda" else "cpu",
    verbose=False,
)

if DEVICE == "cuda":
    torch.cuda.synchronize()

yolo_ms = (time.perf_counter() - start) * 1000

# Depth inference
inputs = processor(
    images=image,
    return_tensors="pt"
).to(DEVICE)

start = time.perf_counter()

with torch.inference_mode():
    outputs = depth_model(**inputs)

depth = processor.post_process_depth_estimation(
    outputs,
    target_sizes=[(image.height, image.width)]
)[0]["predicted_depth"]

if DEVICE == "cuda":
    torch.cuda.synchronize()

depth_ms = (time.perf_counter() - start) * 1000
depth = depth.float().cpu().numpy()

# Draw detections
frame = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
height, width = depth.shape

for result in results:
    for box in result.boxes:
        x1, y1, x2, y2 = map(int, box.xyxy[0].tolist())

        x1 = max(0, min(x1, width))
        x2 = max(0, min(x2, width))
        y1 = max(0, min(y1, height))
        y2 = max(0, min(y2, height))

        if x2 <= x1 or y2 <= y1:
            continue

        # Central 50% of bounding box
        mx = int((x2 - x1) * 0.25)
        my = int((y2 - y1) * 0.25)

        region = depth[
            y1 + my:y2 - my,
            x1 + mx:x2 - mx,
        ]

        valid = region[
            np.isfinite(region) & (region > 0)
        ]

        raw_distance = (
            float(np.median(valid))
            if valid.size
            else None
        )

        distance = calibrate_distance(raw_distance)

        class_id = int(box.cls[0])
        class_name = result.names[class_id]
        confidence = float(box.conf[0])

        label = f"{class_name} {confidence:.2f}"

        if distance is not None:
            label += f" ~{distance:.1f}m"

        cv2.rectangle(
            frame, (x1, y1), (x2, y2),
            (0, 255, 0), 2
        )

        cv2.putText(
            frame, label,
            (x1, max(20, y1 - 8)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55, (0, 255, 0), 2
        )

        print(label)

cv2.imwrite(str(BASE_DIR / "yolo_depth_result.jpg"), frame)

print(f"YOLO: {yolo_ms:.1f} ms")
print(f"Depth: {depth_ms:.1f} ms")
print("Saved yolo_depth_result.jpg")
