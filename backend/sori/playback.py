"""Playback policy; resolved tempo is snapshotted in each newly created attempt."""
import copy
import json
import math
from pathlib import Path

RANGES = [(1,8),(1,2),(1,2),(1,4),(3,4),(3,6),(5,6),(5,8),(7,8),(7,8),(1,8)]
POLICIES = json.loads((Path(__file__).resolve().parents[1] / "content/playback-settings.json").read_text(encoding="utf-8"))


def resolve_tempo(meter, selected_bpm=None):
    """Future learner-level selection calls this once, before creating an attempt."""
    policy = POLICIES["meters"][f'{meter["numerator"]}/{meter["denominator"]}']
    bpm = policy["default_bpm"] if selected_bpm is None else selected_bpm
    if type(bpm) is not int or not policy["minimum_bpm"] <= bpm <= policy["maximum_bpm"]:
        raise ValueError("Tempo is outside the configured meter-specific range")
    return {"policy_id": POLICIES["id"], "beat_unit": policy["beat_unit"], "bpm": bpm,
            "minimum_bpm": policy["minimum_bpm"], "maximum_bpm": policy["maximum_bpm"]}


def quarter_bpm(tempo):
    return tempo["bpm"] * (1.5 if tempo["beat_unit"] == "dotted_quarter" else 1)


def make_playback_plan(metadata, selected_bpm=None):
    meter = metadata["time_signature"]
    tempo = resolve_tempo(meter, selected_bpm)
    scale_measures = metadata.get("score_assets", {}).get("scale", {}).get("measure_count", 2)
    return {
        "version": 4, "engine": "local_midi", "tempo_bpm": quarter_bpm(tempo), "tempo": tempo,
        "instrument_profile_id": "sori-piano-v2", "tuning_hz": 440,
        "transpose_semitones": 0, "velocity": 80, "gate_ratio": 1.0, "release_tail_ms": 300,
        "initial_delay_ms": 2000,
        "scale": {"score_kind": "scale", "from_measure": 1, "to_measure": scale_measures},
        "pause_after_scale_ms": 2000,
        "count_in": {"measures": 1, "before_step_orders": [1,11],
                     "beats_per_measure": meter["numerator"], "beat_unit": meter["denominator"],
                     "accent_velocity": 110, "velocity": 70, "profile_id": "sori-click-v1"},
        "allow_manual_pause": True, "allow_manual_replay": False,
        "interruption_policy": "restart_current_segment",
        "steps": [{"order":i+1,"from_measure":a,"to_measure":b,"score_kind":"main",
                   "pause_after_ms":120000 if i==10 else 20000} for i,(a,b) in enumerate(RANGES)]
    }


def duration_seconds(plan, meter):
    quarter_notes_per_bar = meter["numerator"] * 4 / meter["denominator"]
    scale_bars = plan["scale"]["to_measure"] - plan["scale"]["from_measure"] + 1
    main_bars = sum(s["to_measure"] - s["from_measure"] + 1 for s in plan["steps"])
    count = plan.get("count_in") or {}
    count_bars = count.get("measures", 0) * len(count.get("before_step_orders", []))
    audio = (scale_bars + main_bars + count_bars) * quarter_notes_per_bar * 60 / plan["tempo_bpm"]
    silence = (plan.get("initial_delay_ms",0) + plan["pause_after_scale_ms"] +
               sum(s["pause_after_ms"] for s in plan["steps"])) / 1000
    return audio + silence


def timed_question(metadata, selected_bpm=None):
    result = copy.deepcopy(metadata)
    plan = make_playback_plan(result, selected_bpm)
    result["tempo"] = plan["tempo"]
    result["recommended_duration_seconds"] = math.ceil(duration_seconds(plan,result["time_signature"]))
    return result
