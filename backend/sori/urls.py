from django.urls import path
from . import views
urlpatterns = [
    path("me/", views.me),
    path("questions/", views.questions),
    path("questions/<uuid:question_id>/", views.question_detail),
    path("questions/<uuid:question_id>/versions/<int:version>/scores/<str:kind>/", views.score_asset),
    path("attempts/", views.create_attempt),
    path("attempts/<uuid:attempt_id>/", views.attempt_detail),
    path("attempts/<uuid:attempt_id>/start/", views.start_attempt),
    path("attempts/<uuid:attempt_id>/answers/", views.upload_answer),
    path("attempts/<uuid:attempt_id>/answers/<uuid:answer_id>/image/", views.answer_image),
    path("attempts/<uuid:attempt_id>/submit/", views.submit_attempt),
    path("attempts/<uuid:attempt_id>/result/", views.result),
    path("attempts/<uuid:attempt_id>/grading-retries/", views.retry_grading),
]
