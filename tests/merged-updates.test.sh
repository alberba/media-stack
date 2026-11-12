#!/usr/bin/env bash
# Real Git + Docker: major rollout, role selection, App data recovery and crash journal.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export MERGED_TEST_ROOT="$REPO"
python3 -B - <<'PY'
import copy,fcntl,importlib.util,json,os,shutil,subprocess,tempfile,unittest,uuid,textwrap
from pathlib import Path
from unittest.mock import patch
ROOT=Path(os.environ['MERGED_TEST_ROOT'])
spec=importlib.util.spec_from_file_location('merged',ROOT/'scripts/merged_updates.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Planning(unittest.TestCase):
 def test_namespaces_follow_the_changed_gateway(self):
  before={'vpn':{'definition':{'image':'a'}},'arr':{'definition':{'network_mode':'service:vpn'}},'jellyfin':{'definition':{'image':'j'}}}
  after=copy.deepcopy(before);after['vpn']['definition']['image']='b'
  self.assertEqual(m.changed_services(before,after),['arr','vpn'])
 def test_apps_only_see_their_project_and_profiles(self):
  model={'services':{'seerr':{'image':'app','restart':'unless-stopped'},'worker':{'profiles':['worker'],'restart':'always'},'wire':{'image':'wire','restart':'no'}}}
  self.assertEqual(set(m.signatures(model,ROOT,set())),{'seerr'})
 def test_prereleases_and_drafts_are_not_merge_targets(self):
  self.assertEqual(m.stable_releases([{'tag_name':t,'draft':d,'prerelease':p} for t,d,p in [('v2.0.0',False,False),('v1.1.0',False,False),('v3.0.0',True,False),('v3.0.0-rc1',False,True)]]),['v1.1.0','v2.0.0'])

class Workflow(unittest.TestCase):
 def test_later_main_cannot_use_an_older_ci_success(self):
  source=(ROOT/'.github/workflows/auto-release.yml').read_text()
  gate=source.split('      - name: Require a green CI run on this commit',1)[1].split('        run: |',1)[1].split('      - name:',1)[0]
  gate=textwrap.dedent(gate)
  with tempfile.TemporaryDirectory() as d:
   folder=Path(d)
   (folder/'git').write_text('#!/bin/sh\ncase "$1" in describe) exit 1;; rev-parse) echo "$HEAD_SHA";; esac\n')
   (folder/'gh').write_text('#!/bin/sh\necho 1\n')
   (folder/'git').chmod(0o755);(folder/'gh').chmod(0o755)
   env=os.environ|{'PATH':d+':'+os.environ['PATH'],'EVENT':'workflow_run','CI_SHA':'a'*40,'HEAD_SHA':'b'*40,'GITHUB_OUTPUT':d+'/output','GITHUB_REPOSITORY':'alberba/media-stack'}
   subprocess.run(['bash','-e','-c',gate],env=env,check=True,stdout=subprocess.DEVNULL)
   self.assertIn('ready=false',(folder/'output').read_text())
   env['CI_SHA']='b'*40
   (folder/'output').write_text('')
   subprocess.run(['bash','-e','-c',gate],env=env,check=True,stdout=subprocess.DEVNULL)
   self.assertIn('ready=true',(folder/'output').read_text())

class Deployment(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.temp=tempfile.TemporaryDirectory(prefix='merged-tests-');cls.work=Path(cls.temp.name)
  cls.prefix='merged-test-'+uuid.uuid4().hex[:8]
  (cls.work/'entry.sh').write_text('''#!/bin/sh
mkdir -p /config
case "$MODE" in
old) test -f /config/data || echo original > /config/data ;;
good) echo upgraded > /config/data ;;
bad) echo corrupt > /config/data ;;
esac
exec sleep 600
''')
  (cls.work/'Dockerfile').write_text('''FROM alpine:3.24
ARG MODE
ENV MODE=$MODE
COPY entry.sh /entry.sh
RUN chmod +x /entry.sh
HEALTHCHECK --interval=1s --timeout=1s --retries=1 CMD test "$MODE" != bad
ENTRYPOINT ["/entry.sh"]
''')
  cls.images={mode:cls.prefix+':'+mode for mode in ['old','good','bad']}
  for mode,image in cls.images.items():
   subprocess.run(['docker','build','-q','--build-arg','MODE='+mode,'-t',image,str(cls.work)],check=True,stdout=subprocess.DEVNULL)
 @classmethod
 def tearDownClass(cls):
  subprocess.run(['docker','image','rm',*cls.images.values()],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  cls.temp.cleanup()
 def git(self,*args):
  return subprocess.check_output(['git',*args],cwd=self.root,text=True,stderr=subprocess.DEVNULL).strip()
 def setUp(self):
  self.root=self.work/uuid.uuid4().hex;self.root.mkdir();(self.root/'scripts').mkdir();(self.root/'env').mkdir();(self.root/'docs/releases').mkdir(parents=True)
  (self.root/'scripts/verify.sh').write_text('#!/bin/sh\nexit 0\n')
  shutil.copy(ROOT/'scripts/env_contract.py',self.root/'scripts/env_contract.py');shutil.copy(ROOT/'env/catalog.json',self.root/'env/catalog.json')
  (self.root/'.gitignore').write_text('.env\nappdata/\n')
  self.data=self.root/'appdata';(self.data/'app').mkdir(parents=True);(self.data/'other').mkdir()
  env=subprocess.check_output(['python3',str(ROOT/'scripts/env_contract.py'),'fixture'],text=True)
  env=env.replace('APPDATA_ROOT=/opt/media-stack/appdata','APPDATA_ROOT='+str(self.data))
  (self.root/'.env').write_text(env)
  self.name=self.prefix+'-'+self.root.name[:8]
  (self.root/'apps-server').mkdir()
  appsdata=self.data/'apps';(appsdata/'app').mkdir(parents=True)
  appsenv=subprocess.check_output(['python3',str(ROOT/'scripts/env_contract.py'),'fixture','--scope','apps-server'],text=True).replace('APPDATA_ROOT=/opt/media-stack-apps/appdata','APPDATA_ROOT='+str(appsdata))
  (self.root/'apps-server/.env').write_text(appsenv)
  (self.root/'apps-server/compose.yaml').write_text(json.dumps({'name':self.name+'-apps','services':{'app':{'image':self.images['old'],'restart':'unless-stopped','stop_grace_period':'1s','volumes':[str(appsdata/'app')+':/config']}}}))
  self.model={'name':self.name,'services':{name:{'image':self.images['old'],'restart':'unless-stopped','stop_grace_period':'1s','volumes':[str(self.data/name)+':/config']} for name in ['app','other']}}
  (self.root/'compose.yaml').write_text(json.dumps(self.model));self.git('init','-q','-b','main');self.git('config','user.email','test@example.invalid');self.git('config','user.name','Test');self.git('config','core.hooksPath','/dev/null');self.git('add','.');self.git('commit','-qm','initial');self.git('tag','v1.0.0')
  self.old=self.git('rev-parse','HEAD')
  self.target=copy.deepcopy(self.model)
  self.target['services']['app']['image']=self.images['good'];(self.root/'compose.yaml').write_text(json.dumps(self.target));self.git('add','.');self.git('commit','-qm','major app upgrade');self.git('tag','v2.0.0')
  self.target['services']['app']['image']=self.images['bad'];(self.root/'compose.yaml').write_text(json.dumps(self.target));self.git('add','.');self.git('commit','-qm','failed app upgrade');self.git('tag','v3.0.0');self.git('checkout','-q','v1.0.0')
  self.up=m.Deployment(self.root);self.up.timeout=10
  self.up.host.stable=.1
  m.updater.atomic_json(self.up.installed,{'release':'v1.0.0','commit':self.old})
  self.notify=patch.object(self.up,'notify');self.notify.start();self.addCleanup(self.notify.stop)
  self.scope=patch.object(m.updater,'TEMPLATE',self.root);self.scope.start();self.addCleanup(self.scope.stop)
  self.up.compose('up','-d');self.up.check(['app','other'])
  self.other=self.up.host.container('other')['Id']
  real=self.up.compose
  def fixtures(*args):
   if args and args[0]=='pull':return ''
   return real(*args)
  self.puller=patch.object(self.up,'compose',side_effect=fixtures);self.puller.start();self.addCleanup(self.puller.stop)
  self.addCleanup(lambda: real('down','--remove-orphans','--timeout','1'))
 def test_approved_major_only_recreates_affected_app(self):
  self.up.apply('v2.0.0')
  self.assertEqual(self.git('rev-parse','HEAD'),self.git('rev-parse','v2.0.0'))
  self.assertEqual((self.data/'app/data').read_text().strip(),'upgraded')
  self.assertEqual(self.up.host.container('other')['Id'],self.other)
  self.up.compose('up','-d')
  self.assertEqual(self.up.host.container('app')['Image'],self.up.host.inspect(self.images['good'])['Id'])
 def test_failed_major_restores_database_and_code(self):
  with self.assertRaises(RuntimeError):self.up.apply('v3.0.0')
  self.assertEqual(self.git('rev-parse','HEAD'),self.old)
  self.assertEqual((self.data/'app/data').read_text().strip(),'original')
  self.assertFalse(self.up.journal.exists())
  self.assertEqual(self.up.host.container('other')['Id'],self.other)
 def test_interrupted_deploy_is_recoverable_from_disk(self):
  with patch.object(self.up,'check',side_effect=KeyboardInterrupt):
   with self.assertRaises(KeyboardInterrupt):self.up.apply('v2.0.0')
  self.assertTrue(self.up.journal.exists())
  self.up.restore(json.loads(self.up.journal.read_text()))
  self.assertEqual((self.data/'app/data').read_text().strip(),'original')
  self.assertEqual(self.git('rev-parse','HEAD'),self.old)
 def test_documentation_release_does_not_restart_apps(self):
  (self.root/'docs/info.md').write_text('docs');self.git('add','.');self.git('commit','-qm','docs');self.git('tag','v1.0.1');self.git('checkout','-q','v1.0.0')
  old=self.up.host.container('app')['Id'];self.up.apply('v1.0.1')
  self.assertEqual(self.up.host.container('app')['Id'],old)
  self.assertEqual(self.up.host.container('other')['Id'],self.other)
 def test_instance_only_release_does_not_restart_apps_server(self):
  apps=m.Deployment(self.root,True);apps.timeout=10
  apps.compose('up','-d');self.addCleanup(apps.compose,'down','--remove-orphans');apps.check(['app'])
  old=apps.host.container('app')['Id']
  m.updater.atomic_json(apps.installed,{'release':'v1.0.0','commit':self.old})
  with patch.object(apps,'notify'):apps.apply('v2.0.0')
  self.assertEqual(apps.host.container('app')['Id'],old)
 def test_equivalent_image_tag_does_not_restart_apps(self):
  alias=self.images['old']+'-alias'
  subprocess.run(['docker','tag',self.images['old'],alias],check=True)
  self.addCleanup(lambda:subprocess.run(['docker','image','rm',alias],stdout=subprocess.DEVNULL))
  target=copy.deepcopy(self.model);target['services']['app']['image']=alias
  (self.root/'compose.yaml').write_text(json.dumps(target));self.git('add','.');self.git('commit','-qm','equivalent alias');self.git('tag','v1.0.1');self.git('checkout','-q','v1.0.0')
  before=self.up.host.container('app')['Id'];self.up.apply('v1.0.1')
  self.assertEqual(self.up.host.container('app')['Id'],before)
 def test_failed_download_never_stops_the_running_app(self):
  before=self.up.host.container('app')['Id']
  real=self.up.compose
  def unavailable(*args):
   if args and args[0]=='pull':raise RuntimeError('registry unavailable')
   return real(*args)
  with patch.object(self.up,'compose',side_effect=unavailable):
   with self.assertRaises(RuntimeError):self.up.apply('v2.0.0')
  self.assertEqual(self.up.host.container('app')['Id'],before)
  self.assertEqual(self.git('rev-parse','HEAD'),self.old)
 def test_configuration_change_retries_a_blocked_release(self):
  real_git=self.up.git
  def git(*args):
   return '' if args and args[0]=='fetch' else real_git(*args)
  with patch.object(self.up,'git',side_effect=git), patch.object(self.up,'releases',return_value=['v1.0.0','v2.0.0']), patch.object(self.up,'manifest',return_value={'schema':1}):
   before=self.up.host.container('app')['Id']
   with patch.object(self.up.contract,'validate',return_value=False):
    with self.assertRaises(RuntimeError):self.up.run()
   self.assertEqual(self.up.host.container('app')['Id'],before)
   self.up.run()
   self.assertEqual(self.up.host.container('app')['Id'],before)
   with (self.root/'.env').open('a') as env:env.write('OPERATOR_EXTENSION=ready\n')
   self.up.run()
   self.assertEqual(json.loads(self.up.installed.read_text())['release'],'v2.0.0')
 def test_security_cycle_lock_blocks_release_before_mutation(self):
  with (self.up.host.state/'update.lock').open('a') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX)
   with self.assertRaises(BlockingIOError):self.up.run()
  self.assertEqual(self.git('rev-parse','HEAD'),self.old)

unittest.main()
PY
