
from pathlib import Path
import yaml

BASE_DIR = Path(__file__).resolve().parent
YAML_PATH = BASE_DIR / "rod_dataset.yaml"


def main():
    print("=== DATASET VALIDATION ===")

    if not YAML_PATH.is_file():
        raise FileNotFoundError(
            f"Configuration not found: {YAML_PATH}"
        )

    with open(YAML_PATH, "r", encoding="utf-8") as file:
        config = yaml.safe_load(file)

    dataset_path = Path(config["path"])
    class_names = config["names"]

    print("Dataset:", dataset_path)
    print("Number of classes:", config["nc"])

    if len(class_names) != config["nc"]:
        raise ValueError(
            "Number of class names does not match nc"
        )

    for split in ["train", "val", "test"]:
        images_dir = dataset_path / config[split]
        labels_dir = images_dir.parent / "labels"

        if not images_dir.is_dir():
            raise FileNotFoundError(images_dir)

        if not labels_dir.is_dir():
            raise FileNotFoundError(labels_dir)

        images = [
            p for p in images_dir.iterdir()
            if p.suffix.lower() in {".jpg", ".jpeg", ".png"}
        ]

        labels = list(labels_dir.glob("*.txt"))

        print(f"\n{split.upper()}")
        print("Images:", len(images))
        print("Labels:", len(labels))

        if not images:
            raise RuntimeError(
                f"No images found in {images_dir}"
            )

    print("\n=== CLASSES ===")

    for index, name in enumerate(class_names):
        print(f"{index}: {name}")

    print("\nDataset validation successful!")


if __name__ == "__main__":
    main()
