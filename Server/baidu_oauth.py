"""Bounded OAuth credential exchange only. Never accepts file or media data."""
import asyncio
import json
import os
import re
import secrets
import time
import urllib.parse
import urllib.request
from pathlib import Path

CALLBACK = 'https://zhibenwang.com/touping/baidu/callback'
SESSIONS = {}
BUSY = 0


def configuration():
    try:
        value = json.loads(Path(os.environ.get('BAIDU_OAUTH_CONFIG', '/run/baidu-oauth.json')).read_text())
        if not all(isinstance(value.get(k), str) and 8 <= len(value[k]) <= 256 for k in ('client_id', 'client_secret')):
            raise ValueError()
        return value
    except (OSError, ValueError):
        return None


def exchange_token(parameters, config):
    parameters.update(client_id=config['client_id'], client_secret=config['client_secret'])
    # POST keeps credentials out of request URLs and intermediary access logs.
    request = urllib.request.Request('https://openapi.baidu.com/oauth/2.0/token',
        data=urllib.parse.urlencode(parameters).encode(), headers={'Content-Type': 'application/x-www-form-urlencoded'})
    with urllib.request.urlopen(request, timeout=12) as response:
        raw = response.read(16385)
    if len(raw) > 16384:
        raise ValueError()
    result = json.loads(raw)
    if not isinstance(result.get('access_token'), str) or not 8 <= len(result['access_token']) <= 4096:
        raise ValueError()
    return {key: result[key] for key in ('access_token', 'refresh_token', 'expires_in', 'scope') if key in result}


def response(status, payload, location=None):
    body = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()
    headers = {'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
        'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'"}
    if location:
        headers['Location'] = location
    return status, headers, body


async def handle(method, target, payload, token_exchange=None):
    global BUSY
    route = urllib.parse.urlsplit(target)
    now = time.monotonic()
    for state in list(SESSIONS):
        if SESSIONS[state]['expires'] <= now:
            SESSIONS.pop(state, None)
    config = configuration()
    if route.path == '/baidu/callback' and not route.query:
        return response(200, {'message': '请从李知本·投屏的设置开始百度网盘授权', 'callback': CALLBACK})
    if method == 'GET' and route.path == '/baidu/status':
        return response(200, {'configured': config is not None, 'callback': CALLBACK, 'mediaRelay': False})
    if config is None:
        return response(503, {'error': '百度网盘授权尚未配置'})
    if route.path == '/baidu/callback' and method == 'GET':
        query = urllib.parse.parse_qs(route.query, max_num_fields=12)
        state = query.get('state', [''])[0]
        pending = SESSIONS.get(state)
        code = query.get('code', [''])[0]
        if pending is None or pending.get('code') or not re.fullmatch(r'[A-Za-z0-9_.~-]{1,2048}', code):
            return response(400, {'error': '授权已过期或未获同意，请回到App重试'})
        pending['code'] = code
        return response(302, {'message': '请返回App完成授权'}, 'touping-baidu://oauth?state=' + state)
    if method != 'POST' or not isinstance(payload, dict):
        return response(405, {'error': '仅接受有界授权请求'})
    if route.path == '/baidu/start':
        if set(payload) - {'qr'} or len(SESSIONS) >= 64:
            return response(429, {'error': '授权繁忙，请稍后重试'})
        state, claim = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        SESSIONS[state] = {'claim': claim, 'expires': now + 300}
        query = urllib.parse.urlencode({'response_type': 'code', 'client_id': config['client_id'],
            'redirect_uri': CALLBACK, 'scope': 'basic,netdisk', 'display': 'tv' if payload.get('qr') is True else 'page', 'qrcode': '1', 'qrloginfrom': 'pc', 'state': state})
        return response(200, {'state': state, 'claim': claim,
            'authorize_url': 'https://openapi.baidu.com/oauth/2.0/authorize?' + query})
    if BUSY >= 4:
        return response(429, {'error': '授权繁忙，请稍后重试'})
    if route.path == '/baidu/complete':
        state, claim = payload.get('state'), payload.get('claim')
        if not isinstance(state, str) or not isinstance(claim, str) or set(payload) != {'state', 'claim'}:
            return response(400, {'error': '授权请求无效'})
        pending = SESSIONS.get(state)
        if pending is None or not secrets.compare_digest(pending['claim'], claim) or not pending.get('code'):
            return response(400, {'error': '授权尚未完成或已过期'})
        SESSIONS.pop(state)
        parameters = {'grant_type': 'authorization_code', 'code': pending['code'], 'redirect_uri': CALLBACK}
    elif route.path == '/baidu/refresh':
        token = payload.get('refresh_token')
        if set(payload) != {'refresh_token'} or not isinstance(token, str) or not 8 <= len(token) <= 4096 or any(ord(c) < 32 for c in token):
            return response(400, {'error': '授权续期请求无效'})
        parameters = {'grant_type': 'refresh_token', 'refresh_token': token}
    else:
        return response(404, {'error': '未知授权接口'})
    BUSY += 1
    try:
        result = await asyncio.to_thread(token_exchange or exchange_token, parameters, config)
        return response(200, result)
    except Exception:
        # Do not include provider URLs, codes, credentials, or exception messages in logs/responses.
        return response(502, {'error': '百度授权交换失败，请重新登录或稍后重试'})
    finally:
        BUSY -= 1
