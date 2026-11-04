"""Run against the synthetic WebReceiverHarness, never against a user's live sender."""
import json
import sys
import time
import urllib.request
import urllib.error

ROOT = sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:20319'
assert ROOT.startswith('http://') and ROOT.endswith(':20319'), 'Use only the synthetic harness port'


def request(path, body=None, origin=ROOT, host=None):
    headers = {'Origin': origin, 'Content-Type': 'application/json'}
    if host: headers['Host'] = host
    data = json.dumps(body).encode() if body is not None else None
    try:
        response = urllib.request.urlopen(urllib.request.Request(ROOT + path, data=data, headers=headers), timeout=5)
    except urllib.error.HTTPError as error: response = error
    with response:
        raw = response.read()
        return response.status, response.headers, json.loads(raw) if response.headers.get_content_type() == 'application/json' else raw


status, headers, body = request('/')
assert status == 200 and headers['Cache-Control'] == 'no-store' and b'playsinline' in body
assert request('/join', {'code': '61328407'}, origin='http://untrusted.invalid')[0] == 403
assert request('/join', {'code': '61328407'}, host='untrusted.invalid:20319')[0] == 403
assert request('/join', {'code': '00000000'})[0] == 403
assert request('/poll', {'id': 'unknown'})[0] == 404
ids = []
try:
    for _ in range(5):
        status, _, value = request('/join', {'code': '61328407'})
        if status == 409: break
        assert status == 200
        ids.append(value['id'])
    assert 1 <= len(ids) <= 4 and status == 409
    for _ in range(20):
        _, _, value = request('/poll', {'id': ids[0]})
        if any(packet['type'] == 'offer' and 'H264/90000' in packet['sdp'] for packet in value['events']): break
        time.sleep(.05)
    else: raise AssertionError('No native H264 offer')
finally:
    for identifier in ids: assert request('/leave', {'id': identifier})[0] == 200
assert request('/poll', {'id': ids[0]})[0] == 404
print('PASS LAN assets, origin/host/code rejection, native H264 offer, capacity and peer cleanup')
