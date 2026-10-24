from django.contrib import admin
from django.urls import include, path
from sori.views import sheet_asset

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/", include("api.urls")),
    path("api/v1/", include("sori.urls")),
    path("assets/sheets/<str:layout_id>.png", sheet_asset),
]
