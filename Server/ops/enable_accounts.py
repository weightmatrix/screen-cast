"""Run inside the existing casting sandbox. Extend the deployed account image only."""
from pathlib import Path
import json
import subprocess
import time

ROOT = Path('/srv/apps/touping')
def run(*args):
    return subprocess.check_output(args, text=True).strip()

def main():
    info = json.loads(run('docker','inspect','paike-backend-1'))[0]
    base = info['Config']['Image']
    files = info['Config']['Labels']['com.docker.compose.project.config_files'].split(',')
    project = info['Config']['Labels']['com.docker.compose.project.working_dir']
    backup = ROOT / 'backups' / ('accounts-' + time.strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(mode=0o700)
    # Private operational inventory, no env/credentials captured.
    (backup/'image.txt').write_text(info['Image']+'\n')
    run('docker','tag',info['Image'],'paike-backend:before-touping-accounts')
    run('docker','build','--build-arg','BASE_IMAGE='+base,'-t','paike-backend:touping-accounts102','-f',str(ROOT/'app/touping_accounts/Dockerfile.overlay'),str(ROOT/'app'))
    override = ROOT/'ops/accounts.override.yml'
    override.write_text('services:\n  backend:\n    image: paike-backend:touping-accounts102\n')
    command = ['docker','compose','--project-directory',project,'-p','paike']
    for file in files: command += ['-f',file]
    command += ['-f',str(override)]
    run(*command,'run','--rm','--no-deps','--entrypoint','python','backend','manage.py','test','touping_accounts','--noinput')
    # Migrate the additive table before switching the running backend.
    run(*command,'run','--rm','--no-deps','--entrypoint','python','backend','manage.py','migrate','touping_accounts','--noinput')
    run(*command,'up','-d','--no-deps','--no-build','backend')
    print('ACCOUNT_DEPLOYED')
if __name__ == '__main__': main()
