"""Provision coturn entirely in the casting sandbox; no account credentials in source."""
import json, os, secrets, subprocess
from pathlib import Path
ROOT = Path('/srv/apps/touping')
def run(*args): return subprocess.check_output(args,text=True)
def main():
    private = ROOT/'secrets'; private.mkdir(mode=0o700,exist_ok=True)
    config = private/'relay.json'
    if not config.exists():
        config.write_text(json.dumps({'secret':secrets.token_hex(32),'urls':['turn:49.233.174.254:3479?transport=udp','turn:49.233.174.254:3479?transport=tcp']})); config.chmod(0o600)
    secret = json.loads(config.read_text())['secret']
    path = private/'turnserver.conf'
    path.write_text('''listening-port=3479
listening-ip=10.2.0.5
relay-ip=10.2.0.5
external-ip=49.233.174.254/10.2.0.5
min-port=49160
max-port=49200
realm=touping.zhibenwang.com
fingerprint
use-auth-secret
static-auth-secret='''+secret+'''
user-quota=8
total-quota=16
max-bps=450000
bps-capacity=7200000
no-cli
no-tls
no-dtls
no-multicast-peers
no-loopback-peers
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
log-file=stdout
simple-log
no-software-attribute
'''); path.chmod(0o644)
    compose=ROOT/'ops/turn.compose.yml'
    compose.write_text('''services:
  turn:
    image: coturn/coturn@sha256:ccdbc51e6f072130b0fc9eebda21f8d026d0a25581746c52557e887818011a3f
    container_name: touping-turn
    network_mode: host
    user: "65534:65534"
    restart: unless-stopped
    read_only: true
    command: ["-c", "/etc/coturn/turnserver.conf", "--pidfile", "/run/turnserver.pid"]
    volumes:
      - /srv/apps/touping/secrets/turnserver.conf:/etc/coturn/turnserver.conf:ro
    tmpfs:
      - /run:uid=65534,gid=65534,mode=0700
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: [no-new-privileges:true]
    mem_limit: 128m
    cpus: 0.5
    pids_limit: 64
    logging:
      driver: json-file
      options: {max-size: "1m", max-file: "2"}
''')
    run('docker','compose','-p','touping-turn','-f',str(compose),'up','-d','--force-recreate')
    print('TURN_STARTED')
if __name__ == '__main__': main()
