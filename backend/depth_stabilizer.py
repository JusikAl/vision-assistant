
import math
import time
from dataclasses import dataclass


@dataclass
class Track:
    track_id: int
    class_name: str
    bbox: list
    distance: float
    last_seen: float


class DepthStabilizer:
    def __init__(
        self,
        alpha=0.25,
        approach_alpha=0.75,
        max_age=1.5,
        iou_threshold=0.25,
        max_tracks=100,
    ):
        self.alpha = alpha
        self.approach_alpha = approach_alpha
        self.max_age = max_age
        self.iou_threshold = iou_threshold
        self.max_tracks = max_tracks

        self.tracks = {}
        self.next_id = 1

    @staticmethod
    def iou(a, b):
        x1 = max(a[0], b[0])
        y1 = max(a[1], b[1])
        x2 = min(a[2], b[2])
        y2 = min(a[3], b[3])

        intersection = (
            max(0, x2 - x1) *
            max(0, y2 - y1)
        )

        area_a = max(0, a[2] - a[0]) * max(
            0, a[3] - a[1]
        )
        area_b = max(0, b[2] - b[0]) * max(
            0, b[3] - b[1]
        )

        union = area_a + area_b - intersection

        return intersection / union if union > 0 else 0

    def update(self, detections):
        now = time.monotonic()

        # Remove stale objects.
        self.tracks = {
            tid: track
            for tid, track in self.tracks.items()
            if now - track.last_seen <= self.max_age
        }

        # Build candidate matches.
        candidates = []

        for index, detection in enumerate(detections):
            for tid, track in self.tracks.items():
                if detection["class_name"] != track.class_name:
                    continue

                overlap = self.iou(
                    detection["bbox"], track.bbox
                )

                if overlap >= self.iou_threshold:
                    candidates.append(
                        (overlap, index, tid)
                    )

        # Match each detection and track at most once.
        candidates.sort(reverse=True)

        matches = {}
        used_tracks = set()

        for _, index, tid in candidates:
            if index in matches or tid in used_tracks:
                continue
            matches[index] = tid
            used_tracks.add(tid)

        for index, detection in enumerate(detections):
            value = detection.get("calibrated_distance_m")

            if value is not None:
                try:
                    value = float(value)
                except (TypeError, ValueError):
                    value = None

            if value is not None and (
                not math.isfinite(value) or value <= 0
            ):
                value = None

            tid = matches.get(index)
            track = self.tracks.get(tid) if tid else None

            if value is None:
                detection["distance_m"] = None
                detection["track_id"] = (
                    track.track_id if track else None
                )
                continue

            if track is None:
                tid = self.next_id
                self.next_id += 1

                track = Track(
                    track_id=tid,
                    class_name=detection["class_name"],
                    bbox=detection["bbox"],
                    distance=value,
                    last_seen=now,
                )
                self.tracks[tid] = track

                smoothed = value

            else:
                # Faster response when an obstacle approaches.
                alpha = (
                    self.approach_alpha
                    if value < track.distance
                    else self.alpha
                )

                smoothed = (
                    alpha * value
                    + (1 - alpha) * track.distance
                )

                track.distance = smoothed
                track.bbox = detection["bbox"]
                track.last_seen = now

            detection["track_id"] = tid
            detection["distance_m"] = round(
                smoothed, 2
            )

        # Bound memory usage.
        if len(self.tracks) > self.max_tracks:
            ordered = sorted(
                self.tracks.items(),
                key=lambda item: item[1].last_seen,
                reverse=True,
            )
            self.tracks = dict(
                ordered[:self.max_tracks]
            )

        return detections
