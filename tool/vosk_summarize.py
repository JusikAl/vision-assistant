"""Summarize device microphone evidence; never infer missing trial outcomes."""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / 'docs/vosk_human_validation.json'
rows = json.loads(source.read_text(encoding='utf-8-sig'))
commands = [r for r in rows if r.get('kind') == 'command']
negatives = [r for r in rows if r.get('kind') == 'negative']
silence = [r for r in rows if r.get('kind') == 'silence']
phrases = ['Начать', 'Закончить', 'Что впереди?', 'Опиши окружение']

def quantiles(values):
    values = sorted(v for v in values if isinstance(v, (int, float)) and math.isfinite(v))
    return {'n': len(values), 'p50_ms': values[math.ceil(len(values)*.5)-1] if values else None,
            'p95_ms': values[math.ceil(len(values)*.95)-1] if values else None}

def metric(row, key):
    return (row.get('measurement') or {}).get(key)

counts = {p: {'attempts': sum(r['expected'] == p for r in commands),
              'successes': sum(r['expected'] == p and r['success'] for r in commands)} for p in phrases}
summary = {
    'trials': len(rows), 'command_counts': counts,
    'command_successes': sum(r['success'] for r in commands),
    'negative_attempts': len(negatives), 'negative_false_actions': sum(not r['success'] for r in negatives),
    'silence_attempts': len(silence), 'silence_false_actions': sum(not r['success'] for r in silence),
    'aligned_after_speech': quantiles([metric(r, 'after_speech_ms') for r in commands]),
    'native_compute': quantiles([metric(r, 'native_compute_ms') for r in commands]),
    'modes': {str(active): {'commands': sum(r['detector_active_before'] == active for r in commands),
                           'latency': quantiles([metric(r, 'after_speech_ms') for r in commands if r['detector_active_before'] == active]),
                           'rss_bytes_samples': [r['rss_bytes'] for r in rows if r['detector_active_before'] == active]}
              for active in [False, True]},
    'performance_regression_gate': False,
}
summary['accuracy_gate'] = len(commands) == 40 and summary['command_successes'] >= 36 and all(c['attempts'] == 10 and c['successes'] >= 8 for c in counts.values())
summary['negative_gate'] = len(negatives) == 20 and summary['negative_false_actions'] == 0
summary['silence_gate'] = len(silence) == 20 and summary['silence_false_actions'] == 0
latency = summary['aligned_after_speech']
summary['latency_gate_on_available_alignments'] = bool(latency['n'] and latency['p50_ms'] <= 1500 and latency['p95_ms'] <= 3000)
(ROOT / 'docs/vosk_human_summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')

lines = ['## Живые пробы: сохранённые результаты', '',
         f"Получено {len(rows)}/80 проб. Успешных действий: {summary['command_successes']}/{len(commands)} команд.", '',
         '| Фраза | Успех / попытки |', '|---|---:|']
lines += [f"| {p} | {counts[p]['successes']} / {counts[p]['attempts']} |" for p in phrases]
lines += ['', f"Посторонние фразы: {summary['negative_false_actions']} ложных действий / {len(negatives)} проб; тишина: {summary['silence_false_actions']} / {len(silence)}.",
          f"Задержка от конца последнего слова по выравниванию Vosk: n={latency['n']}, p50={latency['p50_ms']}, p95={latency['p95_ms']} мс. Это оценка ASR, не внешняя акустическая разметка; отсутствие выравнивания не подменяется нулём.",
          '', 'Конфигурация всех строк: vosk-model-small-ru-0.22, грамматика 11 фраз + [unk], PCM16/16000/mono, блок 200 мс, worker priority=19, efficiency cores 0–3. A: камера закрыта до команды. B: YOLO/Safety активны до команды. «Начать» может открыть камеру в ходе самого действия.', '',
          '| № | Режим | Ожидание | Сырой Vosk | После речи, мс | Действие | Успех |', '|---:|---|---|---|---:|---|---|']

def cell(value):
    if value is None: return '—'
    return str(value).replace('|', '\\|').replace('\n', ' ').replace('<', '&lt;')

for r in rows:
    measured = r.get('measurement') or {}
    action = r.get('action') or {}
    duration = measured.get('after_speech_ms')
    lines.append('| ' + ' | '.join(map(cell, [r['trial'], 'B' if r['detector_active_before'] else 'A', r['expected'], measured.get('raw_text'), round(duration, 1) if duration is not None else None, action.get('command'), 'да' if r['success'] else 'нет'])) + ' |')
lines += ['', 'Источник: vosk_human_validation.json; сводка: vosk_human_summary.json. Успех команды означает сопоставление финальной фразы и завершившееся действие Flutter; это не измерение полноты детекции опасностей. Для отрицательных проб «успех» означает отсутствие выполнения поддерживаемой команды.', '', 'Полная приёмка MVP остаётся отрицательной по нагрузочному тесту YOLO независимо от результата этой серии.']
report = ROOT / 'docs/vosk_offline_report.md'
text = report.read_text(encoding='utf-8-sig').split('<!-- LIVE_RESULTS -->')[0]
report.write_text(text.rstrip() + '\n\n<!-- LIVE_RESULTS -->\n' + '\n'.join(lines) + '\n', encoding='utf-8')
print(json.dumps({k: v for k, v in summary.items() if k != 'modes'}, ensure_ascii=True))
