"""Transactional offers and exactly-once, server-authoritative rating updates."""
import uuid
from django.db import transaction
from . import rating
from .errors import ContractError
from .models import Attempt, ExamRatingChange, ExamRatingState
from .practice_bank import timed_practice_question
from .question_pools import manifest as pool_manifest, membership


def locked_state(user):
    ExamRatingState.objects.get_or_create(user=user)
    return ExamRatingState.objects.select_for_update().get(user=user)


def state_json(state):
    return dict(value=state.rating, completed=state.completed, model_version=rating.VERSION)


def active_exam(user):
    # Old, unrated attempts remain readable without blocking the new Exam flow.
    # Failed grading is still unresolved: retry the same answer before a new exam.
    return (Attempt.objects.filter(user=user, mode="exam", exam_rating_snapshot__isnull=False)
            .exclude(status="submitted", current_job__status="completed")
            .order_by("created_at", "id").first())


def offer_for(user):
    from .recommendation import current_versions
    with transaction.atomic():
        state = locked_state(user)
        active = active_exam(user)
        if active is not None:
            return dict(id=str(active.id), pool_version=pool_manifest()["version"],
                        rating=state_json(state), choices=[], active_attempt_id=str(active.id))
        seen = set(str(q) for q in Attempt.objects.filter(user=user).values_list("question_version__question_id", flat=True))
        versions = {str(v.question_id): v for v in current_versions("exam")}
        eligible_count = len(set(versions)-seen)
        if state.offer and state.offer.get("eligible_count") == eligible_count and all(c.get("question_id") is None or
                               (c["question_id"] in versions and c["question_id"] not in seen and
                                c["question_version"] == versions[c["question_id"]].version)
                               for c in state.offer["choices"]):
            return dict(**state.offer, rating=state_json(state))
        candidates = []
        for qid, version in versions.items():
            metadata = timed_practice_question(version.metadata)
            if metadata.get("difficulty_score") is not None:
                candidates.append(rating.Question(qid, metadata["difficulty_score"]))
        offer_id = uuid.uuid4()
        choices = rating.recommendations(state.rating, candidates, seen=seen, seed=str(offer_id))
        for choice in choices:
            if choice["question_id"]:
                choice["question_version"] = versions[choice["question_id"]].version
        state.offer = dict(id=str(offer_id), pool_version=pool_manifest()["version"], eligible_count=eligible_count, choices=choices)
        state.save(update_fields=["offer", "updated_at"])
        return dict(**state.offer, rating=state_json(state))


def reserve_exam(user, version, snapshot):
    """Caller holds create_attempt's transaction; the state serializes one user."""
    state = locked_state(user)
    if membership(version.question_id) != "exam":
        raise ContractError("QUESTION_NOT_IN_EXAM_POOL", "Exam 전용 문제를 선택해 주세요.", 409)
    if Attempt.objects.filter(user=user, question_version__question_id=version.question_id).exists():
        raise ContractError("EXAM_QUESTION_ALREADY_SEEN", "이미 선택한 시험 문제입니다. 진행 중인 시험은 이어서 풀어 주세요.", 409)
    if active_exam(user) is not None:
        raise ContractError("EXAM_ALREADY_ACTIVE", "진행 중인 시험이나 채점 결과를 먼저 확인해 주세요.", 409)
    difficulty = snapshot.get("difficulty_score")
    if difficulty is None or snapshot.get("difficulty_version") is None:
        raise ContractError("QUESTION_DIFFICULTY_UNAVAILABLE", "시험 난이도 정보를 준비하지 못했습니다.", 503)
    state.offer = {}
    state.save(update_fields=["offer", "updated_at"])
    return dict(model_version=rating.VERSION, pool_version=pool_manifest()["version"],
                difficulty_version=snapshot["difficulty_version"], difficulty_score=difficulty)


def apply_rating(attempt, job):
    """Caller locks attempt first; grade and rating commit or roll back together."""
    snap = attempt.exam_rating_snapshot
    if (attempt.mode != "exam" or not snap or job.status != "completed" or
            attempt.current_job_id != job.id or job.score is None):
        return None
    existing = ExamRatingChange.objects.filter(attempt=attempt).first()
    if existing:
        return existing
    if snap["model_version"] != rating.VERSION:
        raise ValueError("unsupported_frozen_rating_version")
    state = locked_state(attempt.user)
    change = rating.update(state.rating, state.completed, snap["difficulty_score"], job.score)
    result = ExamRatingChange.objects.create(attempt=attempt, **change,
        difficulty_version=snap["difficulty_version"], pool_version=snap["pool_version"])
    state.rating = change["after"]
    state.completed += 1
    state.offer = {}
    state.save(update_fields=["rating", "completed", "offer", "updated_at"])
    return result


def change_json(attempt_id):
    change = ExamRatingChange.objects.filter(attempt_id=attempt_id).first()
    if change is None:
        return None
    return dict(before=change.before, after=change.after, delta=change.delta,
                difficulty=change.difficulty, grade=change.grade,
                expected_score=change.expected_score, completed_before=change.completed_before,
                model_version=change.model_version, difficulty_version=change.difficulty_version,
                pool_version=change.pool_version)
