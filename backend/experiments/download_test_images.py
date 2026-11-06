
from pathlib import Path
import shutil
import kagglehub

DATASET = "abtinzandi/obstacle-detection-dataset"
LIMIT = 200

BASE_DIR = Path(__file__).resolve().parent

OUTPUT_DIR = (
    BASE_DIR / "datasets" / "test_images" / "obstacles"
)

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

print("Downloading Obstacle Detection Dataset...")

dataset_path = Path(
    kagglehub.dataset_download(DATASET)
)

print(f"Dataset location: {dataset_path}")

extensions = {".jpg", ".jpeg", ".png", ".webp"}

images = sorted(
    path for path in dataset_path.rglob("*")
    if path.is_file()
    and path.suffix.lower() in extensions
)

print(f"Total images found: {len(images)}")

if not images:
    raise RuntimeError("No images found!")

selected_images = images[:LIMIT]

for index, image_path in enumerate(selected_images):
    target = OUTPUT_DIR / (
        f"obstacle_{index:04d}{image_path.suffix.lower()}"
    )

    shutil.copy2(image_path, target)

print(f"\nSuccessfully copied {len(selected_images)} images")
print(f"Saved to: {OUTPUT_DIR.resolve()}")
