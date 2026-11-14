"""Real-time Depth Anything V2 benchmark logger. No new Python dependencies."""
import csv
import json
import math
import statistics
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import torch

DISTANCES = (0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0)
FIELDS = (
    "timestamp_utc", "session_id", "frame_id", "actual_distance_m", "target_method",
    "target_class", "detected_class", "confidence", "bbox", "target_found",
    "raw_distance_m", "calibrated_distance_m", "stabilized_distance_m",
    "absolute_error_m", "signed_error_m", "dangerous_overestimate",
    "yolo_ms", "depth_ms", "processing_ms", "fps_estimate", "gpu_allocated_mb",
    "gpu_reserved_mb", "image_width", "image_height", "saved_frame",
)


def mean_or_none(values):
    return round(statistics.mean(values), 5) if values else None


def std_or_none(values):
    return round(statistics.stdev(values), 5) if len(values) > 1 else (0.0 if values else None)


def valid_num(value):
    try:
        value = float(value)
        return value if math.isfinite(value) and value > 0 else None
    except (TypeError, ValueError):
        return None


class DepthBenchmarkSession:
    def __init__(self, base_dir: Path, actual_distance_m: float, model_id: str,
                 method="center", target_class="", save_frames=True):
        actual_distance_m = float(actual_distance_m)
        if actual_distance_m not in DISTANCES:
            raise ValueError(f"Distance must be one of {DISTANCES}")
        if method not in ("center", "object"):
            raise ValueError("method must be 'center' or 'object'")
        if method == "object" and not target_class:
            raise ValueError("target_class is required for object mode")
        self.distance = actual_distance_m
        self.model_id = model_id
        self.method = method
        self.target_class = target_class
        self.save_frames = bool(save_frames)
        self.session_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '_' + uuid4().hex[:6]
        self.folder = base_dir / self.session_id
        self.folder.mkdir(parents=True, exist_ok=False)
        if self.save_frames:
            (self.folder / 'frames').mkdir()
        self.csv_file = (self.folder / 'measurements.csv').open('w', encoding='utf-8', newline='')
        self.writer = csv.DictWriter(self.csv_file, fieldnames=FIELDS)
        self.writer.writeheader()
        self.rows = []
        self.finished = False
        with (self.folder / 'metadata.json').open('w', encoding='utf-8') as f:
            json.dump({"session_id":self.session_id,"model":model_id,
                       "actual_distance_m":self.distance,"method":self.method,
                       "target_class":self.target_class,
                       "save_frames":self.save_frames,
                       "note":"Ground truth must be physically measured to target visible in camera; center mode samples central region, not guaranteed object surface."},f,indent=2)

    def record(self, result, image_bytes):
        if self.finished:
            return
        idx = len(self.rows) + 1
        detections = result.get('detections', [])
        chosen = None
        if self.method == 'object':
            matches = [d for d in detections if d.get('class_name') == self.target_class]
            if matches:
                w = result.get('image_width') or 1
                h = result.get('image_height') or 1
                chosen = min(matches, key=lambda d: ((d['bbox'][0]+d['bbox'][2])/2-w/2)**2 + ((d['bbox'][1]+d['bbox'][3])/2-h/2)**2)
        raw = valid_num(result.get('center_raw_distance_m')) if self.method == 'center' else valid_num(chosen.get('raw_distance_m')) if chosen else None
        calibrated = valid_num(result.get('center_calibrated_distance_m')) if self.method == 'center' else valid_num(chosen.get('calibrated_distance_m')) if chosen else None
        stabilized = calibrated if self.method == 'center' else valid_num(chosen.get('distance_m')) if chosen else None
        err = calibrated - self.distance if calibrated is not None else None
        alloc = round(torch.cuda.memory_allocated() / 1024**2, 2) if torch.cuda.is_available() else None
        reserved = round(torch.cuda.memory_reserved() / 1024**2, 2) if torch.cuda.is_available() else None
        saved_frame = ''
        if self.save_frames:
            saved_frame = f'frames/{idx:05d}.jpg'
            (self.folder / saved_frame).write_bytes(image_bytes)
        latency = valid_num(result.get('processing_ms'))
        row = dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),
                   session_id=self.session_id, frame_id=idx, actual_distance_m=self.distance,
                   target_method=self.method, target_class=self.target_class,
                   detected_class=chosen.get('class_name') if chosen else '',
                   confidence=chosen.get('confidence') if chosen else None,
                   bbox=json.dumps(chosen.get('bbox')) if chosen else '',
                   target_found=int(raw is not None),
                   raw_distance_m=raw, calibrated_distance_m=calibrated,
                   stabilized_distance_m=stabilized,
                   absolute_error_m=round(abs(err), 5) if err is not None else None,
                   signed_error_m=round(err, 5) if err is not None else None,
                   dangerous_overestimate=int(err > 0.25) if err is not None else None,
                   yolo_ms=result.get('yolo_ms'), depth_ms=result.get('depth_ms'),
                   processing_ms=result.get('processing_ms'),
                   fps_estimate=round(1000/latency, 3) if latency else None,
                   gpu_allocated_mb=alloc, gpu_reserved_mb=reserved,
                   image_width=result.get('image_width'), image_height=result.get('image_height'),
                   saved_frame=saved_frame)
        self.writer.writerow(row)
        self.csv_file.flush()
        self.rows.append(row)

    def finalize(self):
        if self.finished:
            return self.folder
        self.finished = True
        self.csv_file.close()
        rows = self.rows
        vals = [r['calibrated_distance_m'] for r in rows if r['calibrated_distance_m'] is not None]
        raws = [r['raw_distance_m'] for r in rows if r['raw_distance_m'] is not None]
        errors = [v-self.distance for v in vals]
        mae = mean_or_none([abs(e) for e in errors])
        rmse = round(math.sqrt(statistics.mean([e*e for e in errors])),5) if errors else None
        smoothed = [r['stabilized_distance_m'] for r in rows if r['stabilized_distance_m'] is not None]
        dangerous = sum(e > 0.25 for e in errors)
        summary = dict(session_id=self.session_id,model=self.model_id,
                       distance_m=self.distance,method=self.method,
                       frames=len(rows),valid_measurements=len(vals),
                       valid_rate_pct=round(100*len(vals)/len(rows),2) if rows else 0,
                       raw_mean=mean_or_none(raws),calibrated_mean=mean_or_none(vals),
                       calibrated_std=std_or_none(vals),mae_m=mae,rmse_m=rmse,
                       bias_m=mean_or_none(errors),overestimate_gt_025m_count=dangerous,
                       overestimate_gt_025m_pct=round(100*dangerous/len(errors),2) if errors else None)
        self._write('summary.csv',[summary])
        self._write('stability.csv',[dict(session_id=self.session_id,distance_m=self.distance,
                         calibrated_std_m=std_or_none(vals),stabilized_std_m=std_or_none(smoothed),
                         calibrated_range_m=round(max(vals)-min(vals),5) if vals else None,
                         valid_measurements=len(vals))])
        self._write('system_metrics.csv',[dict(session_id=self.session_id,
                    avg_yolo_ms=mean_or_none([r['yolo_ms'] for r in rows if r['yolo_ms'] is not None]),
                    avg_depth_ms=mean_or_none([r['depth_ms'] for r in rows if r['depth_ms'] is not None]),
                    avg_processing_ms=mean_or_none([r['processing_ms'] for r in rows if r['processing_ms'] is not None]),
                    max_gpu_allocated_mb=max([r['gpu_allocated_mb'] for r in rows if r['gpu_allocated_mb'] is not None],default=None),
                    max_gpu_reserved_mb=max([r['gpu_reserved_mb'] for r in rows if r['gpu_reserved_mb'] is not None],default=None))])
        return self.folder

    def _write(self,name,rows):
        with (self.folder / name).open('w',encoding='utf-8',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
