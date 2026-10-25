"""Current exam timing; stored attempts keep their original immutable plan."""
import copy
import math

RANGES = [(1, 8), (1, 2), (1, 2), (1, 4), (3, 4), (3, 6), (5, 6), (5, 8), (7, 8), (7, 8), (1, 8)]


def make_playback_plan(metadata):
    meter = metadata["time_signature"]
    return {
        "version": 3, "engine": "local_midi", "tempo_bpm": metadata.get("tempo_bpm", 96),
        "instrument_profile_id": "sori-piano-v1", "tuning_hz": 440,
        "transpose_semitones": 0, "velocity": 80, "gate_ratio": 1.0, "release_tail_ms": 300,
        "initial_delay_ms": 2000,
        "scale": {"score_kind": "scale", "from_measure": 1, "to_measure": 2},
        "pause_after_scale_ms": 2000,
        "count_in": {
            "measures": 1, "before_step_orders": [1, 11],
            "beats_per_measure": meter["numerator"], "beat_unit": meter["denominator"],
            "accent_velocity": 110, "velocity": 70, "profile_id": "sori-click-v1",
        },
        "allow_manual_pause": True, "allow_manual_replay": False,
        "interruption_policy": "restart_current_segment",
        "steps": [
            {"order": i + 1, "from_measure": a, "to_measure": b, "score_kind": "main",
             "pause_after_ms": 120000 if i == len(RANGES) - 1 else 20000}
            for i, (a, b) in enumerate(RANGES)
        ],
    }


def duration_seconds(plan, meter):
    """Nominal audio + all silence. Release tails are inside, not added to, pauses."""
    quarter_notes_per_bar = meter["numerator"] * 4 / meter["denominator"]
    scale_bars = plan["scale"]["to_measure"] - plan["scale"]["from_measure"] + 1
    main_bars = sum(s["to_measure"] - s["from_measure"] + 1 for s in plan["steps"])
    count_in = plan.get("count_in") or {}
    count_bars = count_in.get("measures", 0) * len(count_in.get("before_step_orders", []))
    audio = (scale_bars + main_bars + count_bars) * quarter_notes_per_bar * 60 / plan["tempo_bpm"]
    silence = (plan.get("initial_delay_ms", 0) + plan["pause_after_scale_ms"] +
               sum(s["pause_after_ms"] for s in plan["steps"])) / 1000
    return audio + silence


def timed_question(metadata):
    result = copy.deepcopy(metadata)
    plan = make_playback_plan(result)
    result["recommended_duration_seconds"] = math.ceil(duration_seconds(plan, result["time_signature"]))
    return result
