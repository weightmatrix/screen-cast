"""Bounded pairing and STUN only. No media, TURN, database, or external dependencies."""
import asyncio, base64, collections, hashlib, ipaddress, json, os, re, secrets, struct, time, uuid
from pathlib import Path
from audit import AuditLog, AuditUnavailable
MAX_FRAME = 16384
MAX_TOTAL = 65536
ROOMS = {}
RATE = {}
ACTIVE = 0
AUDIT = None
class Rejected(Exception): pass

def audit(event, **metadata):
    global AUDIT
    if AUDIT is None:
        try:
            days = 184  # Fixed operational policy; legal holds are handled separately.
            AUDIT = AuditLog(os.environ.get('AUDIT_LOG_PATH', 'audit/connections.jsonl'), retention_days=days)
        except (OSError, ValueError) as error: raise AuditUnavailable('Connection audit unavailable') from error
    AUDIT.record(event, **metadata)

def source_ip(peer_ip, headers):
    # Only the internal proxy may supply the client address. Invalid/multiple
    # values fall back to the socket peer and cannot inject arbitrary log text.
    if os.environ.get('TRUST_PROXY') == '1' and ipaddress.ip_address(peer_ip).is_private:
        try: return str(ipaddress.ip_address(headers.get('x-real-ip', peer_ip)))
        except ValueError: pass
    return str(ipaddress.ip_address(peer_ip))

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
    def __init__(self, reader, writer, context=None):
        self.reader, self.writer = reader, writer
        self.lock = asyncio.Lock()
        self.bytes = self.messages = 0
        self.context = context or {}
        self.audit_only = False
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

async def maintain_audit():
    while True:
        await asyncio.sleep(3600)
        try:
            if AUDIT is not None: AUDIT.cleanup()
        except OSError:
            print('Connection audit maintenance failed; check private storage', flush=True)

async def keepalive(ws):
    while True:
        await asyncio.sleep(60)
        await ws.frame(9)

def device_metadata(value):
    if value is None: return None  # Older clients remain compatible.
    patterns = {'installation_id': '[a-f0-9]{32}', 'platform': 'macOS|iPadOS|browser',
                'model': '[A-Za-z0-9_,.-]{1,64}', 'os_version': '[0-9.]{1,32}',
                'app_version': '[A-Za-z0-9_.+-]{1,32}', 'app_build': '[A-Za-z0-9_.+-]{1,32}'}
    if not isinstance(value, dict) or set(value) != set(patterns): raise Rejected()
    if any(not isinstance(value[key], str) or not re.fullmatch(pattern, value[key]) for key, pattern in patterns.items()): raise Rejected()
    return value

async def expire_approval(room):
    await asyncio.sleep(60)
    if room['approved']: return
    try: audit('admission_expired', pair_id=room['id'])
    except AuditUnavailable: print('Connection audit unavailable during admission expiry', flush=True)
    for peer in (room['sender'], room['receiver']):
        if peer:
            try:
                await peer.send({'type':'error','message':'接入申请已超时'})
                await peer.frame(8, struct.pack('!H', 1000))
                peer.writer.close()
            except (OSError, ConnectionError): pass

async def exchange(ws):
    hello = await asyncio.wait_for(ws.receive(), 10)
    role, key = hello.get('role'), hello.get('room')
    if (role == 'audit') != ws.audit_only: raise Rejected()
    if role == 'audit':
        if set(hello) - {'role', 'route', 'session_id', 'peer_role', 'event', 'device', 'duration_ms'}: raise Rejected()
        if hello.get('route') not in ('internet_ip', 'internet_code') or hello['peer_role'] not in ('sender', 'receiver') or hello['event'] not in ('attempt', 'approved', 'rejected', 'connected', 'ended'): raise Rejected()
        if not isinstance(hello['session_id'], str) or not re.fullmatch('[a-f0-9]{32}', hello['session_id']): raise Rejected()
        if hello['event'] in ('approved', 'rejected') and (hello['route'] != 'internet_ip' or hello['peer_role'] != 'sender'): raise Rejected()
        duration = hello.get('duration_ms')
        if duration is not None and (hello['event'] != 'ended' or type(duration) is not int or not 0 <= duration <= 31 * 86400000): raise Rejected()
        device = device_metadata(hello['device'])
        if device is None: raise Rejected()
        audit('direct_connection_reported', **ws.context, route=hello['route'], session_id=hello['session_id'], duration_ms=duration,
              peer_role=hello['peer_role'], lifecycle=hello['event'], device=device,
              evidence='client_report_only', mac_address_available=False)
        await ws.send({'type': 'audit_recorded'})
        return
    if role == 'suggest':
        excluded = hello.get('exclude', [])
        if set(hello) - {'role', 'exclude'} or not isinstance(excluded, list) or len(excluded) > 32 or any(
                not isinstance(value, str) or not re.fullmatch('[a-f0-9]{64}', value) for value in excluded): raise Rejected()
        ws.context['role'] = 'suggest'
        for _ in range(128):
            candidate = f'{secrets.randbelow(100_000_000):08d}'
            digest = hashlib.sha256(candidate.encode()).hexdigest()
            if digest not in ROOMS and digest not in excluded:
                audit('code_suggested', **ws.context)
                await ws.send({'type': 'suggestion', 'code': candidate})
                return
        await ws.send({'type': 'error', 'message': '暂时无法生成建议码，请稍后重试'})
        return
    if role not in ('sender', 'receiver') or not isinstance(key, str) or not re.fullmatch('[a-f0-9]{64}', key): raise Rejected()
    ws.context['role'] = role
    device = device_metadata(hello.get('device'))
    audit('device_reported', **ws.context, device=device, evidence='client_report_only',
          device_metadata_available=device is not None, mac_address_available=False)
    if role == 'sender':
        if hello.get('approval') != 1:
            await ws.send({'type':'error','message':'请更新投送端以启用公网接入审批'}); return
        if key in ROOMS:
            audit('pairing_rejected', **ws.context, reason='room_unavailable')
            await ws.send({'type':'error','code':'code_in_use','message':'匹配码已使用，请修改匹配码'}); return
        if len(ROOMS) >= 32:
            audit('pairing_rejected', **ws.context, reason='server_busy')
            await ws.send({'type':'error','code':'server_busy','message':'配对服务繁忙，请稍后重试'}); return
        room = {'sender': ws, 'receiver': None, 'finished': False, 'approved': False, 'approval_timeout': None, 'done': set(), 'bytes': 0, 'id': uuid.uuid4().hex}
        ROOMS[key] = room
    else:
        room = ROOMS.get(key)
        if not room or room['receiver']:
            audit('pairing_rejected', **ws.context, reason='sender_not_found_or_busy')
            await ws.send({'type':'error','message':'未找到可连接的广域网投屏'}); return
        room['receiver'] = ws
    try:
        ws.context['pair_id'] = room['id']
        audit('sender_waiting' if role == 'sender' else 'receiver_joined', **ws.context)
        if role == 'sender': await ws.send({'type':'waiting'})
        else:
            await ws.send({'type':'waiting_approval'})
            await room['sender'].send({'type':'peer'})
            room['approval_timeout'] = asyncio.create_task(expire_approval(room))
        while True:
            obj = await ws.receive()
            kind = obj.get('type')
            room['bytes'] += len(json.dumps(obj, separators=(',', ':')).encode())
            if room['bytes'] > MAX_TOTAL: raise Rejected()
            if kind in ('approve', 'reject'):
                if role != 'sender' or not room['receiver'] or room['approved'] or set(obj) != {'type'}: raise Rejected()
                audit('admission_approved' if kind == 'approve' else 'admission_rejected', **ws.context)
                if kind == 'reject':
                    await room['receiver'].send({'type':'error','message':'投送者拒绝申请或连接已达上限'})
                    return
                room['approved'] = True
                if room['approval_timeout']: room['approval_timeout'].cancel()
                for peer in (room['sender'], room['receiver']):
                    await peer.send({'type':'approved', 'session_id':room['id']})
                continue
            if not room['approved']: raise Rejected()
            if kind == 'done':
                if role not in room['done']:
                    audit('peer_reported_connected', **ws.context, evidence='client_report_only')
                room['done'].add(role)
                if len(room['done']) == 2:
                    audit('pairing_completed', pair_id=room['id'], sender_connection_id=room['sender'].context.get('connection_id'),
                          receiver_connection_id=room['receiver'].context.get('connection_id'), evidence='both_clients_reported', media_end_observed=False)
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
        if room['approval_timeout']: room['approval_timeout'].cancel()
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
    peer = writer.get_extra_info('peername') or ('unknown', 0)
    context = {'connection_id': uuid.uuid4().hex, 'ip': peer[0], 'transport_peer_port': peer[1]}
    started = time.monotonic(); outcome = 'closed'; observed = False
    try:
        request = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
        if len(request) > 8192: raise Rejected()
        parts = request.decode('ascii').split('\r\n')
        method, path, _ = parts[0].split(' ')
        headers = dict(line.split(':', 1) for line in parts[1:] if ':' in line)
        headers = {k.lower():v.strip() for k,v in headers.items()}
        if method == 'GET' and path in ('/', '/receiver.js', '/receiver-i18n.js', '/privacy.html', '/support.html'):
            asset = 'receiver.html' if path == '/' else path[1:]
            body = (Path(__file__).parent / 'Web' / asset).read_bytes()
            if len(body) > 65536: raise Rejected()
            mime = b'application/javascript; charset=utf-8' if path.endswith('.js') else b'text/html; charset=utf-8'
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: '+mime+b'\r\nContent-Length: '+str(len(body)).encode()+
                b"\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self' wss://zhibenwang.com; media-src blob:; base-uri 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n"+body)
            await writer.drain(); return
        if method == 'GET' and path == '/health':
            body = b'{"service":"pairing-only","mediaRelay":false,"maxSessionBytes":65536,"connectionAudit":true}'
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '+str(len(body)).encode()+b'\r\nConnection: close\r\n\r\n'+body)
            await writer.drain(); return
        ip = source_ip(peer[0], headers)
        context['ip'] = ip
        audit('connection_received', **context); observed = True
        if method != 'GET' or path not in ('/signal', '/audit') or ACTIVE >= 64: raise Rejected()
        if not allowance(ip, 'audit' if path == '/audit' else 'ws', 60 if path == '/audit' else 20): raise Rejected()
        if headers.get('upgrade', '').lower() != 'websocket' or headers.get('sec-websocket-version') != '13': raise Rejected()
        key = headers.get('sec-websocket-key', '')
        if len(base64.b64decode(key, validate=True)) != 16: raise Rejected()
        audit('websocket_accepted', **context)
        accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        writer.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
        await writer.drain()
        ACTIVE += 1
        ws = Socket(reader, writer, context)
        ws.audit_only = path == '/audit'
        ping = asyncio.create_task(keepalive(ws))
        await asyncio.wait_for(exchange(ws), 600)
    except AuditUnavailable:
        outcome = 'audit_unavailable'
        # Fail closed: do not silently pair when metadata cannot be persisted.
        print('Connection audit unavailable; pairing refused', flush=True)
        if not ws:
            writer.write(b'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
    except Exception as error:
        outcome = 'timeout' if isinstance(error, asyncio.TimeoutError) else 'peer_closed' if isinstance(error, (EOFError, asyncio.IncompleteReadError, ConnectionError)) else 'protocol_rejected'
        if ws:
            try: await ws.frame(8, struct.pack('!H', 1008))
            except Exception: pass
        else:
            writer.write(b'HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
    finally:
        if observed or outcome != 'closed':
            try:
                audit('signaling_closed' if ws else 'connection_rejected', **context, outcome=outcome,
                      signaling_duration_ms=round((time.monotonic() - started) * 1000),
                      received_bytes=ws.bytes if ws else 0, received_messages=ws.messages if ws else 0,
                      media_end_observed=False)
            except AuditUnavailable:
                print('Connection audit unavailable during close', flush=True)
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
    audit('service_started', instance_id=uuid.uuid4().hex)
    maintenance = asyncio.create_task(maintain_audit())
    host = os.environ.get('BIND_HOST', '127.0.0.1')
    server = await asyncio.start_server(connection, host, int(os.environ.get('PORT', '8322')), limit=8192)
    await asyncio.get_running_loop().create_datagram_endpoint(STUN, local_addr=('0.0.0.0', int(os.environ.get('STUN_PORT', '3478'))))
    async with server: await server.serve_forever()
if __name__ == '__main__': asyncio.run(main())
