"""Pure-Python timing checks; never connect to a database or a paid model."""
import copy
import importlib.util
from pathlib import Path
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("playback", ROOT / "backend/sori/playback.py")
playback = importlib.util.module_from_spec(spec)
spec.loader.exec_module(playback)


class PlaybackTests(unittest.TestCase):
    def test_waits_and_two_full_replay_countins_for_all_meters(self):
        for numerator, denominator, expected in [(4,4,434), (3,4,406.5), (6,8,406.5)]:
            metadata = {"time_signature": {"numerator": numerator, "denominator": denominator},
                        "recommended_duration_seconds": 300}
            original = copy.deepcopy(metadata)
            plan = playback.make_playback_plan(metadata)
            self.assertEqual([s["pause_after_ms"] for s in plan["steps"]], [20000]*10+[120000])
            self.assertEqual(plan["initial_delay_ms"], 2000)
            self.assertEqual(plan["pause_after_scale_ms"], 2000)
            self.assertEqual(plan["count_in"]["before_step_orders"], [1, 11])
            self.assertEqual(plan["count_in"]["beats_per_measure"], numerator)
            self.assertEqual(plan["count_in"]["beat_unit"], denominator)
            self.assertGreater(plan["count_in"]["accent_velocity"], plan["count_in"]["velocity"])
            self.assertEqual(playback.duration_seconds(plan, metadata["time_signature"]), expected)
            self.assertEqual(playback.timed_question(metadata)["recommended_duration_seconds"], 434 if numerator == 4 else 407)
            self.assertEqual(metadata, original)

    def test_short_pcm_click_is_shipped_and_not_a_piano_sample(self):
        resource = ROOT / "frontend/IPadApp/IPadApp/Resources/sori-click-v1.wav"
        with wave.open(str(resource), "rb") as wav:
            self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()), (1,2,44100,2205))
            self.assertNotEqual(set(wav.readframes(2205)), {0})


if __name__ == "__main__":
    unittest.main()
