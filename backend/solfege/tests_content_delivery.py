import hashlib
from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient
from .content_delivery import manifest_data


class ContentDeliveryTests(TestCase):
    def setUp(self):
        self.client=APIClient()
        self.user=get_user_model().objects.create_user(username='content-learner')

    def test_login_required_and_manifest_exposes_no_storage_paths(self):
        url='/api/v1/content/manifest/'
        self.assertEqual(self.client.get(url).status_code,401)
        self.client.force_authenticate(self.user)
        response=self.client.get(url)
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.data['version'],1)
        self.assertNotIn('files',response.data)
        for name,asset in response.data['assets'].items():
            self.assertNotIn('path',asset)
            self.assertEqual(asset['url'],f'http://testserver/api/v1/content/assets/{asset["sha256"]}/')

    def test_catalog_and_musicxml_are_hash_verified_immutable_files(self):
        self.client.force_authenticate(self.user)
        assets=manifest_data()['assets']
        xml=next(name for name in assets if name.endswith('.xml'))
        for name in ['memory-run-v2.json','rhythm-puzzle-v3.json',xml]:
            asset=assets[name]
            response=self.client.get(f'/api/v1/content/assets/{asset["sha256"]}/',HTTP_ACCEPT=asset['content_type'])
            self.assertEqual(response.status_code,200)
            # Django's test client closes a consumed stream with its DB cleanup
            # signal temporarily disconnected. Closing it again here closes the
            # PostgreSQL connection inside TestCase's enclosing transaction.
            data=b''.join(response.streaming_content)
            self.assertTrue(response.closed)
            self.assertEqual(len(data),asset['size_bytes'])
            self.assertEqual(hashlib.sha256(data).hexdigest(),asset['sha256'])
            self.assertEqual(response['Content-Type'],asset['content_type'])
            self.assertIn('immutable',response['Cache-Control'])
            self.assertEqual(response['ETag'],'"'+asset['sha256']+'"')
        # Guard the next test's setup as well as the download itself: consuming
        # streaming responses must leave the enclosing DB transaction usable.
        self.assertTrue(get_user_model().objects.filter(pk=self.user.pk).exists())
        digest=assets[xml]['sha256']
        self.assertEqual(APIClient().get(f'/api/v1/content/assets/{digest}/').status_code,401)

    def test_unknown_assets_cannot_read_arbitrary_paths(self):
        self.client.force_authenticate(self.user)
        for digest in ['0'*64,'settings.py','not-a-sha']:
            self.assertEqual(self.client.get(f'/api/v1/content/assets/{digest}/').status_code,404)
