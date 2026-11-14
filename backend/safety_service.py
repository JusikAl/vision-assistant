
from dataclasses import dataclass
import math


@dataclass(frozen=True)
class SafetyRule:
    message: str
    priority: int
    confidence: float
    min_height: float


RULES = {
    "stairs": SafetyRule("Впереди лестница", 3, 0.35, 0.03),
    "manhole": SafetyRule("Впереди люк", 3, 0.35, 0.02),

    "car": SafetyRule("Впереди автомобиль", 2, 0.40, 0.06),
    "truck": SafetyRule("Впереди грузовик", 2, 0.40, 0.06),
    "bus": SafetyRule("Впереди автобус", 2, 0.40, 0.06),
    "motorcycle": SafetyRule("Впереди мотоцикл", 2, 0.40, 0.05),
    "bike": SafetyRule("Впереди велосипед", 2, 0.40, 0.05),

    "person": SafetyRule("Впереди человек", 1, 0.40, 0.06),
    "dog": SafetyRule("Впереди собака", 1, 0.40, 0.05),
    "chair": SafetyRule("Впереди стул", 1, 0.40, 0.05),
    "bench": SafetyRule("Впереди скамейка", 1, 0.40, 0.05),
    "dustbin": SafetyRule("Впереди мусорный бак", 1, 0.40, 0.05),
    "electrical pole": SafetyRule("Впереди столб", 1, 0.40, 0.05),
    "guard rail": SafetyRule("Впереди ограждение", 1, 0.40, 0.05),
    "traffic cone": SafetyRule("Впереди дорожный конус", 1, 0.40, 0.04),
    "traffic barrel": SafetyRule("Впереди дорожное ограждение", 1, 0.40, 0.04),
    "teraffic barrel": SafetyRule("Впереди дорожное ограждение", 1, 0.40, 0.04),
    "electrical box": SafetyRule("Впереди электрический шкаф", 1, 0.40, 0.05),
    "plant pot": SafetyRule("Впереди цветочный горшок", 1, 0.40, 0.05),
    "bicycle rack": SafetyRule("Впереди велосипедная стойка", 1, 0.40, 0.05),
}


class SafetyService:
    def __init__(
        self,
        min_confidence=0.35,
        center_left=0.20,
        center_right=0.80,
        include_low_priority=True,
    ):
        self.min_confidence = min_confidence
        self.center_left = center_left
        self.center_right = center_right
        self.include_low_priority = include_low_priority

    def evaluate(self, detections, image_width, image_height):
        if not image_width or not image_height:
            return []

        candidates = {}

        for detection in detections:
            name = str(
                detection.get("class_name", "")
            ).strip().lower()

            rule = RULES.get(name)

            if rule is None:
                continue

            if rule.priority == 1 and not self.include_low_priority:
                continue

            try:
                confidence = float(
                    detection.get("confidence", 0)
                )

                bbox = detection.get("bbox", [])

                if len(bbox) != 4:
                    continue

                x1, y1, x2, y2 = map(float, bbox)

            except (TypeError, ValueError):
                continue

            if not all(
                math.isfinite(v)
                for v in [confidence, x1, y1, x2, y2]
            ):
                continue

            if confidence < max(
                self.min_confidence,
                rule.confidence,
            ):
                continue

            if x2 <= x1 or y2 <= y1:
                continue

            object_center = (
                (x1 + x2) / 2.0
            ) / image_width

            height_ratio = (
                y2 - y1
            ) / image_height

            if not (
                self.center_left
                <= object_center
                <= self.center_right
            ):
                continue

            if height_ratio < rule.min_height:
                continue

            alert = {
                "key": name,
                "text": rule.message,
                "priority": rule.priority,
                "confidence": round(confidence, 3),
                "source": "yolo_visual_only",
            }

            previous = candidates.get(name)

            if previous is None or (
                alert["confidence"] > previous["confidence"]
            ):
                candidates[name] = alert

        alerts = list(candidates.values())

        alerts.sort(
            key=lambda item: (
                -item["priority"],
                -item["confidence"],
            )
        )

        return alerts[:3]
