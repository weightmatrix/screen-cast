from django.conf import settings
from django.db import models

class CastProfile(models.Model):
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    nickname = models.CharField(max_length=32, blank=True, default='')
    nickname_key = models.CharField(max_length=128, unique=True, null=True, blank=True)
    matching_code = models.CharField(max_length=36, unique=True, null=True, blank=True)
    is_svip = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)
