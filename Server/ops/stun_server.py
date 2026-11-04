"""Bounded IPv4 STUN Binding only (RFC 8489). Never allocates or relays media."""
import asyncio
import ipaddress
import struct
import time


def binding_response(data, address):
    if not 20 <= len(data) <= 256: return None
    kind, length, cookie = struct.unpack('!HHI', data[:8])
    if kind != 1 or cookie != 0x2112A442 or length % 4 or length + 20 != len(data): return None
    # Validate all attribute boundaries; no arbitrary payload forwarding.
    offset = 20
    while offset < len(data):
        if offset + 4 > len(data): return None
        _, size = struct.unpack('!HH', data[offset:offset + 4])
        offset += 4 + ((size + 3) // 4) * 4
        if offset > len(data): return None
    ip = ipaddress.ip_address(address[0])
    if ip.version != 4: return None
    mapped = struct.pack('!BBHI', 0, 1, address[1] ^ 0x2112, int(ip) ^ cookie)
    return struct.pack('!HHI', 0x0101, 12, cookie) + data[8:20] + struct.pack('!HH', 0x0020, 8) + mapped


class BindingServer(asyncio.DatagramProtocol):
    def __init__(self):
        self.rates = {}; self.second = -1; self.total = 0
    def connection_made(self, transport): self.transport = transport
    def datagram_received(self, data, address):
        now = int(time.monotonic()); minute = now // 60
        if self.second != now: self.second = now; self.total = 0
        if self.total >= 100: return
        self.total += 1
        previous, count = self.rates.get(address[0], (-1, 0))
        if previous != minute: count = 0
        if count >= 60: return
        if address[0] not in self.rates and len(self.rates) >= 2048:
            self.rates = {ip: value for ip, value in self.rates.items() if value[0] == minute}
            if len(self.rates) >= 2048: return
        self.rates[address[0]] = (minute, count + 1)
        reply = binding_response(data, address)
        if reply: self.transport.sendto(reply, address)


async def main():
    await asyncio.get_running_loop().create_datagram_endpoint(BindingServer, local_addr=('0.0.0.0', 3478))
    print('STUN Binding only; no media or TURN', flush=True)
    await asyncio.Future()


if __name__ == '__main__': asyncio.run(main())
