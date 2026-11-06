
from pathlib import Path
from time import perf_counter
import statistics

import pandas as pd
import torch
from ultralytics import YOLO


# =====================================
# CONFIGURATION
# =====================================

BASE_DIR = Path(__file__).resolve().parent

DATASET_DIR = Path(
    r"C:\Users\Zhaks\.cache\kagglehub\datasets"
    r"\abtinzandi\obstacle-detection-dataset"
    r"\versions\4\ROD-Dataset\dataset"
)

IMAGE_DIR = DATASET_DIR / "test" / "images"
OUTPUT_DIR = BASE_DIR / "results"

MODELS = [
    "yolo26n.pt",
    "yolo11n.pt",
    "yolo11s.pt",
]

IMAGE_LIMIT = 100
IMAGE_SIZE = 640
CONFIDENCE = 0.25
WARMUP_RUNS = 10

DEVICE = 0 if torch.cuda.is_available() else "cpu"

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


def synchronize_gpu():
    if DEVICE != "cpu":
        torch.cuda.synchronize()


def load_images():
    extensions = {".jpg", ".jpeg", ".png"}

    images = sorted(
        path for path in IMAGE_DIR.rglob("*")
        if path.is_file()
        and path.suffix.lower() in extensions
    )

    if not images:
        raise RuntimeError(
            f"No images found in {IMAGE_DIR}"
        )

    return images[:IMAGE_LIMIT]


def benchmark_model(weights, images):
    print(f"\nTesting model: {weights}")

    model = YOLO(weights)

    print("Warm-up...")

    for _ in range(WARMUP_RUNS):
        model.predict(
            str(images[0]),
            imgsz=IMAGE_SIZE,
            conf=CONFIDENCE,
            device=DEVICE,
            verbose=False
        )

    synchronize_gpu()

    latencies = []
    total_detections = 0

    for index, image_path in enumerate(images, start=1):
        synchronize_gpu()
        start = perf_counter()

        results = model.predict(
            str(image_path),
            imgsz=IMAGE_SIZE,
            conf=CONFIDENCE,
            device=DEVICE,
            verbose=False
        )

        synchronize_gpu()

        elapsed_ms = (
            perf_counter() - start
        ) * 1000

        latencies.append(elapsed_ms)
        total_detections += len(results[0].boxes)

        if index % 20 == 0:
            print(f"Processed {index}/{len(images)}")

    avg_latency = statistics.mean(latencies)

    del model

    if DEVICE != "cpu":
        torch.cuda.empty_cache()

    return {
        "model": weights,
        "device": str(DEVICE),
        "images": len(images),
        "avg_latency_ms": round(avg_latency, 2),
        "median_latency_ms": round(
            statistics.median(latencies), 2
        ),
        "estimated_fps": round(
            1000 / avg_latency, 2
        ),
        "total_detections": total_detections
    }


def main():
    print("=== YOLO GPU COMPARISON ===")

    print("PyTorch:", torch.__version__)
    print("CUDA available:", torch.cuda.is_available())
    print("Device:", DEVICE)

    if torch.cuda.is_available():
        print("GPU:", torch.cuda.get_device_name(0))

    images = load_images()
    print("Images selected:", len(images))

    results = []

    for weights in MODELS:
        result = benchmark_model(weights, images)
        results.append(result)

    df = pd.DataFrame(results)

    print("\n=== FINAL RESULTS ===")
    print(df.to_string(index=False))

    device_name = (
        "gpu" if DEVICE != "cpu" else "cpu"
    )

    output_file = (
        OUTPUT_DIR /
        f"yolo_speed_comparison_{device_name}.csv"
    )

    df.to_csv(output_file, index=False)

    print("\nResults saved:", output_file)


if __name__ == "__main__":
    main()
