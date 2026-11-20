"""Authenticated, immutable drill files; no user files enter this manifest."""
import json
import re
from functools import lru_cache
from pathlib import Path
from django.conf import settings
from django.http import FileResponse
from rest_framework.decorators import api_view, renderer_classes
from rest_framework.renderers import JSONRenderer, BaseRenderer
from rest_framework.response import Response
from .errors import ContractError

class XMLRenderer(BaseRenderer):
    media_type='application/xml'
    format='xml'
    def render(self,data,accepted_media_type=None,renderer_context=None):
        return JSONRenderer().render(data,renderer_context=renderer_context)

@lru_cache(maxsize=4)
def _load(root):return json.loads((Path(root)/'client-content-manifest.json').read_text(encoding='utf-8'))
def manifest_data():return _load(str(settings.CONTENT_ROOT.resolve()))

@api_view(['GET'])
@renderer_classes([JSONRenderer])
def manifest(request):
    value=manifest_data()
    assets={name:{**entry,'url':request.build_absolute_uri(f'/api/v1/content/assets/{entry["sha256"]}/')} for name,entry in value['assets'].items()}
    return Response({'version':value['version'],'assets':assets})

@api_view(['GET'])
@renderer_classes([JSONRenderer,XMLRenderer])
def asset(request,digest):
    if not re.fullmatch('[a-f0-9]{64}',digest):raise ContractError('RESOURCE_NOT_FOUND','문제 파일을 찾을 수 없습니다.',404)
    entry=manifest_data()['files'].get(digest)
    if not entry:raise ContractError('RESOURCE_NOT_FOUND','문제 파일을 찾을 수 없습니다.',404)
    root=settings.CONTENT_ROOT.resolve();path=(root/entry['path']).resolve()
    if not path.is_relative_to(root) or not path.is_file():raise ContractError('RESOURCE_NOT_FOUND','문제 파일을 찾을 수 없습니다.',404)
    response=FileResponse(path.open('rb'),content_type=entry['content_type'])
    response['ETag']='"'+digest+'"';response['Cache-Control']='private, max-age=31536000, immutable'
    response['X-Content-Type-Options']='nosniff'
    response.immutable_content = True
    return response
