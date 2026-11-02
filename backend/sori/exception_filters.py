"""Keep authentication credentials out of Django exception reports."""

from django.views.debug import SafeExceptionReporterFilter


class AuthenticationExceptionReporterFilter(SafeExceptionReporterFilter):
    def is_authentication_request(self, request):
        return request is not None and request.path.startswith("/api/v1/auth/")

    def is_active(self, request):
        return self.is_authentication_request(request) or super().is_active(request)

    def get_traceback_frame_variables(self, request, tb_frame):
        if self.is_authentication_request(request):
            # Credentials also live in raw middleware bodies, parsed JSON,
            # nested objects and caller frames, not just a password variable.
            return [(name, self.cleansed_substitute) for name in tb_frame.f_locals]
        return super().get_traceback_frame_variables(request, tb_frame)

    def get_post_parameters(self, request):
        if self.is_authentication_request(request):
            return {name: self.cleansed_substitute for name in request.POST}
        return super().get_post_parameters(request)
