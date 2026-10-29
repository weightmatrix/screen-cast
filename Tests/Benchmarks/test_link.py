import socket
import sys
import time
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from runner import Link, PHASES, summarize


class LinkChecks(unittest.TestCase):
    def setUp(self):
        self.link = Link("127.0.0.1")
        self.a, self.b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM), socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for sock in (self.a, self.b):
            sock.bind(("127.0.0.1", 0))
            sock.setblocking(False)
        self.link.configure(dict(sender=self.a.getsockname(), receiver=self.b.getsockname(),
                                 profile=dict(mbps=0.08, delay_ms=20, jitter_ms=0, loss=0, queue_ms=2000)))

    def tearDown(self):
        self.link.close(); self.a.close(); self.b.close()

    def collect(self, sock, wanted, seconds=3):
        received = []
        until = time.monotonic() + seconds
        while time.monotonic() < until and len(received) < wanted:
            self.link.step(0.001)
            while True:
                try:
                    data, address = sock.recvfrom(65535)
                    received.append((time.monotonic(), data, address))
                except BlockingIOError:
                    break
        return received

    def test_real_bandwidth_delay_and_bidirectional_source_ports(self):
        begin = time.monotonic()
        for n in range(10):
            self.a.sendto(bytes([n]) * 1000, ("127.0.0.1", self.link.ports[1]))
        received = self.collect(self.b, 10)
        self.assertEqual([p[1][0] for p in received], list(range(10)))
        self.assertGreaterEqual(received[0][0] - begin, 0.10)
        self.assertGreaterEqual(received[-1][0] - received[0][0], 0.80)
        self.assertTrue(all(p[2][1] == self.link.ports[0] for p in received))
        self.b.sendto(b"feedback", ("127.0.0.1", self.link.ports[0]))
        response = self.collect(self.a, 1)
        self.assertEqual(response[0][1], b"feedback")
        self.assertEqual(response[0][2][1], self.link.ports[1])

    def test_finite_queue_drops_instead_of_unbounded_latency(self):
        self.link.configure(dict(sender=self.a.getsockname(), receiver=self.b.getsockname(), profile=dict(queue_ms=150)))
        for _ in range(20):
            self.a.sendto(b"x" * 1000, ("127.0.0.1", self.link.ports[1]))
        self.collect(self.b, 20, seconds=0.35)
        self.assertGreater(self.link.counts["queue_dropped"], 0)
        self.assertLessEqual(self.link.counts["max_queue_ms"], 150)

    def test_loss_and_unknown_endpoint_rejection(self):
        self.link.configure(dict(sender=self.a.getsockname(), receiver=self.b.getsockname(), profile=dict(loss=1)))
        self.a.sendto(b"drop", ("127.0.0.1", self.link.ports[1]))
        self.collect(self.b, 1, seconds=0.03)
        self.assertEqual(self.link.counts["random_dropped"], 1)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as unknown:
            unknown.sendto(b"reject", ("127.0.0.1", self.link.ports[1]))
            self.collect(self.b, 1, seconds=0.03)
        self.assertEqual(self.link.counts["rejected"], 1)
        self.assertEqual(self.link.counts["forwarded"], 0)


class ReportChecks(unittest.TestCase):
    def link(self):
        return dict(totals=dict(bytes_forwarded=100000000), transitions=[
            dict(name="bandwidth_drop", counts=dict(queue_dropped=0)), dict(name="recovery", counts=dict(queue_dropped=10))])

    def fixture(self, slow_recovery=False):
        report = dict(frames=[], latencies=[], phases=[], stats=[], errors=[])
        begin = 0
        total = 0
        for phase in PHASES:
            fps = 20 if not phase["motion"] else 20 if slow_recovery and phase["name"] == "recovery" else 60
            end = begin + phase["seconds"]
            report["phases"].append(dict(name=phase["name"], start=begin, end=end, submitted=phase["seconds"] * (60 if phase["motion"] else 20)))
            for n in range(phase["seconds"] * fps):
                t = begin + (n + 0.5) / fps
                report["frames"].append(t)
                report["latencies"].append(dict(t=t, source_t=max(begin, t - 0.01), ms=10))
            for second in range(begin, end + 1):
                count = total + (second - begin) * fps
                for role, kind in (("sender", "outbound-rtp"), ("receiver", "inbound-rtp")):
                    values = dict(framesEncoded=count, framesDecoded=count, packetsSent=count * 10,
                                  packetsLost=0, freezeCount=0, totalFreezesDuration=0, totalEncodeTime=count * 0.005,
                                  totalDecodeTime=count * 0.002, totalPacketSendDelay=count * 0.01,
                                  jitterBufferDelay=count * 0.01, jitterBufferEmittedCount=count)
                    report["stats"].append(dict(t=second, role=role, stats=[dict(type=kind, values=values)]))
            total += phase["seconds"] * fps
            begin = end
        report["stats"].sort(key=lambda s: s["t"])
        return report

    def test_functional_success_does_not_hide_slow_recovery(self):
        good = summarize(self.fixture(), self.link())
        self.assertTrue(good["functional_pass"])
        self.assertTrue(good["performance_pass"])
        bad = summarize(self.fixture(slow_recovery=True), self.link())
        self.assertTrue(bad["functional_pass"])
        self.assertFalse(bad["performance_pass"])
        self.assertIsNone(next(p for p in bad["phases"] if p["name"] == "recovery")["sustained_45fps_recovery_seconds"])

    def test_slow_generator_invalidates_comparison(self):
        report = self.fixture()
        report["phases"][1]["submitted"] = 12
        result = summarize(report, self.link())
        self.assertTrue(result["functional_pass"])
        self.assertFalse(result["comparison_valid"])
        self.assertFalse(result["performance_pass"])

    def test_window_metrics_are_weighted_by_frame_count(self):
        report = self.fixture()
        report["events"] = [dict(t=8, event="mac.display windowSec=2 rendered=30 avgMs=1 maxMs=3"),
                            dict(t=10, event="mac.display windowSec=2 rendered=10 avgMs=5 maxMs=7")]
        metric = summarize(report, self.link())["phases"][1]["window_metrics"]["mac.display.rendered"]
        self.assertEqual(metric, dict(count=40, mean_ms=2, max_ms=7))

    def test_unexercised_network_case_invalidates_comparison(self):
        result = summarize(self.fixture(), {})
        self.assertTrue(result["functional_pass"])
        self.assertFalse(result["comparison_valid"])

    def test_missing_frames_or_markers_is_not_a_pass(self):
        report = self.fixture()
        report["latencies"] = []
        self.assertFalse(summarize(report, self.link())["functional_pass"])
        report = self.fixture()
        report["errors"] = ["ICE bypassed test link"]
        self.assertFalse(summarize(report, self.link())["performance_pass"])


if __name__ == "__main__":
    unittest.main()
