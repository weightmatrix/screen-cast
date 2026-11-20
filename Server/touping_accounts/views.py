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
            'relay_allowed': profile.is_svip, 'relay_configured': False}


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
