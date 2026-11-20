"""Resolve sender identity using the scheduling service, never client-supplied phone fields."""
import asyncio
import json
import re
import urllib.request

async def sender_identity(token):
    if not isinstance(token, str) or not 20 <= len(token) <= 4096 or not re.fullmatch(r'[A-Za-z0-9_.-]+', token):
        raise ValueError('Sender login required')
    def lookup():
        request = urllib.request.Request('http://paike-backend-1:8000/api/auth/me/', headers={
            'Authorization': 'Bearer ' + token, 'X-Forwarded-Proto': 'https', 'Host': 'zhibenwang.com'})
        with urllib.request.urlopen(request, timeout=5) as response:
            data = response.read(8193)
        if len(data) > 8192: raise ValueError('Account response too large')
        user = json.loads(data)
        phone, identity = user.get('phone'), user.get('id')
        if not isinstance(phone, str) or not re.fullmatch(r'[0-9]{11}', phone) or not isinstance(identity, str) or len(identity) > 64:
            raise ValueError('Account identity unavailable')
        return {'account_id': identity, 'phone': phone}
    return await asyncio.wait_for(asyncio.to_thread(lookup), timeout=6)

async def relay_authorized(token):
    """Recheck server-side entitlement; client claims never grant relay access."""
    if not isinstance(token,str) or not re.fullmatch(r'[A-Za-z0-9_.-]{20,4096}',token): return False
    def lookup():
        request=urllib.request.Request('http://touping-accounts:8000/api/touping/profile/',headers={
            'Authorization':'Bearer '+token,'X-Forwarded-Proto':'https','Host':'zhibenwang.com'})
        with urllib.request.urlopen(request,timeout=5) as response: data=response.read(8193)
        if len(data)>8192: return False
        return json.loads(data).get('relay_allowed') is True
    try: return await asyncio.wait_for(asyncio.to_thread(lookup),timeout=6)
    except Exception: return False
