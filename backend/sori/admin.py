from django.contrib import admin
from .models import UserProfile, Question, QuestionVersion, Attempt, Answer, GradingJob

for model in (UserProfile, Question, QuestionVersion, Attempt, Answer, GradingJob):
    admin.site.register(model)
