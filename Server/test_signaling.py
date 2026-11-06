import asyncio, base64, hashlib, hmac, json, os, struct, unittest, tempfile
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
    # Public synthetic fixture, never a deployment password.
    verifier = hashlib.sha256(b'touping-auth-v2:61328407:Fixture-only-71').hexdigest()

    async def asyncSetUp(self):
        self.audit_dir = tempfile.TemporaryDirectory()
        self.audit_path = os.path.join(self.audit_dir.name, 'connections.jsonl')
        service.AUDIT = AuditLog(self.audit_path)
        service.ROOMS.clear(); service.RATE.clear()
        self.server = await asyncio.start_server(service.connection,'127.0.0.1',0,limit=8192)
        self.port = self.server.sockets[0].getsockname()[1]
        self.clients=[]

    async def asyncTearDown(self):
        for client in reversed(self.clients): await client.close()
        self.server.close(); await self.server.wait_closed(); await asyncio.sleep(.03)
        service.AUDIT = None; self.audit_dir.cleanup()

    async def client(self, role, key='a'*64, **extra):
        client = await Client.open(self.port); self.clients.append(client)
        hello = {'role':role,'room':key,'protocol':2}
        if role == 'sender': hello['verifier'] = self.verifier
        await client.send({**hello, **extra})
        return client

    async def apply(self, sender, key='a'*64, text='Synthetic request', valid=True, nickname=None):
        receiver = await self.client('receiver',key)
        challenge = (await receiver.receive())[1]
        self.assertEqual(challenge['type'], 'challenge')
        proof = hmac.new(self.verifier.encode(),challenge['nonce'].encode(),hashlib.sha256).hexdigest()
        packet={'type':'apply','proof':proof if valid else '0'*64,'application':text}
        if nickname is not None: packet['nickname']=nickname
        await receiver.send(packet)
        return receiver

    async def pair(self):
        a = await self.client('sender'); self.assertEqual((await a.receive())[1]['type'],'waiting')
        b = await self.apply(a)
        self.assertEqual((await b.receive())[1]['type'],'waiting_approval')
        request = (await a.receive())[1]
        self.assertEqual(request['type'],'request')
        return a,b,request['id']

    async def approve(self,a,b,identity):
        await a.send({'type':'approve','id':identity})
        self.assertEqual((await a.receive())[1],{'type':'approved','id':identity})
        self.assertEqual((await b.receive())[1],{'type':'approved','session_id':identity})

    async def test_nickname_is_bounded_forwarded_but_not_logged(self):
        a=await self.client('sender'); await a.receive()
        b=await self.apply(a,nickname='PRIVATE_NICKNAME_FIXTURE'); await b.receive()
        request=(await a.receive())[1]
        self.assertEqual(request['nickname'],'PRIVATE_NICKNAME_FIXTURE')
        with open(self.audit_path) as stream: self.assertNotIn('PRIVATE_NICKNAME_FIXTURE',stream.read())
        for name in ['x'*33,'bad\x00name',42]:
            bad=await self.apply(a,nickname=name)
            self.assertEqual((await bad.receive())[1]['type'],'error')
        legacy=await self.apply(a); await legacy.receive()
        self.assertEqual((await a.receive())[1]['nickname'],'访客')

    async def test_password_and_application_required_before_sender_notification(self):
        a=await self.client('sender'); await a.receive()
        for valid,text in [(False,'valid'),(True,''),(True,'x'*201),(True,'bad\x00text')]:
            b=await self.apply(a,text=text,valid=valid)
            self.assertEqual((await b.receive())[1]['type'],'error')
        with self.assertRaises(asyncio.TimeoutError): await asyncio.wait_for(a.receive(),.05)
        self.assertEqual(len(service.ROOMS['a'*64]['receivers']),0)

    async def test_request_contains_observed_ip_and_text_but_audit_does_not_contain_secrets(self):
        a=await self.client('sender'); await a.receive()
        text='PRIVATE_APPLICATION_71_DO_NOT_LOG'
        b=await self.apply(a,text=text); await b.receive()
        request=(await a.receive())[1]
        self.assertEqual(request['application'],text); self.assertEqual(request['ip'],'127.0.0.1')
        with open(self.audit_path) as stream: body=stream.read()
        for secret in [text, self.verifier, 'Fixture-only-71']: self.assertNotIn(secret,body)
        self.assertIn('application_length',body)

    async def test_many_applicants_are_independent_of_media_limit(self):
        a=await self.client('sender'); await a.receive()
        requests=[]
        for _ in range(12):
            b=await self.apply(a); await b.receive(); requests.append(((await a.receive())[1]['id'],b))
        self.assertEqual(len(service.ROOMS['a'*64]['receivers']),12)
        await self.approve(a,requests[0][1],requests[0][0])
        await self.approve(a,requests[1][1],requests[1][0])
        self.assertFalse(service.ROOMS['a'*64]['receivers'][requests[2][0]]['approved'])

    async def test_cannot_negotiate_or_self_approve_before_owner_accepts(self):
        a,b,identity=await self.pair()
        await b.send({'type':'approve','id':identity})
        self.assertEqual((await b.receive())[0],8)
        self.assertEqual((await a.receive())[1]['type'],'left')

    async def test_sender_cannot_offer_before_approval(self):
        a,b,identity=await self.pair()
        await a.send({'type':'offer','id':identity,'sdp':'v=0\r\nforbidden'})
        self.assertEqual((await a.receive())[0],8)

    async def test_receiver_cannot_target_another_applicant(self):
        a,b,identity=await self.pair(); await self.approve(a,b,identity)
        c=await self.apply(a); await c.receive(); other=(await a.receive())[1]['id']
        answer={'type':'answer','sdp':'v=0\r\nsynthetic'}
        await b.send({**answer,'id':other})
        self.assertEqual((await a.receive())[1],{**answer,'id':identity})
        self.assertFalse(service.ROOMS['a'*64]['receivers'][other]['approved'])

    async def test_forwarding_is_scoped_and_host_survives_pairing(self):
        a,b,identity=await self.pair(); await self.approve(a,b,identity)
        offer={'type':'offer','sdp':'v=0\r\nsynthetic'}
        await a.send({**offer,'id':identity}); self.assertEqual((await b.receive())[1],offer)
        answer={'type':'answer','sdp':'v=0\r\nsynthetic answer'}
        await b.send(answer); self.assertEqual((await a.receive())[1],{**answer,'id':identity})
        await a.send({'type':'done','id':identity}); await b.send({'type':'done'})
        self.assertEqual((await b.receive())[0],8)
        await asyncio.sleep(.03)
        c=await self.apply(a); await c.receive()
        self.assertEqual((await a.receive())[1]['type'],'request')
        self.assertIn('a'*64,service.ROOMS)

    async def test_rejection_only_removes_selected_applicant(self):
        a,b,identity=await self.pair()
        c=await self.apply(a); await c.receive(); other=(await a.receive())[1]['id']
        await a.send({'type':'reject','id':identity})
        self.assertEqual((await b.receive())[1]['type'],'error')
        self.assertEqual((await a.receive())[1],{'type':'left','id':identity})
        self.assertIn(other,service.ROOMS['a'*64]['receivers'])

    async def test_nonce_cannot_be_replayed(self):
        a=await self.client('sender'); await a.receive()
        b=await self.client('receiver'); nonce=(await b.receive())[1]['nonce']
        proof=hmac.new(self.verifier.encode(),nonce.encode(),hashlib.sha256).hexdigest()
        c=await self.client('receiver'); await c.receive()
        await c.send({'type':'apply','proof':proof,'application':'Replay fixture'})
        self.assertEqual((await c.receive())[1]['type'],'error')
        with self.assertRaises(asyncio.TimeoutError): await asyncio.wait_for(a.receive(),.05)

    async def test_legacy_sender_is_rejected(self):
        a=await self.client('sender',protocol=1)
        self.assertEqual((await a.receive())[1]['type'],'error'); self.assertFalse(service.ROOMS)

    async def test_unknown_room_and_collision(self):
        b=await self.client('receiver'); self.assertEqual((await b.receive())[1]['type'],'error')
        a=await self.client('sender'); await a.receive()
        c=await self.client('sender'); self.assertEqual((await c.receive())[1]['code'],'code_in_use')

    async def test_no_media_messages_and_pair_byte_limit(self):
        a,b,identity=await self.pair(); await self.approve(a,b,identity)
        await a.send({'type':'video','id':identity,'data':'forbidden'})
        self.assertEqual((await a.receive())[0],8)

    async def test_signaling_never_relays_room_chat(self):
        a,b,identity=await self.pair(); await self.approve(a,b,identity)
        await b.send({'type':'chat','text':'PRIVATE_CHAT_MUST_NOT_USE_SIGNALING'})
        self.assertEqual((await b.receive())[0],8)
        with open(self.audit_path) as stream: self.assertNotIn('PRIVATE_CHAT_MUST_NOT_USE_SIGNALING',stream.read())

    async def test_device_fields_and_request_shape_are_bounded(self):
        a=await self.client('sender',device={'mac':'00:11:22:33:44:55'})
        self.assertEqual((await a.receive())[0],8)
        self.assertFalse(service.ROOMS)

    async def test_static_assets_have_no_store_headers(self):
        for path in ['/','/receiver.js','/receiver-auth.js','/receiver-room.js','/receiver-i18n.js','/privacy.html']:
            reader,writer=await asyncio.open_connection('127.0.0.1',self.port)
            writer.write(f'GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode()); await writer.drain()
            response=await reader.read(); writer.close(); await writer.wait_closed()
            self.assertIn(b'200 OK',response); self.assertIn(b'Cache-Control: no-store',response)

    async def test_audit_failure_refuses_registration(self):
        with mock.patch.object(service.AUDIT,'record',side_effect=AuditUnavailable()):
            reader,writer=await asyncio.open_connection('127.0.0.1',self.port)
            writer.write(b'GET /signal HTTP/1.1\r\nHost: localhost\r\n\r\n'); await writer.drain()
            self.assertIn(b'503',await reader.read()); writer.close(); await writer.wait_closed()
        self.assertFalse(service.ROOMS)

    async def test_suggestion_skips_occupied_and_excluded_codes(self):
        key=hashlib.sha256(b'12345678').hexdigest()
        a=await self.client('sender',key); await a.receive()
        c=await Client.open(self.port); self.clients.append(c)
        with mock.patch.object(service.secrets,'randbelow',side_effect=[12345678,23456789,34567890]):
            await c.send({'role':'suggest','exclude':[hashlib.sha256(b'23456789').hexdigest()]})
            self.assertEqual((await c.receive())[1],{'type':'suggestion','code':'34567890'})

    async def test_direct_audit_is_metadata_only(self):
        a=await Client.open(self.port,path='/audit'); self.clients.append(a)
        device={'installation_id':'b'*32,'platform':'macOS','model':'Synthetic','os_version':'0','app_version':'1.4','app_build':'71-test'}
        packet={'role':'audit','route':'internet_ip','session_id':'c'*32,'peer_role':'sender','event':'ended','duration_ms':100,'device':device}
        await a.send(packet); self.assertEqual((await a.receive())[1]['type'],'audit_recorded')
        b=await Client.open(self.port,path='/audit'); self.clients.append(b)
        await b.send({**packet,'application':'not-a-log-field'})
        self.assertEqual((await b.receive())[0],8)

class AuditTests(unittest.TestCase):
    def test_rotation_permissions_and_retention(self):
        with tempfile.TemporaryDirectory() as directory:
            path=os.path.join(directory,'connections.jsonl')
            log=AuditLog(path, max_bytes=512, backups=2, retention_days=1)
            for _ in range(6): log.record('test', ip='203.0.113.4')
            with self.assertRaises(AuditUnavailable):
                for _ in range(12): log.record('test', ip='203.0.113.4')
            self.assertLessEqual(len([name for name in os.listdir(directory) if name != ".lock"]),3)
            self.assertEqual(os.stat(path).st_mode & 0o777,0o600)
            for name in os.listdir(directory):
                if name == ".lock": continue
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
