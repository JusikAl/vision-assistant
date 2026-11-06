
from pathlib import Path
import argparse

import torch
from ultralytics import YOLO


BASE_DIR = Path(__file__).resolve().parent

DATASET_YAML = BASE_DIR / "rod_dataset.yaml"
PROJECT_DIR = BASE_DIR / "runs"

MODEL_WEIGHTS = "yolo26n.pt"
EXPERIMENT_NAME = "yolo26n_full"

EPOCHS = 20
IMAGE_SIZE = 512
BATCH_SIZE = 4


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--resume",
        action="store_true",
        help="Resume interrupted training"
    )

    args = parser.parse_args()

    print("=== YOLO26n FULL TRAINING ===")

    if not torch.cuda.is_available():
        raise RuntimeError(
            "CUDA unavailable."
        )

    if not DATASET_YAML.is_file():
        raise FileNotFoundError(
            f"Dataset YAML not found: {DATASET_YAML}"
        )

    print("GPU:", torch.cuda.get_device_name(0))
    print("Dataset:", DATASET_YAML)
    print("Epochs:", EPOCHS)
    print("Image size:", IMAGE_SIZE)
    print("Batch:", BATCH_SIZE)

    run_dir = PROJECT_DIR / EXPERIMENT_NAME

    if args.resume:
        checkpoint = run_dir / "weights" / "last.pt"

        if not checkpoint.is_file():
            raise FileNotFoundError(checkpoint)

        print("Resuming:", checkpoint)

        model = YOLO(str(checkpoint))
        model.train(resume=True)

    else:
        if run_dir.exists():
            raise FileExistsError(
                f"Experiment already exists: {run_dir}\n"
                "Use --resume for an interrupted run."
            )

        model = YOLO(MODEL_WEIGHTS)

        model.train(
            data=str(DATASET_YAML),
            epochs=EPOCHS,
            imgsz=IMAGE_SIZE,
            batch=BATCH_SIZE,
            device=0,
            workers=2,
            fraction=1.0,
            amp=True,
            cache=False,
            project=str(PROJECT_DIR),
            name=EXPERIMENT_NAME,
            exist_ok=False,
            plots=True,
            save=True,
            save_period=5,
            val=True,
            patience=10,
            seed=42,
        )

    print("\n=== TRAINING FINISHED ===")

    best_weights = run_dir / "weights" / "best.pt"
    last_weights = run_dir / "weights" / "last.pt"

    print("Best weights:", best_weights)
    print("Best exists:", best_weights.is_file())
    print("Last weights:", last_weights)
    print("Last exists:", last_weights.is_file())


if __name__ == "__main__":
    main()
