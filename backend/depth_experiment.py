
import csv
import math
import os
import threading
import time
from pathlib import Path

CSV_PATH = os.getenv('DEPTH_TEST_CSV', '').strip()
TARGET_DISTANCE = os.getenv('DEPTH_TEST_DISTANCE_M', '').strip()
TEST_MODE = os.getenv('DEPTH_TEST_MODE', 'unknown')
TEST_CLASS = os.getenv('DEPTH_TEST_CLASS', '').strip().casefold()
_LOCK = threading.Lock()
_FIELDS = [
    'timestamp_unix', 'mode', 'actual_distance_m', 'target_class',
    'detected_class', 'confidence', 'bbox', 'raw_distance_m',
    'calibrated_distance_m', 'distance_m', 'yolo_ms', 'depth_ms',
    'processing_ms', 'depth_smoothing', 'matched',
]


def record_frame(result: dict) -> None:
    """Record one target observation per analyzed frame (and missed detections)."""
    if not CSV_PATH:
        return
    try:
        actual = float(TARGET_DISTANCE)
        if not math.isfinite(actual) or actual <= 0:
            return
    except ValueError:
        return

    candidates = result.get('detections', [])
    if TEST_CLASS:
        candidates = [d for d in candidates if str(d.get('class_name', '')).casefold() == TEST_CLASS]
    # When several instances match, choose the most confident detection.
    detection = max(candidates, key=lambda d: d.get('confidence') or 0, default=None)
    row = {
        'timestamp_unix': round(time.time(), 3),
        'mode': TEST_MODE,
        'actual_distance_m': actual,
        'target_class': TEST_CLASS,
        'detected_class': detection.get('class_name') if detection else '',
        'confidence': detection.get('confidence') if detection else '',
        'bbox': str(detection.get('bbox')) if detection else '',
        'raw_distance_m': detection.get('raw_distance_m') if detection else '',
        'calibrated_distance_m': detection.get('calibrated_distance_m') if detection else '',
        'distance_m': detection.get('distance_m') if detection else '',
        'yolo_ms': result.get('yolo_ms'),
        'depth_ms': result.get('depth_ms'),
        'processing_ms': result.get('processing_ms'),
        'depth_smoothing': result.get('depth_smoothing'),
        'matched': int(detection is not None),
    }
    path = Path(CSV_PATH)
    with _LOCK:
        path.parent.mkdir(parents=True, exist_ok=True)
        write_header = not path.exists() or path.stat().st_size == 0
        with path.open('a', newline='', encoding='utf-8') as file:
            writer = csv.DictWriter(file, fieldnames=_FIELDS)
            if write_header:
                writer.writeheader()
            writer.writerow(row)
