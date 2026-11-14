
import argparse
import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path

METRICS = ['raw_distance_m', 'calibrated_distance_m', 'distance_m']


def to_float(value):
    try:
        x = float(value)
        return x if math.isfinite(x) and x > 0 else None
    except (ValueError, TypeError):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('csv_path', type=Path)
    parser.add_argument('--output', type=Path, default=Path('depth_summary.csv'))
    args = parser.parse_args()
    with args.csv_path.open(newline='', encoding='utf-8') as f:
        rows = list(csv.DictReader(f))
    groups = defaultdict(list)
    for row in rows:
        actual = to_float(row.get('actual_distance_m'))
        if actual is None:
            continue
        groups[(row.get('mode'), actual, row.get('target_class'))].append(row)

    summary = []
    for (mode, actual, target), group in sorted(groups.items(), key=lambda x: (str(x[0][0]), x[0][1])):
        for metric in METRICS:
            values = [to_float(r.get(metric)) for r in group]
            values = [v for v in values if v is not None]
            if not values:
                continue
            errors = [v - actual for v in values]
            abs_errors = [abs(e) for e in errors]
            n = len(values)
            entry = {
                'mode': mode, 'real_distance_m': actual, 'target_class': target,
                'metric': metric, 'frames_total': len(group), 'frames_valid': n,
                'mean_predicted_m': round(statistics.mean(values), 4),
                'bias_m': round(statistics.mean(errors), 4),
                'mae_m': round(statistics.mean(abs_errors), 4),
                'rmse_m': round(math.sqrt(statistics.mean([e*e for e in errors])), 4),
                'mape_percent': round(statistics.mean(abs_errors) / actual * 100, 2),
                'std_m': round(statistics.stdev(values), 4) if n > 1 else 0,
                'min_m': min(values), 'max_m': max(values),
                'dangerous_overestimation_rate_percent': round(sum(v > actual for v in values) / n * 100, 2),
            }
            summary.append(entry)
            print(f'{mode:7s} real={actual:4.1f}m {metric:23s} N={n:3d} '
                  f'MAE={entry["mae_m"]:6.3f}m RMSE={entry["rmse_m"]:6.3f}m '
                  f'std={entry["std_m"]:6.3f}m')

    if not summary:
        raise SystemExit('No valid distance observations found.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=summary[0].keys())
        writer.writeheader()
        writer.writerows(summary)
    print('Saved', args.output)


if __name__ == '__main__':
    main()
