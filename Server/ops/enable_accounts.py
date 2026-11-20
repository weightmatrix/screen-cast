"""Deploy casting account APIs separately; never replace the scheduling backend."""
from pathlib import Path
import json, subprocess, time
ROOT = Path('/srv/apps/touping')
def run(*args): return subprocess.check_output(args,text=True).strip()
def main():
    info=json.loads(run('docker','inspect','paike-backend-1'))[0]
    backup=ROOT/'backups'/('accounts-isolated-'+time.strftime('%Y%m%d-%H%M%S'));backup.mkdir(mode=0o700)
    run('docker','build','--build-arg','BASE_IMAGE='+info['Config']['Image'],'-t','touping-accounts:104','-f',str(ROOT/'app/touping_accounts/Dockerfile.overlay'),str(ROOT/'app'))
    secret=ROOT/'secrets/accounts.env'
    allowed={'DEBUG','DJANGO_SECRET_KEY','ALLOWED_HOSTS','SECURE_SSL_REDIRECT','SECURE_HSTS_SECONDS','MASTER_ENCRYPTION_KEY','PHONE_LOOKUP_KEY'}
    environment=[item for item in info['Config']['Env'] if item.split('=',1)[0] in allowed or item.startswith('DB_')]
    secret.write_text('\n'.join(environment)+'\n');secret.chmod(0o600)
    compose=ROOT/'ops/accounts.compose.yml'
    compose.write_text('''services:
  accounts:
    image: touping-accounts:104
    container_name: touping-accounts
    restart: unless-stopped
    env_file: [/srv/apps/touping/secrets/accounts.env]
    volumes:
      - /srv/apps/touping/secrets/relay.json:/run/touping-relay.json:ro
    command: ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "1", "--threads", "2", "--access-logfile", "/dev/null"]
    entrypoint: []
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    mem_limit: 192m
    cpus: 0.3
    pids_limit: 32
    networks: [paike]
    logging:
      driver: json-file
      options: {max-size: "1m", max-file: "2"}
networks:
  paike:
    external: true
    name: paike_default
''')
    command=['docker','compose','-p','touping-accounts','-f',str(compose)]
    run(*command,'run','--rm','--no-deps','--entrypoint','python','accounts','manage.py','test','touping_accounts','--noinput')
    run(*command,'run','--rm','--no-deps','--entrypoint','python','accounts','manage.py','migrate','touping_accounts','--noinput')
    run(*command,'up','-d','--no-deps')
    # Only add the casting URL prefix; keep every other live routing directive.
    snippet='''    # Casting accounts live in their own sandbox service.
    location ^~ /api/touping/ {
        resolver 127.0.0.11 valid=10s ipv6=off;
        set $cast_account_upstream touping-accounts:8000;
        proxy_pass http://$cast_account_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        client_max_body_size 8k;
        access_log off;
    }

'''
    (ROOT/'app/accounts-nginx-location.conf').write_text(snippet)
    nginx_info=json.loads(run('docker','inspect','paike-nginx-1'))[0]
    paths=['/etc/nginx/conf.d/default.conf','/etc/nginx/templates/default.conf.template']
    for i,path in enumerate(paths):
        old=backup/('nginx-'+str(i)+'.conf');run('docker','cp','paike-nginx-1:'+path,str(old))
        value=old.read_text()
        if 'location ^~ /api/touping/' not in value:
            value=value.replace('    location /api/ {',snippet+'    location /api/ {',1)
        new=ROOT/'ops/staging'/('accounts-nginx-'+str(i)+'.conf');new.write_text(value)
        mount=next((item for item in nginx_info['Mounts'] if item['Type']=='bind' and item['Destination']==path),None)
        if mount: Path(mount['Source']).write_text(value)
        else: run('docker','cp',str(new),'paike-nginx-1:'+path)
    run('docker','exec','paike-nginx-1','nginx','-t')
    run('docker','exec','paike-nginx-1','nginx','-s','reload')
    print('ISOLATED_ACCOUNT_SERVICE_DEPLOYED')
if __name__ == '__main__': main()
