"""Run on the existing server after the isolated signaling container is healthy."""
from pathlib import Path
import subprocess, time, shutil
root=Path('/home/ubuntu/touping-signal')
backups=root/'backups';backups.mkdir(exist_ok=True)
location=(root/'touping-nginx-location.conf').read_text()
def docker(*args): return subprocess.run(['sudo','-n','docker',*args],check=True,capture_output=True,text=True)
for attempt in range(10):
    try:
        health=docker('exec','touping-signaling','python','-c','import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8322/health",timeout=2).read().decode())')
        print(health.stdout.strip());break
    except subprocess.CalledProcessError:
        if attempt==9:raise
        time.sleep(1)

def insert(text):
    if 'location /touping/' in text:return text
    marker='    location /api/ {'
    if marker not in text:raise RuntimeError('Expected existing HTTPS API route missing')
    return text.replace(marker,location+marker,1)

stamp=str(int(time.time()))
files=[('/etc/nginx/conf.d/default.conf','runtime'),('/etc/nginx/templates/default.conf.template','template')]
originals=[]
for remote,name in files:
    old=backups/(name+'-'+stamp+'.conf')
    docker('cp','paike-nginx-1:'+remote,str(old))
    new=root/(name+'-next.conf');new.write_text(insert(old.read_text()))
    originals.append((remote,old,new))
try:
    for remote,old,new in originals:docker('cp',str(new),'paike-nginx-1:'+remote)
    result=docker('exec','paike-nginx-1','nginx','-t')
    print(result.stderr.strip())
    docker('exec','paike-nginx-1','nginx','-s','reload')
except Exception:
    for remote,old,new in originals:docker('cp',str(old),'paike-nginx-1:'+remote)
    raise
host_template=Path('/home/ubuntu/paike/nginx.https.conf.template')
shutil.copy2(host_template,backups/('paike-template-'+stamp+'.conf'))
host_template.write_text(insert(host_template.read_text()))
print('Pairing route added; existing business containers were not restarted.')
