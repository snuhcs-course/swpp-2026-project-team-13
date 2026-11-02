"""Persistence boundary. Never upsert over an earlier musical interpretation."""
import hashlib
from django.db import transaction
from .analysis import SCHEMA_VERSION, analysis_key, canonical_json
from .musicxml import FeatureError
from ..models import FeatureAnalysis


@transaction.atomic
def store_analysis(question_version, payload):
    if payload.get("question_id") != str(question_version.question_id) or payload.get("question_version") != question_version.version:
        raise FeatureError("analysis_question_mismatch")
    if payload.get("schema_version") != SCHEMA_VERSION or payload.get("analysis_status") not in ("complete", "partial"):
        raise FeatureError("invalid_analysis_payload")
    if payload.get("analysis_key") != analysis_key(payload):
        raise FeatureError("analysis_key_mismatch")
    digest = hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()
    row, created = FeatureAnalysis.objects.get_or_create(
        analysis_key=payload["analysis_key"], defaults=dict(
            question_version=question_version, schema_version=payload["schema_version"],
            extractor_version=payload["extractor_version"], source_xml_sha256=payload["source_xml_sha256"],
            config=payload["config"], analysis_status=payload["analysis_status"],
            payload_sha256=digest, payload=payload))
    if not created and (row.question_version_id != question_version.pk or row.payload_sha256 != digest
                        or canonical_json(row.payload) != canonical_json(payload)):
        raise FeatureError("analysis_identity_conflict")
    return row, created
