from rest_framework.renderers import BaseRenderer, JSONRenderer

class AssetRenderer(BaseRenderer):
    """Negotiation for a FileResponse; errors remain JSON even for binary Accept headers."""
    charset = None
    render_style = "binary"
    def render(self, data, accepted_media_type=None, renderer_context=None):
        if renderer_context:
            renderer_context["response"]["Content-Type"] = "application/json"
        return JSONRenderer().render(data, renderer_context=renderer_context)

class PNGRenderer(AssetRenderer):
    media_type = "image/png"
    format = "png"

class MXLRenderer(AssetRenderer):
    media_type = "application/vnd.recordare.musicxml"
    format = "mxl"
