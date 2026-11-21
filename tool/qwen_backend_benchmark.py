"""Measure real JPEG -> existing FastAPI -> local Ollama, retaining text/metrics only."""
import argparse
import json
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
import psutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--manifest', type=Path, default=Path('docs/qwen3_vl_quality_manifest.json'))
    parser.add_argument('--output', type=Path, default=Path('docs/qwen3_vl_backend_benchmark.json'))
    parser.add_argument('--backend-pid', type=int, default=0)
    args = parser.parse_args()
    samples, rows = [], []
    finished = threading.Event()
    manifest = json.loads(args.manifest.read_text(encoding='utf-8'))

    def sample():
        previous = {}
        previous_at = time.monotonic()
        while not finished.is_set():
            try:
                gpu = subprocess.check_output(['nvidia-smi', '--query-gpu=memory.used,utilization.gpu', '--format=csv,noheader,nounits'], timeout=3, text=True, creationflags=subprocess.CREATE_NO_WINDOW)
                processes = [p for p in psutil.process_iter(['name']) if any(token in (p.info['name'] or '').lower() for token in ('ollama', 'llama'))]
                rss = sum(p.memory_info().rss for p in processes)
                at = time.monotonic()
                cpu = {p.pid: p.cpu_times().user + p.cpu_times().system for p in processes}
                cpu_percent = sum(max(0, value - previous[pid]) for pid, value in cpu.items() if pid in previous) / max(.001, at-previous_at) * 100
                previous, previous_at = cpu, at
                memory, utilization = map(int, gpu.strip().split(','))
                samples.append({'t': at, 'gpu_used_mib': memory, 'gpu_utilization_percent': utilization,
                                'ollama_and_llama_rss_bytes': rss, 'cpu_core_percent': cpu_percent,
                                'backend_rss_bytes': psutil.Process(args.backend_pid).memory_info().rss if args.backend_pid else None,
                                'system_ram_used_bytes': psutil.virtual_memory().used})
            except (OSError, psutil.Error, subprocess.SubprocessError, ValueError):
                pass
            finished.wait(.5)

    worker = threading.Thread(target=sample, daemon=True)
    worker.start()
    with httpx.Client(timeout=60, trust_env=False) as client:
        for image in manifest:
            started = time.monotonic()
            result = {'image_id': image['id'], 'sha256': image['sha256'], 'cold': False,
                      'captured_at': datetime.now(timezone.utc).isoformat()}
            try:
                response = client.post(args.url.rstrip('/') + '/vlm/describe',
                    data={'request_id': f'quality-{time.time_ns()}-{image["id"]}',
                          'captured_at': result['captured_at'], 'question': 'Опиши видимую сцену кратко на русском языке.'},
                    files={'image': ('frame.jpg', Path(image['path']).read_bytes(), 'image/jpeg')})
                result.update(http_status=response.status_code, response=response.json())
            except (httpx.HTTPError, ValueError) as error:
                result['error'] = str(error)
            result['http_total_ms'] = (time.monotonic() - started) * 1000
            rows.append(result)
            args.output.write_text(json.dumps({'rows': rows, 'resource_samples': samples,
                'cold_request': 'qwen3_vl_first_real_image.json', 'expected_trials': len(manifest),
                'rss_scope': 'Ollama app + Ollama API server + llama-server; sum of Windows working sets, not unique RAM',
                'complete': len(rows) == len(manifest)}, ensure_ascii=False, indent=2), encoding='utf-8')
            print(f"{image['id']}/{len(manifest)}: HTTP {result.get('http_status')} {result['http_total_ms']:.0f} ms", flush=True)
    finished.set()
    worker.join(timeout=5)


if __name__ == '__main__':
    main()
