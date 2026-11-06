import json
import unittest
import urllib.parse
from unittest import mock
import baidu_oauth as oauth

FIXTURE = {'client_id': 'fixture-public-client', 'client_secret': 'fixture-private-secret'}

class OAuthTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        oauth.SESSIONS.clear(); oauth.BUSY = 0
        self.config = mock.patch.object(oauth, 'configuration', return_value=FIXTURE)
        self.config.start(); self.addCleanup(self.config.stop)

    async def start(self):
        code, _, body = await oauth.handle('POST', '/baidu/start', {'qr': True})
        self.assertEqual(code, 200)
        flow = json.loads(body); self.assertNotIn(FIXTURE['client_secret'], body.decode())
        parsed = urllib.parse.parse_qs(urllib.parse.urlsplit(flow['authorize_url']).query)
        self.assertEqual(parsed['redirect_uri'], [oauth.CALLBACK]); self.assertEqual(parsed['display'], ['tv'])
        return flow

    async def test_bound_state_claim_and_single_use(self):
        flow = await self.start()
        self.assertEqual((await oauth.handle('GET', '/baidu/callback?code=fixture-code&state=missing', None))[0], 400)
        code, headers, _ = await oauth.handle('GET', '/baidu/callback?' + urllib.parse.urlencode({'state': flow['state'], 'code': 'fixture-code'}), None)
        self.assertEqual(code, 302); self.assertTrue(headers['Location'].startswith('touping-baidu://oauth?state=')); self.assertNotIn('fixture-code', headers['Location'])
        self.assertEqual((await oauth.handle('POST', '/baidu/complete', {'state': flow['state'], 'claim': 'wrong'}))[0], 400)
        def exchange(parameters, config):
            self.assertEqual(parameters['code'], 'fixture-code'); self.assertEqual(config, FIXTURE)
            return {'access_token': 'fixture-access-token', 'refresh_token': 'fixture-refresh-token', 'expires_in': 3600}
        payload = {'state': flow['state'], 'claim': flow['claim']}
        code, headers, body = await oauth.handle('POST', '/baidu/complete', payload, exchange)
        self.assertEqual(code, 200); self.assertEqual(headers['Cache-Control'], 'no-store'); self.assertNotIn(FIXTURE['client_secret'], body.decode())
        self.assertEqual((await oauth.handle('POST', '/baidu/complete', payload, exchange))[0], 400)

    async def test_expiry_capacity_and_provider_error_redaction(self):
        flow = await self.start(); oauth.SESSIONS[flow['state']]['expires'] = 0
        self.assertEqual((await oauth.handle('POST', '/baidu/complete', {'state': flow['state'], 'claim': flow['claim']}))[0], 400)
        for _ in range(64): await self.start()
        self.assertEqual((await oauth.handle('POST', '/baidu/start', {}))[0], 429)
        def failed(*args): raise RuntimeError(FIXTURE['client_secret'])
        code, _, body = await oauth.handle('POST', '/baidu/refresh', {'refresh_token': 'fixture-refresh'}, failed)
        self.assertEqual(code, 502); self.assertNotIn(FIXTURE['client_secret'], body.decode()); self.assertEqual(oauth.BUSY, 0)
        self.assertEqual((await oauth.handle('POST', '/baidu/refresh', {'refresh_token': 'x'*5000}))[0], 400)
        self.assertEqual((await oauth.handle('GET', '/baidu/refresh', None))[0], 405)

    async def test_disabled_landing_and_no_media_endpoint(self):
        with mock.patch.object(oauth, 'configuration', return_value=None):
            self.assertEqual((await oauth.handle('GET', '/baidu/callback', None))[0], 200)
            code, _, body = await oauth.handle('GET', '/baidu/status', None)
            self.assertEqual(code, 200); self.assertFalse(json.loads(body)['configured'])
            self.assertEqual((await oauth.handle('POST', '/baidu/start', {}))[0], 503)
        self.assertEqual((await oauth.handle('POST', '/baidu/upload', {'media': 'rejected'}))[0], 404)

    async def test_http_post_and_body_bounds(self):
        import asyncio
        import tempfile
        import signaling
        from audit import AuditLog
        with tempfile.TemporaryDirectory() as folder:
            previous = signaling.AUDIT; signaling.AUDIT = AuditLog(folder + '/audit.jsonl')
            server = await asyncio.start_server(signaling.connection, '127.0.0.1', 0, limit=8192)
            try:
                port = server.sockets[0].getsockname()[1]
                for length, expected in [(11, b'200 OK'), (8193, b'400 Bad Request')]:
                    reader, writer = await asyncio.open_connection('127.0.0.1', port)
                    writer.write(f'POST /baidu/start HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: {length}\r\n\r\n'.encode())
                    if length == 11: writer.write(b'{"qr":true}')
                    await writer.drain(); reply = await reader.read()
                    self.assertIn(expected, reply.split(b'\r\n')[0]); self.assertNotIn(FIXTURE['client_secret'].encode(), reply)
                    writer.close(); await writer.wait_closed()
            finally:
                server.close(); await server.wait_closed(); signaling.AUDIT = previous
