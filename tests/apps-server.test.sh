#!/usr/bin/env bash
# Check the separate project and relay against Compose's actual merge semantics.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export APPS_TEST_REPO="$REPO"
python3 -B - <<'PY'
import json,os,subprocess,tempfile,time,uuid
from pathlib import Path
root=Path(os.environ['APPS_TEST_REPO'])
def command(*args,env=None):
 return subprocess.check_output(args,cwd=root,env=env,text=True)
with tempfile.TemporaryDirectory() as d:
 envfile=Path(d)/'.env'
 envfile.write_text(command('python3','scripts/env_contract.py','fixture','--scope','apps-server'))
 subprocess.run(['python3','scripts/env_contract.py','validate','--scope','apps-server','--file',str(envfile)],cwd=root,check=True)
 model=json.loads(command('docker','compose','--env-file',str(envfile),'-f','apps-server/compose.yaml','config','--format','json'))
 assert set(model['services'])=={'seerr','wud','security-monitor'}
 assert not any(s.get('profiles') for s in model['services'].values())
 assert model['services']['seerr']['ports'][0]['host_ip']=='127.0.0.1'
 assert model['services']['wud']['ports'][0]['host_ip']=='127.0.0.1'
 assert model['services']['security-monitor']['build']['context']==str(root/'stacks/monitoring/security-monitor')
 assert not model['networks']['media'].get('external')
 envfile.write_text(command('python3','scripts/env_contract.py','fixture'))
 env=os.environ|{'SEERR_REMOTE_URL':'http://192.0.2.10:5055'}
 relay=json.loads(command('docker','compose','--env-file',str(envfile),'-f','compose.yaml','-f','compose.seerr-remote.yaml','config','--format','json',env=env))['services']['seerr']
 assert relay['image'].startswith('nginx:')
 assert relay['environment']=={'SEERR_REMOTE_URL':'http://192.0.2.10:5055','NGINX_ENVSUBST_FILTER':'SEERR_REMOTE_URL'}
 assert len(relay['volumes'])==1 and relay['volumes'][0]['read_only']
 assert relay['volumes'][0]['target']=='/etc/nginx/templates/default.conf.template'
 assert relay['ports'][0]['target']==5055
 print('Apps server and remote relay Compose contracts passed')
 # Exercise envsubst and forwarding against a real upstream, isolated from production.
 prefix='apps-relay-test-'+uuid.uuid4().hex[:10]
 backend=Path(d)/'backend.conf'
 backend.write_text('events {} http { server { listen 80; location / { return 200 "remote-seerr"; } } }')
 image=relay['image']
 subprocess.run(['docker','pull',image],check=True,stdout=subprocess.DEVNULL)
 subprocess.run(['docker','network','create',prefix],check=True,stdout=subprocess.DEVNULL)
 try:
  subprocess.run(['docker','run','-d','--name',prefix+'-upstream','--network',prefix,
   '-v',str(backend)+':/etc/nginx/nginx.conf:ro',image],check=True,stdout=subprocess.DEVNULL)
  subprocess.run(['docker','run','-d','--name',prefix+'-relay','--network',prefix,
   '-e','SEERR_REMOTE_URL=http://'+prefix+'-upstream',
   '-e','NGINX_ENVSUBST_FILTER=SEERR_REMOTE_URL',
   '-v',str(root/'stacks/seerr/remote.conf.template')+':/etc/nginx/templates/default.conf.template:ro',image],check=True,stdout=subprocess.DEVNULL)
  for attempt in range(20):
   r=subprocess.run(['docker','exec',prefix+'-relay','wget','-qO-','http://127.0.0.1:5055/api/v1/status'],capture_output=True,text=True)
   if r.returncode==0:
    assert r.stdout=='remote-seerr';break
   time.sleep(.5)
  else: raise AssertionError('Relay failed to reach its upstream')
  print('Real nginx relay forwarded successfully')
 finally:
  subprocess.run(['docker','rm','-f',prefix+'-relay',prefix+'-upstream'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  subprocess.run(['docker','network','rm',prefix],stdout=subprocess.DEVNULL)

PY
