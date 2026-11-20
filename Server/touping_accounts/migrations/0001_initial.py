from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion

class Migration(migrations.Migration):
    initial = True
    dependencies = [migrations.swappable_dependency(settings.AUTH_USER_MODEL)]
    operations = [migrations.CreateModel(name='CastProfile', fields=[
        ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
        ('nickname', models.CharField(blank=True, default='', max_length=32)),
        ('nickname_key', models.CharField(blank=True, max_length=128, null=True, unique=True)),
        ('matching_code', models.CharField(blank=True, max_length=36, null=True, unique=True)),
        ('is_svip', models.BooleanField(default=False)),
        ('updated_at', models.DateTimeField(auto_now=True)),
        ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, to=settings.AUTH_USER_MODEL)),
    ])]
