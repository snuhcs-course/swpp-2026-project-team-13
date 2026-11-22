"""First-Exam level test: one easy question, then optional medium and hard ones.

Each stage is an ordinary AI-graded exam attempt whose frozen rating snapshot
carries `level_test`. Those grades never move the Elo rating one exam at a
time. When the learner stops (or a stage misses the pass grade), the server
places the first rating once from every graded stage. Skipping starts at 0.
"""
import random
from django.db import transaction
from . import rating
from .errors import ContractError
from .models import Attempt

VERSION = "level-test-1"
PASS_GRADE = 80
SKIP_RATING = 0.0
TIERS = ("easy", "medium", "hard")
# Anchors on the frozen difficulty scale (levels 2, 4 and 6 of the cutoffs).
TARGETS = {"easy": 9.0, "medium": 21.5, "hard": 58.5}
NEAREST = 5


def _locked_state(user):
    from .exam_rating import locked_state
    return locked_state(user)


def _rated_history(user):
    # A learner who already took (or reserved) a rated exam keeps the old flow.
    return (Attempt.objects.filter(user=user, mode="exam", exam_rating_snapshot__isnull=False)
            .exclude(exam_rating_snapshot__has_key="level_test").exists())


def status(state):
    data = state.level_test or {}
    if data.get("status") in ("completed", "skipped"):
        return data["status"]
    if data.get("stages"):
        return "in_progress"
    if state.completed or _rated_history(state.user):
        return "not_applicable"
    return "required"


def _next_stage(state):
    current = status(state)
    if current == "required":
        return 1
    if current != "in_progress":
        return None
    last = state.level_test["stages"][-1]
    if last.get("grade") is None or last["grade"] < PASS_GRADE or last["stage"] >= len(TIERS):
        return None
    return last["stage"] + 1


def state_json(state):
    current = status(state)
    stages = [dict(stage=s["stage"], tier=s["tier"], attempt_id=s["attempt_id"], grade=s.get("grade"),
                   passed=None if s.get("grade") is None else s["grade"] >= PASS_GRADE)
              for s in (state.level_test or {}).get("stages", [])]
    return dict(version=VERSION, status=current, pass_grade=PASS_GRADE, skip_rating=SKIP_RATING,
                stages=stages, next_stage=_next_stage(state),
                can_finish=current == "in_progress" and stages[-1]["grade"] is not None,
                rating=state.rating if current in ("completed", "skipped") else None)


def current(user):
    with transaction.atomic():
        return state_json(_locked_state(user))


def next_question(user):
    """Pick (once) the question for the next stage. Repeated calls return it again."""
    from .practice_bank import timed_practice_question
    from .recommendation import current_versions
    with transaction.atomic():
        state = _locked_state(user)
        stage = _next_stage(state)
        if stage is None:
            raise ContractError("LEVEL_TEST_STAGE_UNAVAILABLE", "지금은 다음 레벨 테스트 문제를 풀 수 없어요.", 409)
        data = dict(state.level_test or {})
        versions = {str(v.question_id): v for v in current_versions("exam")}
        seen = set(str(q) for q in Attempt.objects.filter(user=user).values_list("question_version__question_id", flat=True))
        pending = data.get("next")
        if (pending and pending["stage"] == stage and pending["question_id"] in versions and pending["question_id"] not in seen
                and versions[pending["question_id"]].version == pending["question_version"]):
            return pending
        tier = TIERS[stage - 1]
        target = rating.to_skill(TARGETS[tier])
        candidates = []
        for qid, version in versions.items():
            score = timed_practice_question(version.metadata).get("difficulty_score")
            if qid not in seen and score is not None:
                candidates.append((abs(rating.to_skill(score) - target), qid, score))
        nearest = sorted(candidates)[:NEAREST]
        if not nearest:
            raise ContractError("LEVEL_TEST_QUESTION_UNAVAILABLE", "레벨 테스트 문제를 준비하지 못했어요.", 503)
        _, qid, score = random.Random(f"{user.pk}:{VERSION}:{stage}").choice(nearest)
        pending = dict(stage=stage, tier=tier, question_id=qid, question_version=versions[qid].version, difficulty_score=score)
        data.update(version=VERSION, next=pending)
        data.setdefault("stages", [])
        state.level_test = data
        state.save(update_fields=["level_test", "updated_at"])
        return pending


def reserve(user, version, snapshot, stage):
    """Caller holds create_attempt's transaction. Freezes the stage on the attempt."""
    from .exam_rating import reserve_exam
    state = _locked_state(user)
    pending = (state.level_test or {}).get("next")
    if (not pending or pending["stage"] != stage or pending["question_id"] != str(version.question_id)
            or pending["question_version"] != version.version or _next_stage(state) != stage):
        raise ContractError("LEVEL_TEST_QUESTION_MISMATCH", "레벨 테스트 문제가 바뀌었어요. 다시 시작해 주세요.", 409)
    frozen = reserve_exam(user, version, snapshot)
    frozen["level_test"] = dict(version=VERSION, stage=stage, tier=pending["tier"])
    return frozen


def record_stage(attempt):
    """Caller holds create_attempt's transaction, right after the attempt exists."""
    stage = attempt.exam_rating_snapshot["level_test"]
    state = _locked_state(attempt.user)
    data = dict(state.level_test)
    data.pop("next", None)
    data["stages"] = data.get("stages", []) + [dict(
        stage=stage["stage"], tier=stage["tier"], attempt_id=str(attempt.id),
        question_id=str(attempt.question_version.question_id),
        difficulty_score=attempt.exam_rating_snapshot["difficulty_score"], grade=None)]
    state.level_test = data
    state.save(update_fields=["level_test", "updated_at"])


def record_grade(attempt, job):
    """Caller locks the attempt inside finish_job. Only the first completed grade counts."""
    state = _locked_state(attempt.user)
    data = dict(state.level_test or {})
    stages = [dict(s) for s in data.get("stages", [])]
    for item in stages:
        if item["attempt_id"] == str(attempt.id) and item.get("grade") is None:
            item["grade"] = int(job.score)
            data["stages"] = stages
            state.level_test = data
            state.save(update_fields=["level_test", "updated_at"])
            return


def finish(user):
    with transaction.atomic():
        state = _locked_state(user)
        current_status = status(state)
        if current_status == "completed":
            return state_json(state)
        stages = (state.level_test or {}).get("stages", [])
        if current_status != "in_progress" or stages[-1].get("grade") is None:
            raise ContractError("LEVEL_TEST_NOT_FINISHABLE", "채점이 끝난 뒤 레벨 테스트를 마칠 수 있어요.", 409)
        graded = [(s["difficulty_score"], s["grade"]) for s in stages if s.get("grade") is not None]
        state.rating = rating.placement(graded)
        data = dict(state.level_test)
        data.pop("next", None)
        data["status"] = "completed"
        state.level_test = data
        state.offer = {}
        state.save(update_fields=["rating", "level_test", "offer", "updated_at"])
        return state_json(state)


def skip(user):
    with transaction.atomic():
        state = _locked_state(user)
        current_status = status(state)
        if current_status == "skipped":
            return state_json(state)
        if current_status != "required":
            raise ContractError("LEVEL_TEST_NOT_SKIPPABLE", "이미 시작한 레벨 테스트는 건너뛸 수 없어요.", 409)
        state.rating = SKIP_RATING
        data = dict(state.level_test or {})
        data.pop("next", None)
        data.update(version=VERSION, status="skipped", stages=[])
        state.level_test = data
        state.offer = {}
        state.save(update_fields=["rating", "level_test", "offer", "updated_at"])
        return state_json(state)
