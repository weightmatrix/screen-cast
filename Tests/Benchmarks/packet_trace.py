"""Bounded, header-only SRTP observation for the local test link; no decryption."""
from collections import Counter, OrderedDict
import struct


class PacketTrace:
    def __init__(self):
        self.maps = [{}, {}]
        self.phase = "negotiation"
        self.totals = Counter()
        self.phases = {}
        self.streams = {}

    def count(self, key, amount=1):
        self.totals[key] += amount
        self.phases.setdefault(self.phase, Counter())[key] += amount

    def receive(self, side, data):
        # RFC7983 demux: distinguish RTP/SRTP from STUN, DTLS and RTCP/SRTCP.
        if len(data) < 12 or data[0] >> 6 != 2 or 192 <= data[1] <= 223:
            self.count("non_rtp_received")
            return None
        pt = data[1] & 127
        seq, timestamp, ssrc = struct.unpack_from(">HII", data, 2)
        kind = self.maps[side].get(str(pt), "unknown").lower()
        kind = "rtx" if kind == "rtx" else "media" if kind == "h264" else "unknown"
        key = (side, ssrc)
        if key not in self.streams:
            if len(self.streams) >= 32:
                self.count("stream_overflow")
                return None
            self.streams[key] = dict(ordinal=0, forwarded=0, sequence=None, seen=OrderedDict())
        stream = self.streams[key]
        high = stream["sequence"]
        extended = seq if high is None else high + ((seq - (high & 65535) + 32768) % 65536 - 32768)
        if high is not None and extended < high:
            self.count(kind + "_input_sequence_reordered")
        stream["sequence"] = max(high if high is not None else extended, extended)
        stream["ordinal"] += 1
        self.count(kind + "_received")
        return (key, stream["ordinal"], kind, (extended, timestamp, pt))

    def outcome(self, ticket, outcome):
        if ticket is None:
            return
        key, ordinal, kind, identity = ticket
        self.count(kind + "_" + outcome)
        if outcome != "forwarded":
            return
        stream = self.streams[key]
        if ordinal < stream["forwarded"]:
            self.count(kind + "_link_reordered")
        stream["forwarded"] = max(stream["forwarded"], ordinal)
        # Same RTP identity arriving twice, NOT an RTX-to-original association.
        if identity in stream["seen"]:
            self.count(kind + "_repeated_identity_forwarded")
        stream["seen"][identity] = True
        stream["seen"].move_to_end(identity)
        if len(stream["seen"]) > 4096:
            stream["seen"].popitem(last=False)

    def snapshot(self):
        return dict(schema=1, totals=dict(self.totals),
                    phases={k: dict(v) for k, v in self.phases.items()},
                    limitations=["RTP header only; SRTP payload and RTX original sequence remain encrypted.",
                                 "forwarded means sendto succeeded, not receiver/decode acknowledgement.",
                                 "Repeated identity is bounded to 4096 recent identities per stream; streams limited to 32."])
