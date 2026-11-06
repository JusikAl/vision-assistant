
from pathlib import Path
from time import perf_counter
import statistics

import pandas as pd
import torch
import yaml
from ultralytics import YOLO


BASE_DIR = Path(__file__).resolve().parent
DATASET_YAML = BASE_DIR / "rod_dataset.yaml"
OUTPUT_DIR = BASE_DIR / "results"

MODELS = {
    "YOLO11n": BASE_DIR / "runs" / "yolo11n_full" / "weights" / "best.pt",
    "YOLO26n": BASE_DIR / "runs" / "yolo26n_full" / "weights" / "best.pt",
}

IMAGE_SIZE = 512
BATCH_SIZE = 4
SPEED_IMAGES = 100
WARMUP_RUNS = 10
CONFIDENCE = 0.25

DEVICE = 0 if torch.cuda.is_available() else "cpu"


def sync_gpu():
    if DEVICE != "cpu":
        torch.cuda.synchronize()


def load_test_images():
    with open(DATASET_YAML, "r", encoding="utf-8") as file:
        config = yaml.safe_load(file)

    image_dir = Path(config["path"]) / config["test"]

    images = sorted(
        path for path in image_dir.rglob("*")
        if path.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )

    if not images:
        raise RuntimeError("No test images found")

    return images[:SPEED_IMAGES]


def benchmark_speed(model, images):
    for _ in range(WARMUP_RUNS):
        model.predict(
            str(images[0]),
            imgsz=IMAGE_SIZE,
            conf=CONFIDENCE,
            device=DEVICE,
            verbose=False,
        )

    sync_gpu()
    latencies = []

    for image_path in images:
        sync_gpu()
        start = perf_counter()

        model.predict(
            str(image_path),
            imgsz=IMAGE_SIZE,
            conf=CONFIDENCE,
            device=DEVICE,
            verbose=False,
        )

        sync_gpu()
        latencies.append((perf_counter() - start) * 1000)

    avg_ms = statistics.mean(latencies)

    return {
        "avg_latency_ms": round(avg_ms, 2),
        "median_latency_ms": round(statistics.median(latencies), 2),
        "estimated_fps": round(1000 / avg_ms, 2),
    }


def main():
    print("=== TRAINED YOLO COMPARISON ===")

    if not DATASET_YAML.is_file():
        raise FileNotFoundError(DATASET_YAML)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Device:", DEVICE)

    images = load_test_images()
    print("Speed test images:", len(images))

    summary_rows = []
    class_rows = []

    for model_name, weights_path in MODELS.items():
        if not weights_path.is_file():
            raise FileNotFoundError(weights_path)

        print(f"\n=== {model_name} ===")

        model = YOLO(str(weights_path))

        metrics = model.val(
            data=str(DATASET_YAML),
            split="test",
            imgsz=IMAGE_SIZE,
            batch=BATCH_SIZE,
            device=DEVICE,
            workers=2,
            plots=False,
            verbose=False,
            project=str(BASE_DIR / "runs"),
            name=f"{model_name.lower()}_final_test",
            exist_ok=True,
        )

        speed = benchmark_speed(model, images)

        summary_rows.append({
            "model": model_name,
            "precision": round(float(metrics.box.mp), 4),
            "recall": round(float(metrics.box.mr), 4),
            "mAP50": round(float(metrics.box.map50), 4),
            "mAP50-95": round(float(metrics.box.map), 4),
            **speed,
        })

        for class_id, class_name in model.names.items():
            p, r, ap50, ap5095 = metrics.box.class_result(class_id)

            class_rows.append({
                "model": model_name,
                "class_id": class_id,
                "class_name": class_name,
                "precision": round(float(p), 4),
                "recall": round(float(r), 4),
                "mAP50": round(float(ap50), 4),
                "mAP50-95": round(float(ap5095), 4),
            })

        del model

        if DEVICE != "cpu":
            torch.cuda.empty_cache()

    summary = pd.DataFrame(summary_rows)
    classes = pd.DataFrame(class_rows)

    print("\n=== FINAL COMPARISON ===")
    print(summary.to_string(index=False))

    print("\n=== IMPORTANT CLASSES ===")

    important_classes = [
        "Person",
        "Car",
        "Stairs",
        "Manhole",
        "Pedestrian crosswalk",
        "Traffic Cone",
        "Traffic sign",
    ]

    selected = classes[
        classes["class_name"].isin(important_classes)
    ]

    print(
        selected[
            ["model", "class_name", "recall", "mAP50"]
        ].to_string(index=False)
    )

    summary_path = OUTPUT_DIR / "trained_models_comparison.csv"
    classes_path = OUTPUT_DIR / "trained_models_class_metrics.csv"

    summary.to_csv(summary_path, index=False)
    classes.to_csv(classes_path, index=False)

    print("\nSaved:", summary_path)
    print("Saved:", classes_path)


if __name__ == "__main__":
    main()
