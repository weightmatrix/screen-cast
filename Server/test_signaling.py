import asyncio, base64, json, os, struct, unittest
import signaling as service

class Client:
    @classmethod
    async def open(cls, port):
        self = cls()
        self.r, self.w = await asyncio.open_connection('127.0.0.1', port)
        self.w.write(b'GET /signal HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+base64.b64encode(os.urandom(16))+b'\r\n\r\n')
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
        service.ROOMS.clear(); service.RATE.clear()
        self.server = await asyncio.start_server(service.connection,'127.0.0.1',0,limit=8192)
        self.port = self.server.sockets[0].getsockname()[1]
        self.clients=[]
    async def asyncTearDown(self):
        for c in self.clients: await c.close()
        self.server.close(); await self.server.wait_closed(); await asyncio.sleep(.02)
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
    async def test_no_media_messages(self):
        a,b=await self.pair(); await a.send({'type':'video','data':'forbidden'})
        self.assertEqual((await a.receive())[0],8)
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
if __name__ == '__main__': unittest.main()
