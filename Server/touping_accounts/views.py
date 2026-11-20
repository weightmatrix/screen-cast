"""Account-bound casting identity. Existing scheduling JWT authentication is authoritative."""
import re
import unicodedata
from django.db import IntegrityError, transaction
from rest_framework.views import APIView
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from apps.accounts.username_rules import is_reserved_username, normalize_for_matching
from .models import CastProfile

OCCUPIED = '已被占用'


def code_allowed(value, svip=False):
    return bool(re.fullmatch(r'[0-9]{6,36}', value)) and (svip or not re.search(r'([0-9])\1\1', value))


def profile_data(profile):
    return {'nickname': profile.nickname, 'matching_code': profile.matching_code or '',
            'membership': 'SVIP' if profile.is_svip else '普通用户',
            'relay_allowed': profile.is_svip, 'relay_configured': __import__('pathlib').Path('/run/touping-relay.json').is_file()}


class ProfileView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        profile, _ = CastProfile.objects.get_or_create(user=request.user)
        return Response(profile_data(profile))

    def patch(self, request):
        if set(request.data) != {'nickname', 'matching_code'}:
            return Response({'error': '请填写昵称和匹配码'}, status=400)
        nickname = unicodedata.normalize('NFKC', str(request.data['nickname'])).strip()
        code = str(request.data['matching_code']).strip()
        if not 1 <= len(nickname) <= 32 or any(unicodedata.category(c).startswith('C') for c in nickname):
            return Response({'error': '昵称须为1至32字'}, status=400)
        if not re.fullmatch(r'[0-9]{6,36}', code):
            return Response({'error': '匹配码须为6至36位数字'}, status=400)
        try:
            with transaction.atomic():
                profile, _ = CastProfile.objects.get_or_create(user=request.user)
                profile = CastProfile.objects.select_for_update().get(pk=profile.pk)
                key = normalize_for_matching(nickname)
                if not key or (not profile.is_svip and (is_reserved_username(nickname) or not code_allowed(code))):
                    return Response({'error': OCCUPIED}, status=409)
                if CastProfile.objects.exclude(pk=profile.pk).filter(nickname_key=key).exists() or CastProfile.objects.exclude(pk=profile.pk).filter(matching_code=code).exists():
                    return Response({'error': OCCUPIED}, status=409)
                profile.nickname, profile.nickname_key, profile.matching_code = nickname, key, code
                profile.save(update_fields=['nickname', 'nickname_key', 'matching_code', 'updated_at'])
            return Response(profile_data(profile))
        except IntegrityError:
            return Response({'error': OCCUPIED}, status=409)

class RelayView(APIView):
    """Issue short-lived TURN credentials to server-authorized SVIP senders only."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        import base64, hashlib, hmac, json, secrets, time
        from pathlib import Path
        from django.core.cache import cache
        profile = CastProfile.objects.filter(user=request.user, is_svip=True).first()
        if profile is None:
            return Response({'error': '中转仅向SVIP投屏者开放'}, status=403)
        rate = 'cast-relay:' + str(request.user.pk)
        if not cache.add(rate, 1, timeout=60):
            try: count = cache.incr(rate)
            except ValueError: count = 1
            if count > 6: return Response({'error':'中转申请过于频繁'}, status=429)
        try:
            config = json.loads(Path('/run/touping-relay.json').read_text())
            secret = config['secret']
            urls = config['urls']
            if not isinstance(secret,str) or len(secret)<32 or not isinstance(urls,list): raise ValueError()
        except (OSError, ValueError, KeyError):
            return Response({'error':'中转暂不可用'}, status=503)
        username = str(int(time.time()) + 43200) + ':' + str(request.user.pk) + ':' + secrets.token_hex(8)
        password = base64.b64encode(hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()).decode()
        return Response({'urls':urls, 'username':username, 'credential':password, 'type':'relay_config'})
