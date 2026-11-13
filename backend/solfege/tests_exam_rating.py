import io
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest import skipUnless
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.db import transaction, connection, close_old_connections
from django.test import TestCase, TransactionTestCase
from rest_framework.test import APIClient
from .exam_rating import apply_rating, change_json, offer_for
from .grading import finish_job
from .models import Answer, Attempt, ExamRatingChange, ExamRatingState, GradingJob, Question, QuestionVersion
from .question_pools import ids
from .recommendation import current_versions
from .views import new_job


class ExamRatingTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        call_command("seed_questions", stdout=io.StringIO())
        cls.user=get_user_model().objects.create_user(username="rated-learner")

    def setUp(self):
        self.client=APIClient(); self.client.force_authenticate(self.user)

    def create(self, question=None, mode="exam", key=None):
        if question is None:
            offer=offer_for(self.user)
            q=next(c for c in offer['choices'] if c['category']=='matched' and c['question_id'])
            question=current_versions('exam').get(question_id=q['question_id'])
        body={'question_id':str(question.question_id),'question_version':question.version,'mode':mode}
        return self.client.post('/api/v1/attempts/',body,format='json',HTTP_IDEMPOTENCY_KEY=key or str(uuid.uuid4()))

    def job(self):
        response=self.create(); self.assertEqual(response.status_code,201,response.data)
        attempt=Attempt.objects.get(id=response.data['id'])
        answer=Answer.objects.create(attempt=attempt,client_answer_id=uuid.uuid4(),revision=1,
            image='rating-test.png',sheet_layout_id=attempt.question_snapshot['sheet_layout']['id'],sha256='0'*64,size_bytes=0)
        job=new_job(attempt,answer); job.status='processing'; job.save(update_fields=['status'])
        attempt.status='submitted'; attempt.submitted_answer=answer; attempt.save()
        return attempt,job

    def test_partition_and_cached_three_choices_are_private_to_user(self):
        page=self.client.get('/api/v1/questions/').data
        self.assertEqual(page['count'],1550)
        self.assertTrue({q['id'] for q in page['results']} <= set(ids('practice')))
        a=self.client.get('/api/v1/exam/recommendations/'); b=self.client.get('/api/v1/exam/recommendations/')
        self.assertEqual(a.status_code,200); self.assertEqual(a.data,b.data)
        self.assertEqual(a.data['rating']['value'],7)
        self.assertEqual(len({c['question_id'] for c in a.data['choices']}),3)
        self.assertTrue({c['question_id'] for c in a.data['choices']} <= set(ids('exam')))
        other=get_user_model().objects.create_user(username='other-rated-learner')
        self.assertNotEqual(offer_for(other)['id'],a.data['id'])
        self.assertEqual(APIClient().get('/api/v1/exam/recommendations/').status_code,401)

    def test_membership_reservation_replay_and_resume(self):
        wrong=current_versions('practice').first()
        self.assertEqual(self.create(wrong).data['error']['code'],'QUESTION_NOT_IN_EXAM_POOL')
        q=current_versions('exam').first()
        self.assertEqual(self.create(q,mode='practice').data['error']['code'],'QUESTION_NOT_IN_PRACTICE_POOL')
        key=str(uuid.uuid4()); a=self.create(q,key=key); b=self.create(q,key=key)
        self.assertEqual(a.status_code,201,a.data); self.assertEqual(a.data,b.data)
        self.assertEqual(self.create(q).data['error']['code'],'EXAM_QUESTION_ALREADY_SEEN')
        self.assertEqual(self.client.get(f"/api/v1/attempts/{a.data['id']}/").status_code,200)
        offer=offer_for(self.user)
        self.assertEqual(offer['active_attempt_id'],a.data['id'])
        self.assertEqual(offer['choices'],[])

    def test_selected_exam_is_fixed_before_start_and_blocks_other_questions(self):
        first=self.create(); self.assertEqual(first.status_code,201,first.data)
        a=Attempt.objects.get(id=first.data['id'])
        self.assertEqual(a.status,'ready'); self.assertIsNone(a.started_at)
        other=current_versions('exam').exclude(question_id=a.question_version.question_id).first()
        rejected=self.create(other)
        self.assertEqual(rejected.status_code,409)
        self.assertEqual(rejected.data['error']['code'],'EXAM_ALREADY_ACTIVE')
        # Another request/device gets the same selected exam, without new choices.
        for _ in range(2):
            offer=self.client.get('/api/v1/exam/recommendations/').data
            self.assertEqual(offer['active_attempt_id'],str(a.id)); self.assertEqual(offer['choices'],[])
        self.assertEqual(Attempt.objects.filter(user=self.user).count(),1)

    def test_started_exam_does_not_reset_its_clock_when_restored(self):
        response=self.create(); path=f"/api/v1/attempts/{response.data['id']}/"
        started=self.client.post(path+'start/').data
        self.client.get('/api/v1/exam/recommendations/')
        repeated=self.client.post(path+'start/').data
        self.assertEqual(started['started_at'],repeated['started_at'])
        self.assertEqual(started['recommended_end_at'],repeated['recommended_end_at'])

    def test_queued_processing_and_failed_grading_block_until_completed(self):
        attempt,job=self.job()
        other=current_versions('exam').exclude(question_id=attempt.question_version.question_id).first()
        for status in ['queued','processing','failed']:
            job.status=status; job.save(update_fields=['status'])
            offer=offer_for(self.user)
            self.assertEqual(offer['active_attempt_id'],str(attempt.id)); self.assertEqual(offer['choices'],[])
            self.assertEqual(self.create(other).data['error']['code'],'EXAM_ALREADY_ACTIVE')
        job.status='processing'; job.save(update_fields=['status'])
        self.assertEqual(finish_job(job,{'status':'completed','score':0}),1)
        offer=offer_for(self.user)
        self.assertNotIn('active_attempt_id',offer)
        self.assertEqual(offer['rating']['completed'],1)
        self.assertEqual(offer['rating']['value'],change_json(attempt.id)['after'])
        self.assertNotIn(str(attempt.question_version.question_id),{c['question_id'] for c in offer['choices']})
        self.assertEqual(self.create(other).status_code,201)

    def test_practice_and_other_users_are_not_blocked_by_an_active_exam(self):
        response=self.create(); self.assertEqual(response.status_code,201,response.data)
        self.assertEqual(self.create(current_versions('practice').first(),mode='practice').status_code,201)
        other=get_user_model().objects.create_user(username='independent-exam')
        self.assertNotIn('active_attempt_id',offer_for(other))

    def test_success_zero_and_duplicate_completion_count_once(self):
        attempt,job=self.job()
        before=ExamRatingState.objects.get(user=self.user).rating
        self.assertEqual(finish_job(job,{'status':'completed','score':0}),1)
        state=ExamRatingState.objects.get(user=self.user)
        self.assertLess(state.rating,before); self.assertEqual(state.completed,1)
        change=change_json(attempt.id); self.assertEqual(change['grade'],0)
        self.assertEqual(finish_job(job,{'status':'completed','score':100}),0)
        with transaction.atomic():
            held=Attempt.objects.select_for_update().get(id=attempt.id)
            self.assertEqual(apply_rating(held,job).id,ExamRatingChange.objects.get(attempt=attempt).id)
        state.refresh_from_db(); self.assertEqual(state.completed,1); self.assertEqual(change_json(attempt.id),change)
        for _ in range(3):
            self.assertEqual(self.client.get(f'/api/v1/attempts/{attempt.id}/result/').data['rating_change'],change)
        state.refresh_from_db(); self.assertEqual(state.completed,1)

    def test_failure_legacy_and_practice_never_change_rating(self):
        attempt,job=self.job()
        self.assertEqual(finish_job(job,{'status':'failed'}),1)
        self.assertFalse(ExamRatingChange.objects.exists())
        self.assertEqual(ExamRatingState.objects.get(user=self.user).completed,0)
        for field,value in [('exam_rating_snapshot',None),('mode','practice')]:
            setattr(attempt,field,value); attempt.save()
            job.status='processing'; job.save(update_fields=['status'])
            self.assertEqual(finish_job(job,{'status':'completed','score':100}),1)
            self.assertFalse(ExamRatingChange.objects.exists())

    def test_late_job_cannot_overwrite_and_uses_frozen_difficulty(self):
        attempt,old=self.job()
        new=new_job(attempt,old.answer); new.status='processing'; new.save(update_fields=['status'])
        attempt.save(update_fields=['current_job'])
        self.assertEqual(finish_job(old,{'status':'completed','score':100}),0)
        frozen=attempt.exam_rating_snapshot['difficulty_score']
        metadata=attempt.question_version.metadata.copy(); metadata['difficulty_score']=999
        attempt.question_version.metadata=metadata; attempt.question_version.save(update_fields=['metadata'])
        self.assertEqual(finish_job(new,{'status':'completed','score':95}),1)
        self.assertEqual(change_json(attempt.id)['difficulty'],frozen)
        self.assertEqual(ExamRatingState.objects.get(user=self.user).completed,1)

    def test_delete_account_removes_rating_and_offers(self):
        from .accounts import delete_account
        attempt,job=self.job(); finish_job(job,{'status':'completed','score':90})
        self.assertTrue(delete_account(self.user))
        self.assertFalse(ExamRatingState.objects.exists())
        self.assertFalse(ExamRatingChange.objects.exists())


@skipUnless(connection.vendor=='postgresql','Real row-lock checks require PostgreSQL')
class RatingConcurrencyTests(TransactionTestCase):
    def setUp(self):
        self.user=get_user_model().objects.create_user(username='concurrent-rating')
        ExamRatingState.objects.create(user=self.user)

    def job(self):
        q=Question.objects.create()
        v=QuestionVersion.objects.create(question=q,version=1,metadata={},main_path='',scale_path='')
        a=Attempt.objects.create(user=self.user,question_version=v,question_snapshot={},playback_plan={},
            exam_rating_snapshot={'model_version':'exam-rating-1','difficulty_score':7,
                                  'difficulty_version':'practice-difficulty-2','pool_version':'question-pools-1'})
        answer=Answer.objects.create(attempt=a,client_answer_id=uuid.uuid4(),revision=1,image='unused.png',
            sheet_layout_id='unused',sha256='0'*64,size_bytes=0)
        job=GradingJob.objects.create(attempt=a,answer=answer,status='processing',grading_version='ai-melodic-v2',
            model='fixture',reasoning_effort='none',prompt_version='fixture',prompt_text='fixture')
        a.current_job=job; a.save(update_fields=['current_job']); return job

    def complete(self, job, grade):
        close_old_connections()
        try:return finish_job(job,{'status':'completed','score':grade})
        finally:connection.close()

    def test_two_workers_on_one_job_apply_once(self):
        job=self.job()
        with ThreadPoolExecutor(max_workers=2) as workers:
            results=list(workers.map(lambda _:self.complete(job,90),range(2)))
        self.assertEqual(sorted(results),[0,1])
        self.assertEqual(ExamRatingState.objects.get(user=self.user).completed,1)
        self.assertEqual(ExamRatingChange.objects.count(),1)

    def test_two_distinct_results_serialize_one_users_rating(self):
        jobs=[self.job(),self.job()]
        with ThreadPoolExecutor(max_workers=2) as workers:
            results=list(workers.map(lambda pair:self.complete(*pair),zip(jobs,[60,95])))
        self.assertEqual(results,[1,1])
        state=ExamRatingState.objects.get(user=self.user)
        self.assertEqual(state.completed,2)
        changes=list(ExamRatingChange.objects.order_by('completed_before'))
        self.assertEqual([c.completed_before for c in changes],[0,1])
        self.assertAlmostEqual(changes[0].after,changes[1].before)
        self.assertAlmostEqual(state.rating,changes[1].after)
