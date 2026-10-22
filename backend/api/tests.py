from django.test import SimpleTestCase
from django.urls import reverse


class HealthAPITests(SimpleTestCase):
    def test_anonymous_client_receives_documented_json_without_database(self):
        response = self.client.get(reverse("health"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Content-Type"], "application/json")
        self.assertEqual(response.json(), {"status": "ok"})

    def test_health_does_not_accept_writes(self):
        response = self.client.post(reverse("health"), {}, content_type="application/json")
        self.assertEqual(response.status_code, 405)
