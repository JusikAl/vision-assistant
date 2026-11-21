import unittest

from vosk_recognition_fix_summary import PHRASES, summarize


class AcceptanceEvidenceTest(unittest.TestCase):
    def series(self):
        rows = []
        for phrase, intent in PHRASES.items():
            for _ in range(10):
                rows.append({
                    "trial": len(rows) + 1, "run_id": "unit-fixture-only", "kind": "command",
                    "expected": phrase, "valid_measurement": True, "build_mode": "release",
                    "measurement": {"type": "final", "grammar_id": "v2-context-guards", "after_speech_ms": 1100},
                    "spoken_full_phrase_confirmed": intent == "describeEnvironment",
                    "running_after": intent == "start",
                    "action": {"command": intent, "executed": intent != "describeEnvironment",
                               "intent_only": intent == "describeEnvironment"},
                })
        for kind in ("negative", "silence"):
            for _ in range(20):
                rows.append({"trial": len(rows) + 1, "run_id": "unit-fixture-only", "kind": kind,
                             "valid_measurement": True, "build_mode": "release",
                             "measurement": {"type": "final", "grammar_id": "v2-context-guards"}})
        return rows

    def test_complete_evidence_still_requires_device_safety_acceptance(self):
        summary = summarize(self.series())
        for key in ("accuracy_gate", "negative_gate", "silence_gate", "latency_gate"):
            self.assertTrue(summary[key], key)
        self.assertFalse(summary["acceptance_passed"])

    def test_missing_full_phrase_confirmation_fails_accuracy(self):
        rows = self.series()
        rows[30]["spoken_full_phrase_confirmed"] = None
        self.assertFalse(summarize(rows)["accuracy_gate"])

    def test_cancelled_control_is_not_successful_silence(self):
        rows = self.series()
        rows[-1]["error"] = "Interrupted by Safety"
        summary = summarize(rows)
        self.assertEqual(summary["silence_false_actions"], 0)
        self.assertFalse(summary["silence_gate"])

    def test_stored_success_flag_does_not_hide_unwanted_actions(self):
        rows = self.series()
        rows[40].update(success=True, action={"command": "start", "executed": True})
        summary = summarize(rows)
        self.assertFalse(summary["negative_gate"])
        self.assertEqual(summary["negative_false_actions"], 1)

    def test_duplicate_or_missing_trials_never_form_complete_series(self):
        rows = self.series()
        rows[-1]["trial"] = 1
        self.assertFalse(summarize(rows)["complete_series"])
        self.assertFalse(summarize(rows[:-1])["accuracy_gate"])

    def test_old_grammar_or_profile_is_not_release_v2_evidence(self):
        rows = self.series()
        rows[0]["measurement"]["grammar_id"] = "v1-commands"
        rows[1]["build_mode"] = "profile"
        self.assertEqual(summarize(rows)["invalid_trials"], [1, 2])

    def test_missing_alignment_does_not_silently_pass_latency(self):
        rows = self.series()
        rows[0]["measurement"]["after_speech_ms"] = None
        self.assertFalse(summarize(rows)["latency_gate"])


if __name__ == "__main__":
    unittest.main()
