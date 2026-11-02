"""Independent checks for the configurable tempo and full ascending/descending scale."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("playback",ROOT/"backend/sori/playback.py")
playback = importlib.util.module_from_spec(spec)
spec.loader.exec_module(playback)
CATALOG=json.loads((ROOT/"backend/content/catalog.json").read_text(encoding="utf-8"))


class PlaybackTests(unittest.TestCase):
    def test_waits_countins_and_real_scale_length_for_all_meters(self):
        expected={(4,4):(80,456),(3,4):(80,425.25),(6,8):(82.5,422.1818181818182),(2,4):(80,393),(7,8):(80,442.125),(9,8):(82.5,468),(12,8):(82.5,516)}
        for item in CATALOG:
            metadata=item["metadata"];original=copy.deepcopy(metadata);meter=metadata["time_signature"]
            key=(meter["numerator"],meter["denominator"]);bpm,seconds=expected[key]
            plan=playback.make_playback_plan(metadata)
            self.assertEqual(plan["version"],4)
            self.assertEqual(plan["tempo_bpm"],bpm)
            self.assertEqual(plan["scale"]["to_measure"],metadata["score_assets"]["scale"]["measure_count"])
            self.assertEqual([s["pause_after_ms"] for s in plan["steps"]],[20000]*10+[120000])
            self.assertEqual((plan["initial_delay_ms"],plan["pause_after_scale_ms"]),(2000,2000))
            self.assertEqual(plan["count_in"]["before_step_orders"],[1,11])
            self.assertEqual(plan["count_in"]["beats_per_measure"],meter["numerator"])
            self.assertEqual(plan["count_in"]["beat_unit"],meter["denominator"])
            self.assertGreater(plan["count_in"]["accent_velocity"],plan["count_in"]["velocity"])
            self.assertAlmostEqual(playback.duration_seconds(plan,meter),seconds)
            self.assertEqual(metadata,original)

    def test_six_eighth_note_clicks_at_dotted_quarter_55(self):
        tempo=playback.resolve_tempo({"numerator":6,"denominator":8})
        interval=60/playback.quarter_bpm(tempo)/2
        self.assertAlmostEqual(interval,60/(55*3))
        self.assertAlmostEqual(6*interval,2*60/55)

    def test_future_selection_uses_ranges_and_does_not_rewrite_a_snapshot(self):
        for n,d,low,high in [(4,4,72,96),(3,4,72,96),(6,8,48,66)]:
            meter={"numerator":n,"denominator":d};metadata={"time_signature":meter}
            saved=playback.make_playback_plan(metadata)
            original=copy.deepcopy(saved)
            faster=playback.make_playback_plan(metadata,selected_bpm=high)
            self.assertEqual(faster["tempo"]["bpm"],high)
            self.assertEqual(saved,original)
            for invalid in [low-1,high+1,True,55.5]:
                with self.assertRaises(ValueError):
                    playback.make_playback_plan(metadata,selected_bpm=invalid)

    def test_short_pcm_click_is_shipped(self):
        with wave.open(str(ROOT/"frontend/IPadApp/IPadApp/Resources/sori-click-v1.wav"),"rb") as wav:
            self.assertEqual((wav.getnchannels(),wav.getsampwidth(),wav.getframerate(),wav.getnframes()),(1,2,44100,2205))
            self.assertNotEqual(set(wav.readframes(2205)),{0})


    def test_current_api_fixture_matches_the_selected_tempo_and_scale(self):
        fixture=json.loads((ROOT/"docs/sori-api/examples/attempt-ready-v4.json").read_text(encoding="utf-8"))
        current=playback.timed_question(CATALOG[0]["metadata"])
        self.assertEqual(fixture["question"],current)
        self.assertEqual(fixture["playback_plan"],playback.make_playback_plan(current))

if __name__=="__main__":
    unittest.main()
