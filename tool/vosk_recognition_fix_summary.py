"""Summarize TZ7.2 evidence without modifying TZ7 historical results."""
import argparse
import json
import math
from pathlib import Path

PHRASES = {
    "Начать": "start", "Закончить": "stop",
    "Что впереди?": "describe", "Опиши окружение": "describeEnvironment",
}


def quantiles(values):
    values = sorted(v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v >= 0)
    return {"n": len(values), "p50_ms": values[math.ceil(len(values) * .5) - 1] if values else None,
            "p95_ms": values[math.ceil(len(values) * .95) - 1] if values else None}


def summarize(rows):
    commands = [r for r in rows if r.get("kind") == "command"]
    negatives = [r for r in rows if r.get("kind") == "negative"]
    silence = [r for r in rows if r.get("kind") == "silence"]

    def valid(row):
        measurement = row.get("measurement") or {}
        return (row.get("valid_measurement") is True and not row.get("error")
                and row.get("build_mode") == "release" and measurement.get("type") == "final"
                and measurement.get("grammar_id") == "v2-context-guards")

    def success(row):
        if not valid(row):
            return False
        action = row.get("action") or {}
        expected = PHRASES.get(row.get("expected"))
        if row.get("kind") != "command":
            return action.get("command") in (None, "unknown") and action.get("executed") is not True
        if expected is None or action.get("command") != expected:
            return False
        if expected == "describeEnvironment":
            return (row.get("spoken_full_phrase_confirmed") is True
                    and action.get("intent_only") is True and action.get("executed") is False)
        return (action.get("executed") is True
                and (expected != "start" or row.get("running_after") is True)
                and (expected != "stop" or row.get("running_after") is False))

    counts = {p: {"attempts": sum(r.get("expected") == p for r in commands),
                  "successes": sum(r.get("expected") == p and success(r) for r in commands)} for p in PHRASES}
    confirmed = sum(r.get("expected") == "Опиши окружение" and r.get("spoken_full_phrase_confirmed") is True for r in commands)
    latencies = quantiles([(r.get("measurement") or {}).get("after_speech_ms") for r in commands])
    complete = (len(rows) == 80 and len({r.get("trial") for r in rows}) == 80
                and {r.get("trial") for r in rows} == set(range(1, 81))
                and len({r.get("run_id") for r in rows}) == 1 and bool(rows[0].get("run_id")))
    result = {
        "suite": "TZ7.2", "trials": len(rows), "complete_series": complete,
        "command_counts": counts, "command_successes": sum(success(r) for r in commands),
        "full_describe_phrase_confirmations": confirmed,
        "negative_attempts": len(negatives), "silence_attempts": len(silence),
        "negative_false_intents": sum((r.get("action") or {}).get("command") not in (None, "unknown") for r in negatives),
        "silence_false_intents": sum((r.get("action") or {}).get("command") not in (None, "unknown") for r in silence),
        "negative_false_actions": sum((r.get("action") or {}).get("executed") is True for r in negatives),
        "silence_false_actions": sum((r.get("action") or {}).get("executed") is True for r in silence),
        "invalid_trials": [r.get("trial") for r in rows if not valid(r)],
        "aligned_after_speech": latencies,
        "modes": {str(active): quantiles([(r.get("measurement") or {}).get("after_speech_ms")
                                         for r in commands if r.get("detector_active_before") is active]) for active in (False, True)},
    }
    result["accuracy_gate"] = (complete and len(commands) == 40 and result["command_successes"] >= 36
                               and all(c["attempts"] == 10 and c["successes"] >= 8 for c in counts.values()) and confirmed == 10)
    result["negative_gate"] = complete and len(negatives) == 20 and all(success(r) for r in negatives)
    result["silence_gate"] = complete and len(silence) == 20 and all(success(r) for r in silence)
    result["latency_gate"] = (len(commands) == 40 and latencies["n"] == 40
                              and latencies["p50_ms"] <= 1500 and latencies["p95_ms"] <= 3000)
    # Unit tests and throughput do not prove warning recall on the real device.
    result["critical_warning_device_gate"] = None
    result["production_voice_actions_enabled_by_default"] = False
    result["acceptance_passed"] = False
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = summarize(json.loads(args.source.read_text(encoding="utf-8-sig")))
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
