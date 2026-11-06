
from pathlib import Path

import pandas as pd


BASE_DIR = Path(__file__).resolve().parent

RESULTS_FILE = (
    BASE_DIR
    / "runs"
    / "yolo11n_full"
    / "results.csv"
)


def main():
    print("=== YOLO11n TRAINING ANALYSIS ===")

    if not RESULTS_FILE.is_file():
        raise FileNotFoundError(
            f"Results not found: {RESULTS_FILE}"
        )

    df = pd.read_csv(RESULTS_FILE)

    df.columns = df.columns.str.strip()

    metrics = {
        "precision": "metrics/precision(B)",
        "recall": "metrics/recall(B)",
        "mAP50": "metrics/mAP50(B)",
        "mAP50-95": "metrics/mAP50-95(B)",
    }

    missing = [
        col for col in metrics.values()
        if col not in df.columns
    ]

    if missing:
        raise ValueError(
            f"Missing metric columns: {missing}"
        )

    print("\nTotal epochs:", len(df))

    print("\n=== FIRST EPOCH ===")
    first = df.iloc[0]

    for name, column in metrics.items():
        print(f"{name}: {first[column]:.4f}")

    print("\n=== LAST EPOCH ===")
    last = df.iloc[-1]

    for name, column in metrics.items():
        print(f"{name}: {last[column]:.4f}")

    print("\n=== BEST EPOCH BY mAP50-95 ===")
    best_idx = df[metrics["mAP50-95"]].idxmax()
    best = df.loc[best_idx]

    print("Epoch:", int(best["epoch"]))

    for name, column in metrics.items():
        print(f"{name}: {best[column]:.4f}")

    print("\n=== TRAINING HISTORY ===")

    selected = [
        "epoch",
        *metrics.values()
    ]

    print(
        df[selected].to_string(
            index=False,
            float_format=lambda x: f"{x:.4f}"
        )
    )


if __name__ == "__main__":
    main()
