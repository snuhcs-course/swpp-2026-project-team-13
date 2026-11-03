"""Pin a verified musical snapshot before starting a learning activity."""
import hashlib
from pathlib import Path
from django.conf import settings
from . import FeatureError, analyze
from .storage import store_analysis


def ensure_question_analysis(version):
    root = Path(settings.CONTENT_ROOT).resolve()
    path = (root / version.main_path).resolve()
    if not path.is_relative_to(root):
        raise FeatureError("content_path_outside_root")
    asset = version.metadata.get("score_assets", {}).get("main", {})
    if path.stat().st_size != asset.get("size_bytes") or hashlib.sha256(path.read_bytes()).hexdigest() != asset.get("sha256"):
        raise FeatureError("source_asset_mismatch")
    payload = analyze(path, question_id=str(version.question_id), question_version=version.version)
    return store_analysis(version, payload)[0]
