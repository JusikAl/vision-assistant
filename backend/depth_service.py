
import logging
import os
import time

import numpy as np
import torch

from transformers import (
    AutoImageProcessor,
    AutoModelForDepthEstimation,
)

logger = logging.getLogger("uvicorn.error")

DEPTH_MODEL_ID = os.getenv(
    "DEPTH_MODEL",
    "depth-anything/Depth-Anything-V2-Metric-Outdoor-Small-hf",
)


class DepthService:
    def __init__(self):
        self.device = (
            "cuda" if torch.cuda.is_available() else "cpu"
        )

        self.dtype = (
            torch.float16
            if self.device == "cuda"
            else torch.float32
        )

        logger.info(
            "Loading Depth model: %s",
            DEPTH_MODEL_ID,
        )

        logger.info(
            "Depth device=%s, dtype=%s",
            self.device,
            self.dtype,
        )

        self.processor = AutoImageProcessor.from_pretrained(
            DEPTH_MODEL_ID,
            use_fast=False,
        )

        self.model = (
            AutoModelForDepthEstimation.from_pretrained(
                DEPTH_MODEL_ID
            )
            .to(device=self.device, dtype=self.dtype)
            .eval()
        )

        logger.info("Depth model loaded")

    @torch.inference_mode()
    def predict(self, image):
        started = time.perf_counter()

        inputs = self.processor(
            images=image,
            return_tensors="pt",
        ).to(self.device)

        inputs["pixel_values"] = inputs[
            "pixel_values"
        ].to(dtype=self.dtype)

        outputs = self.model(**inputs)

        processed = (
            self.processor.post_process_depth_estimation(
                outputs,
                target_sizes=[
                    (image.height, image.width)
                ],
            )
        )

        depth_map = (
            processed[0]["predicted_depth"]
            .float()
            .cpu()
            .numpy()
        )

        if self.device == "cuda":
            torch.cuda.synchronize()

        depth_ms = round(
            (time.perf_counter() - started) * 1000,
            2,
        )

        return depth_map, depth_ms

    @staticmethod
    def object_distance(depth_map, bbox):
        h, w = depth_map.shape

        x1, y1, x2, y2 = map(int, bbox)

        x1 = max(0, min(x1, w))
        x2 = max(0, min(x2, w))
        y1 = max(0, min(y1, h))
        y2 = max(0, min(y2, h))

        if x2 <= x1 or y2 <= y1:
            return None

        margin_x = int((x2 - x1) * 0.25)
        margin_y = int((y2 - y1) * 0.25)

        region = depth_map[
            y1 + margin_y:y2 - margin_y,
            x1 + margin_x:x2 - margin_x,
        ]

        valid = region[
            np.isfinite(region) & (region > 0)
        ]

        if valid.size == 0:
            return None

        return float(np.median(valid))
