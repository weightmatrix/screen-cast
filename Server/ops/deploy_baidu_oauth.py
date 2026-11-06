"""Run with sudo in the existing /srv/apps/touping sandbox. No credentials in source."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time
import urllib.request

sandbox = Path('/srv/apps/touping')
stage = sandbox / 'ops/staging/release79'
app = sandbox / 'app'
backup = sandbox / 'backups/before79-baidu'

def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout

def docker(*args):
    return command('docker', *args)


def install(source, target):
    temporary = target.with_name(target.name + '.next79')
    shutil.copyfile(source, temporary); os.chmod(temporary, 0o644); os.replace(temporary, target)


def verify():
    with urllib.request.urlopen('https://zhibenwang.com/touping/health', timeout=15) as response:
        assert json.load(response)['mediaRelay'] is False
    with urllib.request.urlopen('https://zhibenwang.com/touping/baidu/status', timeout=15) as response:
        assert json.load(response)['configured'] is True
    with urllib.request.urlopen('https://zhibenwang.com/touping/baidu/callback', timeout=15) as response:
        assert response.status == 200
    for name in ['receiver.html', 'receiver.js', 'receiver-room.js', 'privacy.html', 'support.html']:
        route = '' if name == 'receiver.html' else name
        with urllib.request.urlopen('https://zhibenwang.com/touping/' + route, timeout=15) as response:
            assert hashlib.sha256(response.read()).digest() == hashlib.sha256((stage / 'Web' / name).read_bytes()).digest()


def main():
    assert os.geteuid() == 0
    # Provisioning is separate; this program never prints or copies private client credentials into backups/logs.
    config = json.loads((sandbox / 'secrets/baidu-oauth.json').read_text())
    assert set(config) == {'client_id', 'client_secret'}
    backup.mkdir(mode=0o700)
    files = ['signaling.py', 'baidu_oauth.py', 'Dockerfile']
    original = {}
    for name in files:
        original[name] = (app / name).exists()
        if original[name]: shutil.copy2(app / name, backup / name)
    shutil.copytree(app / 'Web', backup / 'Web')
    override = sandbox / 'ops/baidu-oauth.override.yml'
    had_override = override.exists()
    if had_override: shutil.copy2(override, backup / 'override.yml')
    image = json.loads(docker('inspect', 'touping-signaling'))[0]
    image_name = image['Config']['Image']; image_id = image['Image']
    docker('tag', image_id, 'touping-signaling:before79-baidu')
    nginx = [('/etc/nginx/conf.d/default.conf', 'nginx-runtime.conf'), ('/etc/nginx/templates/default.conf.template', 'nginx-template.conf')]
    for remote, name in nginx: docker('cp', 'paike-nginx-1:' + remote, str(backup / name))
    # Existing parent app's deploy template is also kept consistent, without running its deployment.
    host_template = Path('/home/ubuntu/paike/nginx.https.conf.template')
    if host_template.exists(): shutil.copy2(host_template, backup / 'nginx-host-template.conf')
    snippet = '''    # Touping Baidu OAuth: no access/query logs and no media/file endpoint.
    location ^~ /touping/baidu/ {
        access_log off;
        error_log /dev/null crit;
        resolver 127.0.0.11 valid=30s ipv6=off;
        set $touping_oauth_upstream touping-signaling:8322;
        rewrite ^/touping/(.*)$ /$1 break;
        proxy_pass http://$touping_oauth_upstream;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP $remote_addr;
        client_max_body_size 8k;
        proxy_read_timeout 25s;
        proxy_send_timeout 10s;
    }

'''
    def patch(text):
        if 'location ^~ /touping/baidu/' in text: return text
        assert '    location /touping/' in text
        return text.replace('    location /touping/', snippet + '    location /touping/', 1)
    compose = ('compose', '-p', 'touping', '-f', str(app / 'compose.yml'), '-f', str(override))
    try:
        for name in files: install(stage / name, app / name)
        for source in (stage / 'Web').iterdir():
            assert source.name in {'receiver.html','receiver.js','receiver-room.js','receiver-auth.js','receiver-i18n.js','privacy.html','support.html'}
            install(source, app / 'Web' / source.name)
        install(stage / 'baidu-oauth.override.example.yml', override)
        # Disable callback query logging before enabling OAuth in the rebuilt pairing container.
        for remote, name in nginx:
            candidate = stage / (name + '.next'); candidate.write_text(patch((backup / name).read_text()))
            docker('cp', str(candidate), 'paike-nginx-1:' + remote)
        docker('exec', 'paike-nginx-1', 'nginx', '-t'); docker('exec', 'paike-nginx-1', 'nginx', '-s', 'reload')
        if host_template.exists(): host_template.write_text(patch((backup / 'nginx-host-template.conf').read_text()))
        docker(*compose, 'up', '-d', '--build', '--no-deps', 'signaling')
        for attempt in range(15):
            try: verify(); break
            except Exception:
                if attempt == 14: raise
                time.sleep(1)
        (backup / 'release.json').write_text(json.dumps({'release':79,'image_before':image_id,'callback':'https://zhibenwang.com/touping/baidu/callback','result':'published'}))
        print('PASS release79: OAuth configured, callback 200, no media relay, static resources match; rollback=' + str(backup))
    except Exception:
        for name in files:
            if original[name]: install(backup / name, app / name)
            elif (app / name).exists(): (app / name).unlink()
        for source in (backup / 'Web').iterdir(): install(source, app / 'Web' / source.name)
        docker('tag', image_id, image_name)
        if had_override:
            install(backup / 'override.yml', override)
            docker(*compose, 'up', '-d', '--no-build', '--no-deps', 'signaling')
        else:
            docker('compose', '-p', 'touping', '-f', str(app / 'compose.yml'), 'up', '-d', '--no-build', '--no-deps', 'signaling')
            if override.exists(): override.unlink()
        for remote, name in nginx: docker('cp', str(backup / name), 'paike-nginx-1:' + remote)
        docker('exec', 'paike-nginx-1', 'nginx', '-t'); docker('exec', 'paike-nginx-1', 'nginx', '-s', 'reload')
        if host_template.exists(): shutil.copy2(backup / 'nginx-host-template.conf', host_template)
        print('Release79 failed; previous image, sources and Nginx restored. Private credentials retained only in secrets.')
        raise

if __name__ == '__main__': main()
