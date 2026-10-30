#!/usr/bin/env python3
"""Local-only UDP impairment and repeatable native-video benchmark runner (stdlib)."""
import argparse
import hashlib
import heapq
import json
import math
import os
from pathlib import Path
import random
import re
import selectors
import socket
import statistics
import struct
import subprocess
import tempfile
import time
import zlib
from packet_trace import PacketTrace

PROTOCOL_PATH = Path(__file__).with_name("protocol.json")
PROTOCOL = json.loads(PROTOCOL_PATH.read_text())
PHASES = PROTOCOL["phases"]
CRITERIA = PROTOCOL["criteria"]


def atomic_json(path, value):
    temporary = Path(str(path) + ".new")
    temporary.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True))
    temporary.replace(path)


class Link:
    """Two local UDP endpoints, bounded FIFO service time, deterministic impairments.

    A sends to sockets[1]; forward from sockets[0] to B. Reverse is symmetric.
    Only the exact ICE endpoints in the control file may use this test link.
    """
    def __init__(self, host, seed=20261029, ordered=False):
        self.selector = selectors.DefaultSelector()
        self.sockets = []
        for side in range(2):
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.bind((host, 0))
            sock.setblocking(False)
            self.sockets.append(sock)
            self.selector.register(sock, selectors.EVENT_READ, side)
        self.random = random.Random(seed)
        self.endpoints = [None, None]
        self.profile = dict(mbps=20, delay_ms=10, jitter_ms=2, loss=0, queue_ms=150)
        self.next_service = [0.0, 0.0]
        self.pending = []
        self.sequence = 0
        self.ordered = ordered
        self.last_due = [0.0, 0.0]
        self.trace = PacketTrace()
        self.counts = dict(received=0, forwarded=0, queue_dropped=0, random_dropped=0,
                           rejected=0, send_errors=0, bytes_forwarded=0, max_queue_ms=0)

    @property
    def ports(self):
        return [sock.getsockname()[1] for sock in self.sockets]

    def configure(self, value):
        self.endpoints = [tuple(value[k]) if value.get(k) else None for k in ("sender", "receiver")]
        self.trace.maps = [value.get("rtp_maps", {}).get(str(side), {}) for side in range(2)]
        self.trace.phase = value.get("phase", "negotiation")
        profile = value.get("profile", {})
        for key in self.profile:
            if key in profile:
                number = float(profile[key])
                if not math.isfinite(number):
                    raise ValueError("nonfinite network profile")
                self.profile[key] = number
        if self.profile["mbps"] <= 0 or not 0 <= self.profile["loss"] <= 1:
            raise ValueError("invalid network profile")
        if min(self.profile[k] for k in ("delay_ms", "jitter_ms", "queue_ms")) < 0:
            raise ValueError("negative network time")

    def step(self, timeout=0.005):
        for key, _ in self.selector.select(timeout):
            inbound = key.data
            while True:
                try:
                    data, address = key.fileobj.recvfrom(65535)
                except BlockingIOError:
                    break
                source = 1 - inbound
                self.counts["received"] += 1
                if address != self.endpoints[source] or self.endpoints[inbound] is None:
                    self.counts["rejected"] += 1
                    continue
                ticket = self.trace.receive(source, data)
                if self.random.random() < self.profile["loss"]:
                    self.counts["random_dropped"] += 1
                    self.trace.outcome(ticket, "random_dropped")
                    continue
                now = time.monotonic()
                # Apply the bandwidth ceiling in both directions independently.
                service = max(now, self.next_service[source]) + (len(data) + 28) * 8 / (self.profile["mbps"] * 1e6)
                queued_ms = (service - now) * 1000
                if queued_ms > self.profile["queue_ms"]:
                    self.counts["queue_dropped"] += 1
                    self.trace.outcome(ticket, "queue_dropped")
                    continue
                self.counts["max_queue_ms"] = max(self.counts["max_queue_ms"], queued_ms)
                self.next_service[source] = service
                jitter = self.random.uniform(-self.profile["jitter_ms"], self.profile["jitter_ms"])
                due = service + max(0, self.profile["delay_ms"] + jitter) / 1000
                if self.ordered:
                    due = max(due, self.last_due[source])
                self.last_due[source] = due
                self.sequence += 1
                heapq.heappush(self.pending, (due, self.sequence, source, data, ticket))
        now = time.monotonic()
        while self.pending and self.pending[0][0] <= now:
            _, _, source, data, ticket = heapq.heappop(self.pending)
            destination = self.endpoints[1 - source]
            if destination is None:
                continue
            try:
                self.sockets[source].sendto(data, destination)
                self.counts["forwarded"] += 1
                self.counts["bytes_forwarded"] += len(data)
                self.trace.outcome(ticket, "forwarded")
            except OSError:
                self.counts["send_errors"] += 1
                self.trace.outcome(ticket, "send_error")

    def close(self):
        self.selector.close()
        for sock in self.sockets:
            sock.close()


def document(path, seed):
    """Deterministic paper, small glyphs and a textured illustration; no user capture."""
    width, height = 3072, 2304
    rng = random.Random(seed)
    pixels = bytearray(b"\xf9\xf9\xf6\xff" * (width * height))
    def rect(x, y, w, h, color):
        row = bytes(color) * w
        for yy in range(y, min(height, y + h)):
            offset = (yy * width + x) * 4
            pixels[offset:offset + len(row)] = row
    for y in range(80, height - 80, 34):
        for x in range(70, width - 100, 14):
            pattern = rng.getrandbits(35)
            for gy in range(7):
                for gx in range(5):
                    if pattern & (1 << (gy * 5 + gx)):
                        rect(x + gx * 2, y + gy * 2, 2, 2, (35, 42, 55, 255))
    # A fixed textured illustration exposes moving-detail load that a flat checker misses.
    photo_w, photo_h, photo_x, photo_y = 1408, 1000, 850, 650
    for y in range(photo_h):
        noise = rng.randbytes(photo_w)
        row = bytearray(photo_w * 4)
        row[0::4] = noise
        row[1::4] = noise.translate(bytes((n * 3 // 4 + 35) for n in range(256)))
        row[2::4] = noise.translate(bytes((n // 2 + 60) for n in range(256)))
        row[3::4] = b"\xff" * photo_w
        offset = ((photo_y + y) * width + photo_x) * 4
        pixels[offset:offset + len(row)] = row
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value))
    raw = b"".join(b"\0" + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values, percent):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * percent / 100) - 1)]


def summarize(report, link):
    frames = report.get("frames", [])
    latency = report.get("latencies", [])
    result = dict(schema=1, analysis_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), run=report.get("run"), setup=report.get("setup"),
                  provenance=report.get("provenance"), limitations=report.get("limitations"),
                  infrastructure_errors=report.get("errors", []), phases=[], link=link)
    def counters(role, kind, before):
        samples = [s for s in report.get("stats", []) if s["role"] == role and s["t"] <= before]
        for sample in reversed(samples):
            found = [s["values"] for s in sample["stats"] if s["type"] == kind]
            if found:
                return found[0]
        return {}
    for phase in report.get("phases", []):
        start, end = phase["start"], phase["end"]
        current = [t for t in frames if start <= t < end]
        gaps = [b - a for a, b in zip(frames, frames[1:]) if start <= b < end]
        lat = [s["ms"] for s in latency if start <= s["t"] < end and s.get("source_t", start) >= start]
        received_start = counters("receiver", "inbound-rtp", start)
        received_end = counters("receiver", "inbound-rtp", end)
        sent_start = counters("sender", "outbound-rtp", start)
        sent_end = counters("sender", "outbound-rtp", end)
        def delta(key, a=received_start, b=received_end):
            if key not in a or key not in b:
                return None
            return max(0, b[key] - a[key])
        decoded = delta("framesDecoded")
        encoded = delta("framesEncoded", sent_start, sent_end)
        packets = delta("packetsSent", sent_start, sent_end)
        emitted = delta("jitterBufferEmittedCount")
        item = dict(name=phase["name"], seconds=end - start, decoded_frames=len(current),
                    fps=len(current) / (end - start), generator_fps=phase.get("submitted", 0) / (end - start), gap_p95_ms=percentile([g * 1000 for g in gaps], 95),
                    max_gap_ms=max(gaps, default=0) * 1000, capture_to_decode_p95_ms=percentile(lat, 95),
                    latency_samples=len(lat), freezes=delta("freezeCount"), freeze_seconds=delta("totalFreezesDuration"),
                    packets_lost=delta("packetsLost"))
        def mean_ms(key, denominator, a, b):
            value = delta(key, a, b)
            return value * 1000 / denominator if value is not None and denominator else None
        item["encode_mean_ms"] = mean_ms("totalEncodeTime", encoded, sent_start, sent_end)
        item["decode_mean_ms"] = mean_ms("totalDecodeTime", decoded, received_start, received_end)
        item["send_queue_mean_ms"] = mean_ms("totalPacketSendDelay", packets, sent_start, sent_end)
        item["jitter_buffer_mean_ms"] = mean_ms("jitterBufferDelay", emitted, received_start, received_end)
        windows = {}
        for event in report.get("events", []):
            if not start <= event["t"] < end:
                continue
            text = event["event"]
            match = re.search(r"(native\.capture|native\.encoder|mac\.display) windowSec=", text)
            if not match:
                continue
            for metric, count, average, maximum in re.findall(r"([\w-]+)=(\d+) avgMs=([\d.]+) maxMs=([\d.]+)", text):
                key = match[1] + "." + metric
                bucket = windows.setdefault(key, dict(count=0, weighted_ms=0.0, max_ms=0.0))
                bucket["count"] += int(count)
                bucket["weighted_ms"] += int(count) * float(average)
                bucket["max_ms"] = max(bucket["max_ms"], float(maximum))
        item["window_metrics"] = {key: dict(count=value["count"], mean_ms=value["weighted_ms"] / value["count"], max_ms=value["max_ms"])
                                  for key, value in windows.items() if value["count"]}
        minimum_fps = CRITERIA["constrained_min_fps"] if phase["name"] == "bandwidth_drop" else CRITERIA["normal_min_fps"]
        if phase["name"] in ("warmup", "idle"):
            item["performance_pass"] = None
        else:
            item["performance_pass"] = (item["fps"] >= minimum_fps and item["capture_to_decode_p95_ms"] is not None
                and item["capture_to_decode_p95_ms"] <= (CRITERIA["constrained_latency_p95_ms"] if phase["name"] == "bandwidth_drop" else CRITERIA["normal_latency_p95_ms"])
                and item["max_gap_ms"] <= CRITERIA["max_gap_ms"] and item["freeze_seconds"] is not None and item["freeze_seconds"] <= CRITERIA["max_freeze_seconds"])
        if phase["name"] in ("recovery", "resume_motion"):
            recovery = None
            for offset in range(math.ceil(end - start) - 3):
                begin = start + offset
                if all(sum(begin + w * 2 <= t < begin + (w + 1) * 2 for t in frames) >= 90 for w in range(2)):
                    recovery = offset
                    break
            item["sustained_45fps_recovery_seconds"] = recovery
            item["performance_pass"] = item["performance_pass"] and recovery is not None and recovery <= (CRITERIA["recovery_seconds"] if phase["name"] == "recovery" else CRITERIA["resume_seconds"])
        result["phases"].append(item)
    result["functional_pass"] = (not result["infrastructure_errors"] and len(result["phases"]) == len(PHASES)
        and all(p["decoded_frames"] > 0 for p in result["phases"]) and len(latency) >= CRITERIA["min_latency_samples"])
    graded = [p for p in result["phases"] if p["performance_pass"] is not None]
    last_receiver = counters("receiver", "inbound-rtp", float("inf"))
    totals = link.get("totals", {})
    result["impairment_path_verified"] = totals.get("bytes_forwarded", 0) > 0 and last_receiver.get("bytesReceived", 0) <= totals.get("bytes_forwarded", 0)
    transitions = {p["name"]: p["counts"] for p in link.get("transitions", [])}
    result["bandwidth_drop_exercised"] = transitions.get("recovery", {}).get("queue_dropped", 0) > transitions.get("bandwidth_drop", {}).get("queue_dropped", 0)
    result["comparison_valid"] = result["functional_pass"] and result["impairment_path_verified"] and result["bandwidth_drop_exercised"] and all(
        p["generator_fps"] >= CRITERIA["generator_min_fps"] for p in result["phases"] if p["name"] not in ("warmup", "idle"))
    trace = link.get("packet_trace")
    trace_counts = (trace or {}).get("totals", {})
    trace_valid = trace is None or (trace_counts.get("media_received", 0) > 0
        and not trace_counts.get("stream_overflow", 0) and not trace_counts.get("unknown_received", 0))
    result["diagnostic_valid"] = result["functional_pass"] and result["impairment_path_verified"] and trace_valid and all(
        p["generator_fps"] >= CRITERIA["generator_min_fps"] for p in result["phases"] if p["name"] not in ("warmup", "idle"))
    result["performance_pass"] = result["comparison_valid"] and bool(graded) and all(p["performance_pass"] for p in graded)
    if result.get("setup", {}) and result["setup"].get("diagnostic_profile", "standard") != "standard":
        result["comparison_valid"] = False
        result["performance_pass"] = False
    return result


def run(args):
    root = Path(__file__).resolve().parents[2]
    expected = dict(width=1920, height=1440, fps_ceiling=60, bitrate_ceiling=100000000, idle_source_fps=20)
    if PROTOCOL["settings"] != expected or PROTOCOL["link"] != dict(delay_ms=10, jitter_ms=2, loss=0, queue_ms=150):
        raise ValueError("this driver implements screen-motion-v1 settings; update driver before changing its fixed settings")
    folder = Path(tempfile.mkdtemp(prefix="touping-benchmark-", dir=args.output_parent))
    image = folder / "document.png"
    digest = document(image, args.seed)
    host = subprocess.check_output(["ipconfig", "getifaddr", "en0"], text=True).strip()
    variant = getattr(args, "diagnostic_profile", "standard")
    link = Link(host, args.seed, ordered=variant in ("ordered", "steady-ordered"))
    plan = [dict(p, mbps=20) if variant.startswith("steady") else p.copy() for p in PHASES]
    control_path, report_path = folder / "control.json", folder / "report.json"
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    patch = subprocess.check_output(["git", "diff", "HEAD", "--"], cwd=root)
    source_paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=root, text=True).splitlines()
    source_hashes = {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sorted(source_paths)
                     if (root / p).is_file() and (Path(p).suffix in (".swift", ".pbxproj", ".xcconfig", ".py", ".json") or p.endswith("Package.resolved"))}
    control = dict(schema=1, run=folder.name, host=host, ports=link.ports, sender=None, receiver=None,
                   profile=link.profile.copy(), phases=plan, diagnostic_profile=variant, image=str(image), report=str(report_path),
                   provenance=dict(protocol_sha256=hashlib.sha256(PROTOCOL_PATH.read_bytes()).hexdigest(), commit=commit, tracked_patch_sha256=hashlib.sha256(patch).hexdigest(),
                                   app_sha256=hashlib.sha256(Path(args.app).read_bytes()).hexdigest(),
                                   source_tree_sha256=hashlib.sha256(json.dumps(source_hashes, sort_keys=True).encode()).hexdigest(),
                                   source_files=source_hashes,
                                   code_files={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in Path(args.app).parent.iterdir() if p.is_file()},
                                   toolchain=subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
                                   hardware=subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
                                   chip=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(), cpu_count=os.cpu_count(),
                                   source_image_sha256=digest, seed=args.seed))
    atomic_json(control_path, control)
    log = (folder / "console.log").open("w")
    process = subprocess.Popen([args.app, "--verify-native-scenario", "--scenario-control", str(control_path), "-appMode", "cast"],
                               stdout=log, stderr=subprocess.STDOUT)
    started = time.monotonic()
    previous, last_check, phase_counts = None, 0, []
    try:
        while time.monotonic() - started < 150:
            if time.monotonic() - last_check > 0.02:
                current = json.loads(control_path.read_text())
                link.configure(current)
                if current.get("state") != "started" and time.monotonic() - started > 12:
                    raise RuntimeError(f"benchmark entry did not start; see {folder}")
                phase = current.get("phase", "negotiation")
                if phase != previous:
                    phase_counts.append(dict(name=phase, t=time.monotonic() - started, counts=link.counts.copy()))
                    previous = phase
                last_check = time.monotonic()
            link.step()
            if report_path.exists():
                report = json.loads(report_path.read_text())
                summary = summarize(report, dict(totals=link.counts, transitions=phase_counts, packet_trace=link.trace.snapshot()))
                atomic_json(folder / "summary.json", summary)
                print(json.dumps(dict(output=str(folder), functional_pass=summary["functional_pass"],
                                      performance_pass=summary["performance_pass"], comparison_valid=summary["comparison_valid"], diagnostic_valid=summary["diagnostic_valid"]), ensure_ascii=False))
                return 0 if summary["performance_pass"] else 2 if summary["comparison_valid"] or (variant != "standard" and summary["diagnostic_valid"]) else 1
            if process.poll() is not None:
                raise RuntimeError(f"benchmark app exited early ({process.returncode}); see {folder}")
        raise TimeoutError(f"benchmark exceeded 150 seconds; see {folder}")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        link.close()
        log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="Built Debug MacCaster executable, not an .app directory")
    parser.add_argument("--seed", type=int, default=PROTOCOL["seed"])
    parser.add_argument("--output-parent", default="/tmp")
    parser.add_argument("--diagnostic-profile", choices=("standard", "ordered", "steady", "steady-ordered"), default="standard",
                        help="Diagnostic 2x2: default independent jitter vs FIFO delivery; 20/4/20 vs constant 20 Mbps. Not alternative acceptance tests.")
    raise SystemExit(run(parser.parse_args()))
