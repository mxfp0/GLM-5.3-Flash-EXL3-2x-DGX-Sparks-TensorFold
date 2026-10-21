import fcntl
import hashlib
import json
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

state = Path.home() / '.local/state/glm53-exl3-setup'
state.mkdir(exist_ok=True)
lock = (state / 'prepare.lock').open('a')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
image = json.loads((state / 'image-contract.json').read_text())
drafter = json.loads((state / 'drafter-manifest.json').read_text())
tag = image.get('tag', 'tensorfold-glm53:v0.6.0')
base = 'http://10.100.227.2:18764/'
hub = Path.home() / '.cache/huggingface/hub'
repo = hub / ('models--' + drafter['repo'].replace('/', '--'))
snapshot = repo / 'snapshots' / drafter['revision']
assert shutil.disk_usage(hub).free > image['size'] + sum(f['size'] for f in drafter['files']) + 5 * 1024**3
found = subprocess.run(['docker', 'image', 'inspect', tag], capture_output=True, text=True)
if found.returncode or json.loads(found.stdout)[0]['Id'] != image['id']:
    with (state / 'image-load.log').open('w') as log:
        subprocess.run(['bash', '-o', 'pipefail', '-c', 'curl --fail --silent --show-error http://10.100.227.2:18764/image.tar.zst | zstd -dc | docker load'], stdout=log, stderr=subprocess.STDOUT, check=True)
loaded = json.loads(subprocess.check_output(['docker', 'image', 'inspect', tag]))[0]
assert loaded['Id'] == image['id']
assert loaded['RootFS']['Layers'] == image['layers']
assert loaded['Config']['Labels']['tf.patches'] == image['patches']
print('Pinned image loaded and verified', flush=True)
locks = hub / '.locks' / repo.name
locks.mkdir(parents=True, exist_ok=True)
handles = []
for entry in drafter['files']:
    handle = (locks / (entry['key'] + '.lock')).open('a')
    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    handles.append(handle)
if not all((snapshot / entry['path']).is_file() for entry in drafter['files']):
    allowed = {repo.name + '/refs/main'}
    for entry in drafter['files']:
        allowed.add(repo.name + '/blobs/' + entry['key'])
        allowed.add(repo.name + '/snapshots/' + drafter['revision'] + '/' + entry['path'])
    with urllib.request.urlopen(base + 'drafter.tar', timeout=120) as stream:
        with tarfile.open(fileobj=stream, mode='r|') as archive:
            for member in archive:
                assert member.name in allowed, member.name
                archive.extract(member, path=hub, filter='data')
for entry in drafter['files']:
    path = snapshot / entry['path']
    assert path.stat().st_size == entry['size']
    digest = hashlib.sha256() if entry['lfs'] else hashlib.sha1()
    if not entry['lfs']:
        digest.update(f"blob {entry['size']}\0".encode())
    with path.open('rb') as stream:
        while block := stream.read(8 * 1024 * 1024):
            digest.update(block)
    assert digest.hexdigest() == entry['key'], str(path)
print('Pinned drafter verified', flush=True)
code = 'import torch,tensorfold; import tensorfold.cuda.server,tensorfold.families.glm5_next.cuda.engine,tensorfold.vision.glm; x=torch.arange(16,device="cuda"); assert int(x.sum())==120; print("GPU_IMPORT_SMOKE_OK")'
with (state / 'gpu-import-smoke.log').open('w') as log:
    subprocess.run(['docker', 'run', '--rm', '--gpus', 'all', '--network', 'none', '--ipc=host', tag, 'python', '-c', code], stdout=log, stderr=subprocess.STDOUT, check=True)
receipt = {'image_id': image['id'], 'image_layers_match': True, 'patches': image['patches'], 'drafter_revision': drafter['revision'], 'drafter_files_verified': len(drafter['files']), 'gpu_import_smoke': True, 'free_bytes': shutil.disk_usage(hub).free}
(state / 'prepared.json').write_text(json.dumps(receipt, indent=2))
print(json.dumps(receipt), flush=True)
