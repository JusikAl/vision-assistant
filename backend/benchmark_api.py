
import time
import statistics

import requests

URL = "http://127.0.0.1:8000/detect"
IMAGE_PATH = "test.jpg"

WARMUP = 3
RUNS = 10

results = []

with open(IMAGE_PATH, "rb") as f:
    image_bytes = f.read()

print("Benchmarking FastAPI YOLO + Depth...")

for i in range(WARMUP + RUNS):
    start = time.perf_counter()

    response = requests.post(
        URL,
        files={
            "file": (
                "test.jpg",
                image_bytes,
                "image/jpeg",
            )
        },
        timeout=60,
    )

    response.raise_for_status()
    data = response.json()

    http_ms = (
        time.perf_counter() - start
    ) * 1000

    print(
        f"Request {i + 1}: "
        f"YOLO={data['yolo_ms']:.1f}ms | "
        f"Depth={data['depth_ms']:.1f}ms | "
        f"Server={data['processing_ms']:.1f}ms | "
        f"HTTP={http_ms:.1f}ms"
    )

    if i >= WARMUP:
        results.append({
            "yolo": data["yolo_ms"],
            "depth": data["depth_ms"],
            "server": data["processing_ms"],
            "http": http_ms,
        })

print("\n===== AVERAGES =====")

for key in ("yolo", "depth", "server", "http"):
    avg = statistics.mean(
        r[key] for r in results
    )
    print(f"{key}: {avg:.2f} ms")

avg_server = statistics.mean(
    r["server"] for r in results
)

print(
    f"\nEstimated throughput: "
    f"{1000 / avg_server:.2f} FPS"
)
