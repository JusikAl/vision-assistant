
from pathlib import Path
import csv

import torch
from ultralytics import YOLO


BASE_DIR = Path(__file__).resolve().parent

MODEL_PATH = (
    BASE_DIR / "runs" / "yolo11n_full"
    / "weights" / "best.pt"
)

DATASET_YAML = BASE_DIR / "rod_dataset.yaml"
OUTPUT_FILE = BASE_DIR / "results" / "yolo11n_class_metrics.csv"


def main():
    print("=== YOLO11n CLASS EVALUATION ===")

    if not MODEL_PATH.is_file():
        raise FileNotFoundError(MODEL_PATH)

    if not DATASET_YAML.is_file():
        raise FileNotFoundError(DATASET_YAML)

    model = YOLO(str(MODEL_PATH))

    device = 0 if torch.cuda.is_available() else "cpu"

    metrics = model.val(
        data=str(DATASET_YAML),
        split="val",
        imgsz=512,
        batch=4,
        device=device,
        workers=2,
        plots=False,
        verbose=False,
        project=str(BASE_DIR / "runs"),
        name="yolo11n_class_evaluation",
        exist_ok=True,
    )

    print("\n=== OVERALL METRICS ===")
    print(f"Precision: {metrics.box.mp:.4f}")
    print(f"Recall: {metrics.box.mr:.4f}")
    print(f"mAP50: {metrics.box.map50:.4f}")
    print(f"mAP50-95: {metrics.box.map:.4f}")

    rows = []

    for class_id, class_name in model.names.items():
        precision, recall, ap50, ap5095 = (
            metrics.box.class_result(class_id)
        )

        rows.append({
            "class_id": class_id,
            "class_name": class_name,
            "precision": round(float(precision), 4),
            "recall": round(float(recall), 4),
            "mAP50": round(float(ap50), 4),
            "mAP50-95": round(float(ap5095), 4),
        })

    print("\n=== PER-CLASS RESULTS ===")

    for row in rows:
        print(
            f"{row['class_name']:<23} "
            f"P={row['precision']:.3f} "
            f"R={row['recall']:.3f} "
            f"mAP50={row['mAP50']:.3f}"
        )

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)

    with open(
        OUTPUT_FILE, "w", newline="", encoding="utf-8"
    ) as file:
        writer = csv.DictWriter(
            file, fieldnames=rows[0].keys()
        )
        writer.writeheader()
        writer.writerows(rows)

    print("\nSaved:", OUTPUT_FILE)


if __name__ == "__main__":
    main()
