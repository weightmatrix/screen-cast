import os
import struct
import unittest
from ops.stun_server import binding_response, BindingServer


class BindingTests(unittest.TestCase):
    def request(self, kind=1, body=b''):
        return struct.pack('!HHI', kind, len(body), 0x2112A442) + os.urandom(12) + body
    def test_reflects_only_observed_address_and_transaction(self):
        data = self.request(); reply = binding_response(data, ('192.0.2.17', 43210))
        self.assertEqual(len(reply), 32); self.assertEqual(reply[8:20], data[8:20])
        self.assertEqual(struct.unpack('!H', reply[26:28])[0] ^ 0x2112, 43210)
        self.assertEqual(struct.unpack('!I', reply[28:32])[0] ^ 0x2112A442, 0xc0000211)
    def test_turn_binary_and_malformed_attributes_never_relay(self):
        for data in [self.request(3), b'video', self.request(body=b'\x00'*260),
                     self.request(body=struct.pack('!HH', 1, 8)), self.request(body=b'\x00')]:
            self.assertIsNone(binding_response(data, ('192.0.2.17', 12345)))
    def test_per_ip_limit(self):
        class Transport:
            replies = 0
            def sendto(self, *args): self.replies += 1
        server = BindingServer(); transport = Transport(); server.connection_made(transport)
        for _ in range(65): server.datagram_received(self.request(), ('192.0.2.17', 12345))
        self.assertEqual(transport.replies, 60)
