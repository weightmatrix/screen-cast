import asyncio, base64, hashlib, json, os, struct, unittest, tempfile
from unittest import mock
from audit import AuditLog, AuditUnavailable
import signaling as service

class Client:
    @classmethod
    async def open(cls, port, host='127.0.0.1', path='/signal', tls=None):
        self = cls()
        self.r, self.w = await asyncio.open_connection(host, port, ssl=tls)
        self.w.write(f'GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '.encode()+base64.b64encode(os.urandom(16))+b'\r\n\r\n')
        await self.w.drain()
        response = await self.r.readuntil(b'\r\n\r\n')
        assert b'101 Switching' in response
        return self
    async def send(self, obj):
        raw = json.dumps(obj, separators=(',', ':')).encode(); mask = b'abcd'
        h = b'\x81' + (bytes([0x80 | len(raw)]) if len(raw)<126 else b'\xfe'+struct.pack('!H',len(raw)))
        self.w.write(h+mask+bytes(v^mask[i%4] for i,v in enumerate(raw))); await self.w.drain()
    async def receive(self):
        a,b = await asyncio.wait_for(self.r.readexactly(2), 2)
        size = b&127
        if size == 126: size = struct.unpack('!H',await self.r.readexactly(2))[0]
        data = await self.r.readexactly(size)
        return a&15, json.loads(data) if a&15==1 else data
    async def close(self): self.w.close(); await self.w.wait_closed()

class PairingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.audit_dir = tempfile.TemporaryDirectory()
        self.audit_path = os.path.join(self.audit_dir.name, 'connections.jsonl')
        service.AUDIT = AuditLog(self.audit_path)
        service.ROOMS.clear(); service.RATE.clear()
        self.server = await asyncio.start_server(service.connection,'127.0.0.1',0,limit=8192)
        self.port = self.server.sockets[0].getsockname()[1]
        self.clients=[]
    async def asyncTearDown(self):
        for c in self.clients: await c.close()
        self.server.close(); await self.server.wait_closed(); await asyncio.sleep(.02)
        service.AUDIT = None
        self.audit_dir.cleanup()
    async def client(self,role,key='a'*64):
        c=await Client.open(self.port); self.clients.append(c)
        await c.send({'role':role,'room':key}); return c
    async def pair(self):
        a=await self.client('sender'); self.assertEqual((await a.receive())[1]['type'],'waiting')
        b=await self.client('receiver'); self.assertEqual((await a.receive())[1]['type'],'peer'); return a,b
    async def test_pairing_forward_and_both_connected_close(self):
        a,b=await self.pair()
        msg={'type':'offer','sdp':'v=0\r\nexample'}; await a.send(msg); self.assertEqual((await b.receive())[1],msg)
        await a.send({'type':'done'})
        await b.send({'type':'answer','sdp':'v=0\r\nanswer'})
        self.assertEqual((await a.receive())[1]['type'],'answer')
        await b.send({'type':'done'})
        self.assertEqual((await a.receive())[0],8); self.assertEqual((await b.receive())[0],8)
    async def test_room_reusable_after_successful_pair(self):
        a,b=await self.pair()
        await a.send({'type':'done'}); await b.send({'type':'done'})
        self.assertEqual((await a.receive())[0],8); self.assertEqual((await b.receive())[0],8)
        await asyncio.sleep(.02)
        c,d=await self.pair()
        offer={'type':'offer','sdp':'v=0\r\nsecond pair'}
        await c.send(offer); self.assertEqual((await d.receive())[1],offer)
    async def test_no_media_messages(self):
        a,b=await self.pair(); await a.send({'type':'video','data':'forbidden'})
        self.assertEqual((await a.receive())[0],8)
    async def test_receiver_page_and_script_have_private_static_headers(self):
        for path, mime in [('/', b'text/html'), ('/receiver.js', b'application/javascript'),
                           ('/privacy.html', b'text/html'), ('/support.html', b'text/html')]:
            reader, writer = await asyncio.open_connection('127.0.0.1', self.port)
            writer.write(f'GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode()); await writer.drain()
            response = await reader.read()
            writer.close(); await writer.wait_closed()
            self.assertIn(b'200 OK', response); self.assertIn(mime, response)
            self.assertIn(b'Referrer-Policy: no-referrer', response)
            self.assertIn(b'Cache-Control: no-store', response)
            self.assertNotIn(b'Access-Control-Allow-Origin: *', response)
        self.assertFalse(service.ROOMS)
    async def test_browser_receiver_metadata_joins_native_sender(self):
        sender = await self.client('sender'); await sender.receive()
        receiver = await Client.open(self.port); self.clients.append(receiver)
        await receiver.send({'role':'receiver','room':'a'*64,'device':{'installation_id':'c'*32,
            'platform':'browser','model':'Browser','os_version':'0','app_version':'1.4','app_build':'51-web'}})
        self.assertEqual((await sender.receive())[1], {'type':'peer'})
        with open(self.audit_path) as stream: records = [json.loads(line) for line in stream]
        self.assertTrue(any(row.get('device', {}).get('platform') == 'browser' for row in records if row.get('device')))
    async def test_bounded_device_metadata_is_audited_not_forwarded(self):
        device = {'installation_id': 'b' * 32, 'platform': 'iPadOS', 'model': 'iPad11,1',
                  'os_version': '26.0.1', 'app_version': '1.4', 'app_build': '50'}
        a = await Client.open(self.port); self.clients.append(a)
        await a.send({'role': 'sender', 'room': 'a' * 64, 'device': device})
        self.assertEqual((await a.receive())[1], {'type': 'waiting'})
        with open(self.audit_path) as stream: events = [json.loads(line) for line in stream]
        record = next(event for event in events if event['event'] == 'device_reported')
        self.assertEqual(record['device'], device)
        self.assertEqual(record['evidence'], 'client_report_only')
        self.assertFalse(record['mac_address_available'])
        self.assertNotIn('room', record)
        b = await self.client('receiver'); self.assertEqual((await a.receive())[1], {'type': 'peer'})
    async def test_rejects_device_fields_outside_allowlist(self):
        for value in [{'mac': '00:11:22:33:44:55'}, 'invalid', {'installation_id': 'a' * 5000}]:
            a = await Client.open(self.port); self.clients.append(a)
            await a.send({'role': 'sender', 'room': 'a' * 64, 'device': value})
            self.assertEqual((await a.receive())[0], 8)
        self.assertFalse(service.ROOMS)
    async def test_direct_report_is_bounded_metadata_only_without_room(self):
        device = {'installation_id': 'b' * 32, 'platform': 'macOS', 'model': 'Mac16,10',
                  'os_version': '26.0.1', 'app_version': '1.4', 'app_build': '50'}
        packet = {'role': 'audit', 'route': 'internet_ip', 'session_id': 'c' * 32,
                  'peer_role': 'sender', 'event': 'connected', 'device': device}
        a = await Client.open(self.port, path='/audit'); self.clients.append(a); await a.send(packet)
        self.assertEqual((await a.receive())[1], {'type': 'audit_recorded'})
        self.assertFalse(service.ROOMS)
        with open(self.audit_path) as stream: records = [json.loads(line) for line in stream]
        record = next(value for value in records if value['event'] == 'direct_connection_reported')
        self.assertEqual(record['session_id'], 'c' * 32)
        self.assertEqual(record['ip'], '127.0.0.1')
        b = await Client.open(self.port, path='/audit'); self.clients.append(b)
        await b.send({**packet, 'sdp': 'forbidden'})
        self.assertEqual((await b.receive())[0], 8)
        c = await Client.open(self.port); self.clients.append(c); await c.send(packet)
        self.assertEqual((await c.receive())[0], 8)
        d = await Client.open(self.port, path='/audit'); self.clients.append(d)
        await d.send({'role': 'sender', 'room': 'a' * 64})
        self.assertEqual((await d.receive())[0], 8)
    async def test_room_shared_byte_budget(self):
        a,b=await self.pair(); room=service.ROOMS['a'*64]; room['bytes']=65530
        await a.send({'type':'candidate','candidate':'candidate:x','mid':'0','line':0})
        self.assertEqual((await a.receive())[0],8)
    async def test_code_not_found(self):
        a=await self.client('receiver'); self.assertEqual((await a.receive())[1]['type'],'error')
    async def test_duplicate_sender_does_not_replace_room(self):
        a=await self.client('sender'); await a.receive()
        b=await self.client('sender'); self.assertEqual((await b.receive())[1]['type'],'error')
        self.assertIsNotNone(service.ROOMS.get('a'*64))
    async def test_suggestion_skips_occupied_and_excluded_codes(self):
        occupied='12345678'; excluded='87654321'; expected='23456789'
        digest=lambda value: hashlib.sha256(value.encode()).hexdigest()
        sender=await self.client('sender', digest(occupied)); await sender.receive()
        suggestion=await Client.open(self.port); self.clients.append(suggestion)
        with mock.patch.object(service.secrets,'randbelow',side_effect=[int(occupied),int(excluded),int(expected)]):
            await suggestion.send({'role':'suggest','exclude':[digest(excluded)]})
            reply=(await suggestion.receive())[1]
        self.assertEqual(reply,{'type':'suggestion','code':expected})
        self.assertNotIn(digest(expected),service.ROOMS, 'A suggestion must not replace/register a sender')
        self.assertIn(digest(occupied),service.ROOMS)
        with open(self.audit_path) as stream: raw=stream.read()
        self.assertIn('code_suggested',raw)
        self.assertNotIn('"code":',raw); self.assertNotIn(digest(excluded),raw)
    async def test_suggestion_race_still_rejects_second_sender(self):
        key=hashlib.sha256(b'23456789').hexdigest()
        first=await self.client('sender',key); await first.receive()
        original=service.ROOMS[key]
        second=await self.client('sender',key)
        response=(await second.receive())[1]
        self.assertEqual(response['code'],'code_in_use')
        self.assertIs(service.ROOMS[key],original)
        self.assertEqual(len(service.ROOMS),1)
    async def test_server_full_is_not_reported_as_code_collision(self):
        service.ROOMS.update({f'{index:064x}':{} for index in range(32)})
        sender=await self.client('sender','f'*64)
        response=(await sender.receive())[1]
        self.assertEqual(response['code'],'server_busy')
        self.assertNotIn('匹配码已使用',response['message'])
    async def test_suggestion_rejects_unbounded_exclusion_list(self):
        suggestion=await Client.open(self.port); self.clients.append(suggestion)
        await suggestion.send({'role':'suggest','exclude':['a'*64]*33})
        self.assertEqual((await suggestion.receive())[0],8)
    async def test_suggestion_generation_has_bounded_attempts(self):
        sender=await self.client('sender',hashlib.sha256(b'12345678').hexdigest()); await sender.receive()
        suggestion=await Client.open(self.port); self.clients.append(suggestion)
        with mock.patch.object(service.secrets,'randbelow',return_value=12345678) as generate:
            await suggestion.send({'role':'suggest','exclude':[]})
            response=(await suggestion.receive())[1]
        self.assertEqual(response['type'],'error'); self.assertEqual(generate.call_count,128)
    async def test_connection_audit_correlates_without_payloads(self):
        a,b=await self.pair()
        await a.send({'type':'offer','sdp':'v=0\r\nPRIVATE-SDP'})
        await b.receive()
        await a.send({'type':'done'}); await b.send({'type':'done'})
        await a.receive(); await b.receive(); await asyncio.sleep(.02)
        with open(self.audit_path) as stream: raw=stream.read()
        rows=[json.loads(line) for line in raw.splitlines()]
        joined=next(row for row in rows if row['event']=='receiver_joined')
        waiting=next(row for row in rows if row['event']=='sender_waiting')
        completed=next(row for row in rows if row['event']=='pairing_completed')
        self.assertEqual(joined['pair_id'], waiting['pair_id'])
        self.assertEqual(completed['pair_id'], joined['pair_id'])
        self.assertEqual(completed['sender_connection_id'], waiting['connection_id'])
        self.assertFalse(completed['media_end_observed'])
        self.assertEqual(joined['ip'], '127.0.0.1')
        self.assertNotIn('PRIVATE-SDP', raw); self.assertNotIn('a'*64, raw)
        self.assertEqual(len([r for r in rows if r['event']=='peer_reported_connected']), 2)
        self.assertTrue(any(r['event']=='signaling_closed' for r in rows))
    async def test_audit_failure_refuses_handshake(self):
        with mock.patch.object(service.AUDIT, 'record', side_effect=AuditUnavailable()):
            reader,writer=await asyncio.open_connection('127.0.0.1',self.port)
            writer.write(b'GET /signal HTTP/1.1\r\nHost: localhost\r\n\r\n'); await writer.drain()
            self.assertIn(b'503', await reader.read())
            writer.close(); await writer.wait_closed()
            self.assertEqual(service.ACTIVE, 0)
    async def test_rejection_logged(self):
        a=await self.client('receiver'); await a.receive(); await asyncio.sleep(.02)
        with open(self.audit_path) as stream: rows=[json.loads(line) for line in stream]
        self.assertTrue(any(r['event']=='pairing_rejected' and r['reason']=='sender_not_found_or_busy' for r in rows))
    async def test_stun_binding_only_and_rate_limit(self):
        class Transport:
            def __init__(self): self.sent=[]
            def sendto(self,data,addr): self.sent.append((data,addr))
        stun=service.STUN(); transport=Transport(); stun.connection_made(transport)
        request=struct.pack('!HHI',1,0,0x2112A442)+b'123456789012'
        stun.datagram_received(request,('203.0.113.4',54321))
        answer=transport.sent[0][0]; self.assertEqual(len(answer),32); self.assertEqual(answer[8:20],request[8:20])
        self.assertEqual(struct.unpack('!H',answer[26:28])[0]^0x2112,54321)
        stun.datagram_received(b'x'*1000,('203.0.113.4',54321)); self.assertEqual(len(transport.sent),1)
        turn=struct.pack('!HHI',3,0,0x2112A442)+b'123456789012'
        stun.datagram_received(turn,('203.0.113.4',54321)); self.assertEqual(len(transport.sent),1)
        for _ in range(100): stun.datagram_received(request,('203.0.113.4',54321))
        self.assertEqual(len(transport.sent),60)
class AuditTests(unittest.TestCase):
    def test_rotation_permissions_and_retention(self):
        with tempfile.TemporaryDirectory() as directory:
            path=os.path.join(directory,'connections.jsonl')
            log=AuditLog(path, max_bytes=512, backups=2, retention_days=1)
            for _ in range(12): log.record('test', ip='203.0.113.4')
            self.assertLessEqual(len(os.listdir(directory)),3)
            self.assertEqual(os.stat(path).st_mode & 0o777,0o600)
            for name in os.listdir(directory):
                with open(os.path.join(directory,name)) as stream:
                    for line in stream: self.assertEqual(json.loads(line)['event'],'test')
            old=path+'.2'; os.utime(old,(1,1)); log.last_cleanup=0
            log.max_bytes=1024*1024
            log.record('after_cleanup')
            self.assertFalse(os.path.exists(old))
    def test_proxy_ip_cannot_inject_logs(self):
        with mock.patch.dict(os.environ,{'TRUST_PROXY':'1'}):
            self.assertEqual(service.source_ip('172.18.0.2',{'x-real-ip':'203.0.113.7'}),'203.0.113.7')
            self.assertEqual(service.source_ip('172.18.0.2',{'x-real-ip':'evil\nforged'}),'172.18.0.2')
            self.assertEqual(service.source_ip('8.8.8.8',{'x-real-ip':'203.0.113.7'}),'8.8.8.8')

if __name__ == '__main__': unittest.main()
