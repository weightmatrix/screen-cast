"""Bounded pairing and STUN only. No media, TURN, database, or external dependencies."""
import asyncio, base64, collections, hashlib, ipaddress, json, os, re, struct, time
MAX_FRAME = 16384
MAX_TOTAL = 65536
ROOMS = {}
RATE = {}
ACTIVE = 0
class Rejected(Exception): pass

def allowance(ip, name, limit):
    now = time.monotonic()
    key = (ip, name)
    if len(RATE) > 4096:
        for k in list(RATE):
            if not RATE[k] or now - RATE[k][-1] > 60: RATE.pop(k, None)
        if key not in RATE and len(RATE) > 4096: return False
    times = RATE.setdefault(key, collections.deque())
    while times and now - times[0] > 60: times.popleft()
    if len(times) >= limit: return False
    times.append(now)
    return True

class Socket:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.lock = asyncio.Lock()
        self.bytes = self.messages = 0
    async def frame(self, opcode, data=b''):
        if len(data) > MAX_FRAME: raise Rejected()
        header = bytes([0x80 | opcode])
        header += bytes([len(data)]) if len(data) < 126 else b'\x7e' + struct.pack('!H', len(data))
        async with self.lock:
            self.writer.write(header + data)
            await asyncio.wait_for(self.writer.drain(), 5)
    async def send(self, obj):
        await self.frame(1, json.dumps(obj, separators=(',', ':')).encode())
    async def receive(self):
        while True:
            first, second = await asyncio.wait_for(self.reader.readexactly(2), 95)
            if first & 0x70 or not first & 0x80 or not second & 0x80: raise Rejected()
            opcode, size = first & 15, second & 127
            if size == 127: raise Rejected()
            if size == 126: size = struct.unpack('!H', await self.reader.readexactly(2))[0]
            if size > MAX_FRAME or (opcode >= 8 and size > 125): raise Rejected()
            mask = await self.reader.readexactly(4)
            raw = await self.reader.readexactly(size)
            data = bytes(n ^ mask[i % 4] for i, n in enumerate(raw))
            self.bytes += size + 6
            self.messages += 1
            if self.bytes > MAX_TOTAL or self.messages > 96: raise Rejected()
            if opcode == 8: raise EOFError()
            if opcode == 9: await self.frame(10, data); continue
            if opcode == 10: continue
            if opcode != 1: raise Rejected()
            obj = json.loads(data)
            if not isinstance(obj, dict): raise Rejected()
            return obj

async def keepalive(ws):
    while True:
        await asyncio.sleep(60)
        await ws.frame(9)

async def exchange(ws):
    hello = await asyncio.wait_for(ws.receive(), 10)
    role, key = hello.get('role'), hello.get('room')
    if role not in ('sender', 'receiver') or not isinstance(key, str) or not re.fullmatch('[a-f0-9]{64}', key): raise Rejected()
    if role == 'sender':
        if key in ROOMS or len(ROOMS) >= 32:
            await ws.send({'type':'error','message':'匹配码已使用或服务繁忙'}); return
        room = {'sender': ws, 'receiver': None, 'finished': False, 'done': set(), 'bytes': 0}
        ROOMS[key] = room
    else:
        room = ROOMS.get(key)
        if not room or room['receiver']:
            await ws.send({'type':'error','message':'未找到可连接的广域网投屏'}); return
        room['receiver'] = ws
    try:
        if role == 'sender': await ws.send({'type':'waiting'})
        else: await room['sender'].send({'type':'peer'})
        while True:
            obj = await ws.receive()
            kind = obj.get('type')
            room['bytes'] += len(json.dumps(obj, separators=(',', ':')).encode())
            if room['bytes'] > MAX_TOTAL: raise Rejected()
            if kind == 'done':
                room['done'].add(role)
                if len(room['done']) == 2:
                    room['finished'] = True
                    for peer in (room['sender'], room['receiver']):
                        if peer: await peer.frame(8, struct.pack('!H', 1000))
                    return
                continue
            if kind in ('offer','answer'):
                if (kind == 'offer') != (role == 'sender'): raise Rejected()
                if set(obj) != {'type','sdp'} or not isinstance(obj['sdp'], str) or not obj['sdp'].startswith('v=0\r\n'): raise Rejected()
                if len(obj['sdp']) > 12288: raise Rejected()
            elif kind == 'candidate':
                if set(obj) != {'type','candidate','mid','line'}: raise Rejected()
                if not isinstance(obj['candidate'], str) or not obj['candidate'].startswith('candidate:') or len(obj['candidate']) > 2048: raise Rejected()
                if not isinstance(obj['line'], int) or not 0 <= obj['line'] <= 16: raise Rejected()
                if obj['mid'] is not None and (not isinstance(obj['mid'], str) or len(obj['mid']) > 64): raise Rejected()
            else: raise Rejected()
            peer = room['receiver'] if role == 'sender' else room['sender']
            if peer: await peer.send(obj)
    finally:
        if ROOMS.get(key) is room:
            ROOMS.pop(key, None)
        if not room['finished']:
            other = room['receiver'] if role == 'sender' else room['sender']
            if other:
                try:
                    await other.send({'type':'error','message':'配对已结束，请重试'})
                    await other.frame(8, struct.pack('!H', 1000))
                except Exception: pass

async def connection(reader, writer):
    global ACTIVE
    ws = None; ping = None
    try:
        request = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
        if len(request) > 8192: raise Rejected()
        parts = request.decode('ascii').split('\r\n')
        method, path, _ = parts[0].split(' ')
        headers = dict(line.split(':', 1) for line in parts[1:] if ':' in line)
        headers = {k.lower():v.strip() for k,v in headers.items()}
        if method == 'GET' and path == '/health':
            body = b'{"service":"pairing-only","mediaRelay":false,"maxSessionBytes":65536}'
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '+str(len(body)).encode()+b'\r\nConnection: close\r\n\r\n'+body)
            await writer.drain(); return
        peer_ip = writer.get_extra_info('peername')[0]
        ip = headers.get('x-real-ip', peer_ip) if os.environ.get('TRUST_PROXY') == '1' else peer_ip
        if method != 'GET' or path != '/signal' or ACTIVE >= 64 or not allowance(ip, 'ws', 20): raise Rejected()
        if headers.get('upgrade', '').lower() != 'websocket' or headers.get('sec-websocket-version') != '13': raise Rejected()
        key = headers.get('sec-websocket-key', '')
        if len(base64.b64decode(key, validate=True)) != 16: raise Rejected()
        accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        writer.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
        await writer.drain()
        ACTIVE += 1
        ws = Socket(reader, writer)
        ping = asyncio.create_task(keepalive(ws))
        await asyncio.wait_for(exchange(ws), 600)
    except Exception:
        if ws:
            try: await ws.frame(8, struct.pack('!H', 1008))
            except Exception: pass
        else:
            writer.write(b'HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
    finally:
        if ping: ping.cancel()
        if ws: ACTIVE -= 1
        writer.close()
        try: await writer.wait_closed()
        except Exception: pass

class STUN(asyncio.DatagramProtocol):
    def connection_made(self, transport): self.transport = transport
    def datagram_received(self, data, addr):
        if not 20 <= len(data) <= 256: return
        kind, length, cookie = struct.unpack('!HHI', data[:8])
        if kind != 1 or cookie != 0x2112A442 or length + 20 != len(data) or not allowance(addr[0], 'stun', 60): return
        ip = ipaddress.ip_address(addr[0])
        if ip.version != 4: return
        mapped = struct.pack('!BBHI', 0, 1, addr[1] ^ 0x2112, int(ip) ^ cookie)
        attr = struct.pack('!HH', 0x0020, 8) + mapped
        self.transport.sendto(struct.pack('!HHI', 0x0101, len(attr), cookie)+data[8:20]+attr, addr)

async def main():
    host = os.environ.get('BIND_HOST', '127.0.0.1')
    server = await asyncio.start_server(connection, host, int(os.environ.get('PORT', '8322')), limit=8192)
    await asyncio.get_running_loop().create_datagram_endpoint(STUN, local_addr=('0.0.0.0', int(os.environ.get('STUN_PORT', '3478'))))
    async with server: await server.serve_forever()
if __name__ == '__main__': asyncio.run(main())
