
import time

import numpy as np
import torch
import matplotlib.pyplot as plt

from PIL import Image
from transformers import (
    AutoImageProcessor,
    AutoModelForDepthEstimation,
)

MODEL_ID = (
    "depth-anything/"
    "Depth-Anything-V2-Metric-Outdoor-Small-hf"
)

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

print("Device:", DEVICE)
print("Loading Depth Anything V2...")

processor = AutoImageProcessor.from_pretrained(MODEL_ID)

model = AutoModelForDepthEstimation.from_pretrained(
    MODEL_ID
).to(DEVICE)

model.eval()

print("Model loaded!")

# Load image
image = Image.open("test.jpg").convert("RGB")

inputs = processor(
    images=image,
    return_tensors="pt"
).to(DEVICE)

# Inference
if DEVICE == "cuda":
    torch.cuda.synchronize()

start = time.perf_counter()

with torch.inference_mode():
    outputs = model(**inputs)

depth = processor.post_process_depth_estimation(
    outputs,
    target_sizes=[(image.height, image.width)]
)[0]["predicted_depth"]

if DEVICE == "cuda":
    torch.cuda.synchronize()

elapsed = time.perf_counter() - start

depth = depth.float().cpu().numpy()

# Estimate depth at image center
h, w = depth.shape

center_region = depth[
    int(h * 0.45):int(h * 0.55),
    int(w * 0.45):int(w * 0.55)
]

valid = center_region[
    np.isfinite(center_region) & (center_region > 0)
]

if valid.size:
    distance = float(np.median(valid))
    print(f"Estimated center depth: {distance:.2f} m")
else:
    print("No valid depth in center region")

print(f"Inference time: {elapsed * 1000:.1f} ms")

# Save visualization
plt.figure(figsize=(10, 6))
plt.imshow(depth, cmap="turbo", vmin=0, vmax=80)
plt.colorbar(label="Estimated depth (m)")
plt.title("Metric Depth Estimation")
plt.axis("off")
plt.savefig("depth_map.png", dpi=150)
plt.close()

np.save("depth_meters.npy", depth)

print("Saved depth_map.png")
print("Saved depth_meters.npy")
