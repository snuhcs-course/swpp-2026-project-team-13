"""Fractional-score Elo on the reviewed difficulty scale (one exam = one result).

This is a product calibration model, not an empirically validated ability test.
At equal rating/difficulty the expected AI grade is 80/100. No 100-point ceiling.
"""
from bisect import bisect_right
from dataclasses import dataclass
import math
import random

VERSION = "exam-rating-1"
INITIAL_RATING = 7.0
# Frozen v1 mapping. A future difficulty policy must not silently change Elo.
CUTOFFS = (7.5, 9.5, 13., 30., 55., 62., 68., 74.)
KNOTS = (0.0,) + CUTOFFS
TAIL_WIDTH = CUTOFFS[-1] - CUTOFFS[-2]


def number(value, name, maximum=None):
    if (type(value) not in (int, float) or not math.isfinite(value) or value < 0
            or (maximum is not None and value > maximum)):
        raise ValueError("invalid_" + name)
    return float(value)


def to_skill(score):
    score = number(score, "score")
    index = bisect_right(KNOTS, score) - 1
    width = TAIL_WIDTH if index == len(KNOTS) - 1 else KNOTS[index + 1] - KNOTS[index]
    return index + (score - KNOTS[index]) / width


def from_skill(skill):
    skill = number(skill, "skill")
    index = min(int(skill), len(KNOTS) - 1)
    width = TAIL_WIDTH if index == len(KNOTS) - 1 else KNOTS[index + 1] - KNOTS[index]
    return KNOTS[index] + (skill - index) * width


def expected_fraction(rating, difficulty):
    value = math.log(4) + (to_skill(rating) - to_skill(difficulty)) / .5
    if value >= 0:
        return 1 / (1 + math.exp(-value))
    z = math.exp(value)
    return z / (1 + z)


def learning_rate(completed):
    if type(completed) is not int or completed < 0:
        raise ValueError("invalid_completed")
    return .25 + .5 * math.exp(-completed / 5)


def update(rating, completed, difficulty, grade):
    grade = number(grade, "grade", 100)
    before = to_skill(rating)
    expected = expected_fraction(rating, difficulty)
    k = learning_rate(completed)
    step = min(.5, max(-.5, k * (grade / 100 - expected)))
    after = from_skill(max(0, before + step))
    return dict(before=float(rating), after=after, delta=after-rating,
                difficulty=float(difficulty), grade=grade, expected_score=expected*100,
                completed_before=completed, k=k, model_version=VERSION)


@dataclass(frozen=True)
class Question:
    id: str
    difficulty: float


def recommendations(rating, questions, *, seen=(), seed=0):
    """Draw from continuous score bands, without recycling or false edge labels.

    Prefer the prototype's expected-grade bands; if sparse, take the nearest
    candidate in the correct direction. Matched stays within half a skill unit.
    A service persists the result, so repeated GETs cannot reroll the choices.
    """
    number(rating, "rating")
    items = sorted(questions, key=lambda q: q.id)
    if len({q.id for q in items}) != len(items):
        raise ValueError("duplicate_question_id")
    for q in items:
        number(q.difficulty, "difficulty")
    seen = set(seen)
    available = [q for q in items if q.id not in seen]
    rng = random.Random(seed)
    selected = {}
    for category, target, lo, hi in (("matched", .8, .75, .85),
                                     ("challenge", .625, .55, .70),
                                     ("easy", .915, .88, .95)):
        matched = selected.get("matched")
        eligible = [q for q in available if q.id not in {v.id for v in selected.values() if v}]
        if category == "challenge":
            eligible = [q for q in eligible if q.difficulty > max(rating, matched.difficulty if matched else rating)]
        elif category == "easy":
            eligible = [q for q in eligible if q.difficulty < min(rating, matched.difficulty if matched else rating)]
        else:
            eligible = [q for q in eligible if abs(to_skill(q.difficulty)-to_skill(rating)) <= .5]
        preferred = [q for q in eligible if lo <= expected_fraction(rating, q.difficulty) <= hi]
        if (not preferred or category == "matched") and eligible:
            # A small nearest-score set keeps sparse-band choices meaningful.
            preferred = sorted(eligible, key=lambda q: (abs(expected_fraction(rating, q.difficulty)-target), q.id))[:5]
        selected[category] = rng.choice(preferred) if preferred else None
    return [dict(category=category, question_id=selected[category].id,
                 difficulty_score=selected[category].difficulty,
                 rating_difference=selected[category].difficulty-rating)
            if selected[category] else dict(category=category, question_id=None, reason="no_unseen_question")
            for category in ("challenge", "matched", "easy")]
