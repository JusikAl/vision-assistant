
from pathlib import Path
from collections import Counter

DATASET_DIR = Path(
    r"C:\Users\Zhaks\.cache\kagglehub\datasets"
    r"\abtinzandi\obstacle-detection-dataset\versions\4"
)

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}

def main():
    if not DATASET_DIR.exists():
        raise FileNotFoundError(
            f"Dataset not found: {DATASET_DIR}"
        )

    print("=== DATASET INSPECTION ===")
    print("Path:", DATASET_DIR)

    print("\n=== TOP-LEVEL CONTENTS ===")
    for item in sorted(DATASET_DIR.iterdir()):
        print(
            "[DIR]" if item.is_dir() else "[FILE]",
            item.name
        )

    images = [
        p for p in DATASET_DIR.rglob("*")
        if p.is_file()
        and p.suffix.lower() in IMAGE_EXTENSIONS
    ]

    labels = [
        p for p in DATASET_DIR.rglob("*.txt")
        if p.is_file()
    ]

    yaml_files = list(DATASET_DIR.rglob("*.yaml"))
    yaml_files += list(DATASET_DIR.rglob("*.yml"))

    print("\n=== FILE COUNTS ===")
    print("Images:", len(images))
    print("TXT files:", len(labels))
    print("YAML files:", len(yaml_files))

    print("\n=== IMAGES BY FOLDER ===")
    folders = Counter(
        str(p.parent.relative_to(DATASET_DIR))
        for p in images
    )

    for folder, count in folders.most_common(20):
        print(f"{folder}: {count}")

    print("\n=== YAML CONTENT ===")
    for yaml_path in yaml_files[:5]:
        print(f"\nFile: {yaml_path}")
        print(
            yaml_path.read_text(
                encoding="utf-8",
                errors="replace"
            )[:5000]
        )

    print("\n=== SAMPLE LABEL FILES ===")
    for label_path in labels[:5]:
        print(f"\nFile: {label_path}")
        print(
            label_path.read_text(
                encoding="utf-8",
                errors="replace"
            )[:500]
        )

    print("\n=== SAMPLE IMAGES ===")
    for image in images[:5]:
        print(image.relative_to(DATASET_DIR))

if __name__ == "__main__":
    main()
