import unittest
from unittest.mock import patch, MagicMock
from account_identity import sender_identity

class IdentityTests(unittest.IsolatedAsyncioTestCase):
    async def test_missing_or_injected_token(self):
        for token in (None, '', 'x\r\nAuthorization: other'):
            with self.assertRaises(ValueError): await sender_identity(token)

    async def test_verified_identity_only(self):
        reply = MagicMock()
        reply.__enter__.return_value.read.return_value = b'{"id":"verified-user","phone":"13000000000"}'
        with patch('account_identity.urllib.request.urlopen', return_value=reply) as request:
            result = await sender_identity('a' * 30)
            self.assertEqual(result, {'account_id':'verified-user','phone':'13000000000'})
            self.assertEqual(request.call_args[0][0].get_header('Authorization'), 'Bearer '+ 'a'*30)

    async def test_masked_phone_rejected(self):
        reply = MagicMock()
        reply.__enter__.return_value.read.return_value = b'{"id":"user","phone":"130****0000"}'
        with patch('account_identity.urllib.request.urlopen', return_value=reply):
            with self.assertRaises(ValueError): await sender_identity('a' * 30)
