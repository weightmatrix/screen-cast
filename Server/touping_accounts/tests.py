from unittest.mock import patch
from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient
from .models import CastProfile
from .views import code_allowed

class ProfileTests(TestCase):
    def setUp(self):
        # Bypass unrelated encrypted profile creation; no real phone or credentials.
        self.user = get_user_model()(phone='test-digest', role='teacher', username='test')
        from django.db.models import Model
        Model.save(self.user)
        self.client = APIClient(HTTP_X_FORWARDED_PROTO="https")
        self.client.force_authenticate(self.user)

    def test_code_rules(self):
        self.assertFalse(code_allowed('111234'))
        self.assertTrue(code_allowed('121314'))
        self.assertTrue(code_allowed('111234', True))
        self.assertFalse(code_allowed('１２３４５６', True))

    @patch('touping_accounts.views.is_reserved_username', return_value=True)
    def test_reserved_and_svip(self, reserved):
        self.assertEqual(self.client.patch('/api/touping/profile/', {'nickname':'李老师','matching_code':'111234'}, format='json').status_code, 409)
        CastProfile.objects.filter(user=self.user).update(is_svip=True)
        result = self.client.patch('/api/touping/profile/', {'nickname':'李老师','matching_code':'111234'}, format='json')
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.data['membership'], 'SVIP')
        self.assertIsInstance(result.data['relay_configured'], bool)

    def test_no_privilege_escalation(self):
        self.assertEqual(self.client.patch('/api/touping/profile/', {'nickname':'特色名','matching_code':'123456','is_svip':True}, format='json').status_code,400)
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get('/api/touping/profile/').status_code,401)

    def test_relay_denies_ordinary_and_anonymous(self):
        self.assertEqual(self.client.post('/api/touping/relay/', {}, format='json').status_code,403)
        self.client.force_authenticate(None)
        self.assertEqual(self.client.post('/api/touping/relay/', {}, format='json').status_code,401)

    @patch('pathlib.Path.read_text', return_value='{"secret":"01234567890123456789012345678901","urls":["turn:49.233.174.254:3479?transport=udp"]}')
    def test_svip_receives_expiring_credentials(self, read):
        CastProfile.objects.create(user=self.user,is_svip=True)
        response = self.client.post('/api/touping/relay/', {}, format='json')
        self.assertEqual(response.status_code,200)
        import time
        self.assertGreater(int(response.data['username'].split(':')[0]),time.time())
        self.assertNotIn('secret',response.data)
