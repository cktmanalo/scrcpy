import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import urllib.error
import urllib.request
from pathlib import Path

from . import logic
from .system import FROZEN, IS_LINUX, IS_MAC, find_resource, log, mac_bundle_path, read_json, system_name

DEFAULT_REPO = 'cktmanalo/scrcpy'
USER_AGENT = 'scrcpy-monitor'


class VersionInfo:
    def __init__(self):
        config = None
        path = find_resource('update.json')
        if path:
            config = read_json(path)
        self.repo = DEFAULT_REPO
        self.version = 'dev'
        self.display = 'dev'
        self.built = None
        self.enabled = False
        if isinstance(config, dict) and config.get('Repo') and config.get('Version'):
            self.repo = str(config['Repo'])
            self.version = str(config['Version'])
            self.display = logic.display_version(self.version)
            self.built = logic.parse_iso_datetime(config.get('Built'))
            self.enabled = True

    @property
    def can_self_update(self):
        return FROZEN and (IS_MAC or IS_LINUX)


class Worker:
    def __init__(self, target, *args):
        self.result = None
        self.error = None
        self.done = threading.Event()
        threading.Thread(target=self._run, args=(target, args), daemon=True).start()

    def _run(self, target, args):
        try:
            self.result = target(*args)
        except Exception as error:
            self.error = error
        finally:
            self.done.set()


def fetch_latest_release(repo):
    request = urllib.request.Request(f'https://api.github.com/repos/{repo}/releases/latest',
                                     headers={'User-Agent': USER_AGENT, 'Accept': 'application/vnd.github+json'})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def check_release(release, info):
    return logic.find_update(release, info.version, info.built, system_name(), platform.machine())


def install_target():
    if IS_MAC:
        return mac_bundle_path()
    if IS_LINUX and FROZEN:
        return Path(sys.executable).resolve().parent
    return None


def _download(url, destination):
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response, open(destination, 'wb') as handle:
        shutil.copyfileobj(response, handle)


def _safe_extract_tar(archive, destination):
    root = Path(destination).resolve()
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            target = (root / member.name).resolve()
            if root not in target.parents and target != root:
                raise RuntimeError(f'Unsafe path in update archive: {member.name}')
        tar.extractall(destination)


def prepare_update(url, work_dir):
    target = install_target()
    if not target:
        raise RuntimeError('This copy cannot update itself.')
    if not os.access(target.parent, os.W_OK):
        raise RuntimeError(f'No permission to replace {target}. Download the update from the release page.')
    work_dir = Path(work_dir)
    if work_dir.exists():
        shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True)
    temp = Path(tempfile.mkdtemp(prefix='scrcpy-monitor-update-'))
    archive = temp / ('update.zip' if IS_MAC else 'update.tar.gz')
    extract = temp / 'files'
    extract.mkdir()
    log(f'Update: downloading {url}')
    _download(url, archive)
    if IS_MAC:
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(extract)], check=True)
        source = next((p for p in extract.rglob('Scrcpy Monitor.app') if p.is_dir()), None)
        if not source:
            raise RuntimeError('The downloaded update does not contain Scrcpy Monitor.app.')
    else:
        _safe_extract_tar(archive, extract)
        source = next((p.parent for p in extract.rglob('scrcpy-monitor') if p.is_file()
                       and p.parent.name == 'scrcpy-monitor'), None)
        if not source:
            raise RuntimeError('The downloaded update is not a scrcpy monitor package.')
    archive.unlink()
    script = work_dir / 'apply-update.sh'
    script.write_text(_script(), encoding='utf-8')
    script.chmod(0o755)
    return {'script': str(script), 'source': str(source), 'target': str(target), 'temp': str(temp)}


def _script():
    if IS_MAC:
        install = ('/usr/bin/ditto "$source" "$target" || { rm -rf "$target"; mv "$backup" "$target"; '
                   'echo "copy failed" >> "$log"; open "$target"; exit 1; }\n'
                   '/usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null\n')
        launch = 'open "$target"\n'
    else:
        install = ('cp -a "$source" "$target" || { rm -rf "$target"; mv "$backup" "$target"; '
                   'echo "copy failed" >> "$log"; exit 1; }\n')
        launch = 'cd "$HOME" && nohup "$target/scrcpy-monitor" >/dev/null 2>&1 &\n'
    return ('#!/bin/sh\n'
            'pid="$1"; source="$2"; target="$3"; temp="$4"; log="$5"\n'
            'echo "$(date "+%Y-%m-%d %H:%M:%S") Update: waiting for process $pid" >> "$log"\n'
            'while kill -0 "$pid" 2>/dev/null; do sleep 1; done\n'
            'backup="$target.old-$$"\n'
            'mv "$target" "$backup" || { echo "Update: could not move $target" >> "$log"; exit 1; }\n'
            + install +
            'rm -rf "$backup" "$temp"\n'
            'echo "$(date "+%Y-%m-%d %H:%M:%S") Update: installed." >> "$log"\n'
            + launch)


def launch_update(prepared, log_file):
    args = ['/bin/sh', prepared['script'], str(os.getpid()), prepared['source'], prepared['target'],
            prepared['temp'], str(log_file)]
    log(f'Update: {" ".join(shlex.quote(a) for a in args)}')
    subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True)
