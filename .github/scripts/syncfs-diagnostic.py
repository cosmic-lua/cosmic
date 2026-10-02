#!/usr/bin/env python3
"""One temporary C3 confirmation; remove together with its CI steps before merge."""
from pathlib import Path
import contextlib
import hashlib
import json
import os
import stat
import statistics
import subprocess
import sys
import time
import math
import signal
import threading
import re
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


COMMAND_DEADLINE = None


def command_text(argv, cwd=None):
    timeout = 5 if COMMAND_DEADLINE is None else min(5, COMMAND_DEADLINE - time.monotonic())
    require(timeout > 0, 'confirmation deadline reached before setup command')
    return subprocess.check_output(argv, cwd=cwd, text=True, timeout=timeout)


def command_json(argv):
    return json.loads(command_text(argv))


def flatten_devices(devices):
    result = {}
    for device in devices:
        result[device['maj:min']] = device
        result.update(flatten_devices(device.get('children', [])))
    return result


def validate_backing(mount, root_device, source_device, devices, nodes):
    """Validate collected facts, rejecting backing we cannot establish directly."""
    require(mount['fstype'] in ('ext4', 'xfs'), 'expected ext4 or xfs; other filesystems need separate backing proof')
    number = mount['maj:min']
    require(number == root_device == source_device, 'mount, destination and block-source device numbers differ')
    require(number in devices and number in nodes, 'block device absent from lsblk or sysfs')
    device = devices[number]
    node = nodes[number]
    require(device['type'] in ('disk', 'part'), 'stacked or unknown block device')
    require(node['dev'] == number, 'sysfs device number differs')
    disk_number = node['parent'] if device['type'] == 'part' else number
    require(disk_number in nodes and disk_number in devices, 'partition parent is not established')
    disk = devices[disk_number]
    require(disk['type'] == 'disk', 'backing parent is not a direct disk')
    if device['type'] == 'part':
        require(node['partition'] and device.get('pkname') == disk['name'], 'lsblk and sysfs partition parents differ')
    for current in {number, disk_number}:
        facts = nodes[current]
        require(facts['dev'] == current, 'sysfs backing device number differs')
        require(not facts['virtual'], 'virtual sysfs block device (including loop/ram/zram) is unsupported')
        require(not facts['slaves'], 'stacked backing devices are unsupported')
        require(not devices[current]['name'].startswith(('loop', 'ram', 'zram', 'nbd')), 'memory, loop or network block device is unsupported')
    require(nodes[disk_number]['device'], 'attached disk device is not established')
    return disk_number


def storage(root):
    data = command_json(['findmnt', '--json', '-T', str(root), '-o', 'FSTYPE,SOURCE,TARGET,OPTIONS,MAJ:MIN'])
    require(len(data['filesystems']) == 1, 'ambiguous destination mount')
    mount = data['filesystems'][0]
    print('mount ' + json.dumps(mount, sort_keys=True), flush=True)
    # A bind mount may append [/subdirectory] to its source name.
    source = Path(mount['source'].split('[', 1)[0])
    require(source.is_absolute() and str(source).startswith('/dev/'), 'mount has no block-device source')
    source_stat = source.stat()
    require(stat.S_ISBLK(source_stat.st_mode), 'mount source is not a block device')
    number = lambda value: f'{os.major(value)}:{os.minor(value)}'
    inventory = command_json(['lsblk', '--json', '-o', 'NAME,TYPE,MAJ:MIN,PKNAME,MODEL,TRAN,SUBSYSTEMS'])
    devices = flatten_devices(inventory['blockdevices'])
    nodes = {}
    node_paths = {}
    def collect(device_number):
        path = (Path('/sys/dev/block') / device_number).resolve(strict=True)
        parent = path.parent
        partition = (path / 'partition').exists()
        parent_number = (parent / 'dev').read_text().strip() if partition else None
        nodes[device_number] = {
            'path': str(path), 'dev': (path / 'dev').read_text().strip(),
            'partition': partition, 'parent': parent_number,
            'virtual': '/devices/virtual/' in str(path),
            'slaves': sorted(p.name for p in (path / 'slaves').iterdir()) if (path / 'slaves').exists() else [],
            'device': (path / 'device').exists(),
        }
        node_paths[device_number] = path
        if parent_number and parent_number not in nodes:
            collect(parent_number)
    collect(mount['maj:min'])
    disk = validate_backing(mount, number(root.stat().st_dev), number(source_stat.st_rdev), devices, nodes)
    return {'mount': mount, 'lsblk': inventory, 'sysfs': nodes, 'backing_disk': disk}, node_paths


STAT_FIELDS = ('reads', 'reads_merged', 'sectors_read', 'read_ms', 'writes', 'writes_merged',
               'sectors_written', 'write_ms', 'in_flight', 'io_ms', 'weighted_io_ms',
               'discards', 'discards_merged', 'sectors_discarded', 'discard_ms', 'flushes', 'flush_ms')


def io_snapshot(paths):
    return {'monotonic_ns': time.monotonic_ns(), 'devices': {
        name: [int(value) for value in (path / 'stat').read_text().split()]
        for name, path in paths.items()
    }}


def io_delta(before, after):
    result = {'before': before, 'after': after, 'devices': {}}
    for name, values in before['devices'].items():
        later = after['devices'][name]
        require(len(values) == len(later) and len(values) >= 11, 'block stat shape changed')
        deltas = {field: later[index] - values[index] for index, field in enumerate(STAT_FIELDS[:len(values)]) if field != 'in_flight'}
        result['devices'][name] = {'counter_deltas': deltas, 'nondecreasing': all(value >= 0 for value in deltas.values()),
                                   'in_flight_before': values[8], 'in_flight_after': later[8]}
    return result


def make_script(original, diagnostic):
    source = original
    def replace(old, new):
        nonlocal source
        require(source.count(old) == 1, 'patch anchor changed: ' + old)
        source = source.replace(old, new, 1)
    imports = '''local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local Json = require("cosmic.json")
local Env = require("cosmic.env")
local flush_mode = Env.get("COSMIC_PATCH_FLUSH") or "fsync"
assert(flush_mode == "fsync" or flush_mode == "syncfs")
local metrics: {string:integer} = {}'''
    if diagnostic:
        imports += '''
local function add(name: string, value: integer)
  metrics[name] = (metrics[name] or 0) + value
end
local ordinary_fsync = Fs.fsync
Fs.fsync = function(fd: integer): boolean, string
  local started = Time.monotonic_ns()
  local ok, trouble = ordinary_fsync(fd)
  add("flush_ns", Time.monotonic_ns() - started)
  add("fsync_calls", 1)
  return ok, trouble
end'''
    replace('local Fs = require("cosmic.fs")', imports)
    replace('    ok, failure = Fs.fsync(fd)', '    if flush_mode == "fsync" then ok, failure = Fs.fsync(fd) end')
    flush = '    local ok, failure = sys.syncfs(fd)'
    if diagnostic:
        flush = '    local started = Time.monotonic_ns()\n' + flush + '\n    add("flush_ns", Time.monotonic_ns() - started)\n    add("syncfs_calls", 1)'
    anchor = '  for _, dir in ipairs(dirs) do\n    local synced, sync_trouble = sync_dir(dir)'
    replace(anchor, '''  if flush_mode == "syncfs" then
    local fd, trouble = Fs.open_read(out)
    if fd == nil then return false, trouble end
''' + flush + '''
    local closed, close_trouble = Fs.close(fd)
    if not ok then return false, failure end
    if not closed then return false, close_trouble end
    return true, ""
  end
''' + anchor)
    if diagnostic:
        replace('function Patch.prepare(root: string, name: string, cache: string): string | nil, string\n  local inputs, trouble = read_inputs(root, name)', '''function Patch.prepare(root: string, name: string, cache: string): string | nil, string
  local reading = Time.monotonic_ns()
  local inputs, trouble = read_inputs(root, name)
  add("read_ns", Time.monotonic_ns() - reading)''')
        prepare = source.index('function Patch.prepare')
        prefix, source = source[:prepare], source[prepare:]
        replace('  local tree, patch_trouble = patched(inputs)', '  local patching = Time.monotonic_ns()\n  local tree, patch_trouble = patched(inputs)\n  add("patch_ns", Time.monotonic_ns() - patching)')
        replace('  local dir = cache .. "/" .. name .. "-" .. key_of(tree)', '''  local hashing = Time.monotonic_ns()
  local dir = cache .. "/" .. name .. "-" .. key_of(tree)
  add("hash_ns", Time.monotonic_ns() - hashing)
  add("files", #tree.files)
  add("directories", #tree.dirs + 1)
  for _, file in ipairs(tree.files) do add("bytes", #file.data) end''')
        replace('  local written, write_trouble = write_tree(tree, payload)', '''  local writing = Time.monotonic_ns()
  local prior_flush = metrics.flush_ns or 0
  local written, write_trouble = write_tree(tree, payload)
  add("write_mode_ns", Time.monotonic_ns() - writing - ((metrics.flush_ns or 0) - prior_flush))''')
        replace('  local moved, move_trouble = Fs.rename(payload, dir)', '  local renaming = Time.monotonic_ns()\n  local moved, move_trouble = Fs.rename(payload, dir)\n  add("rename_ns", Time.monotonic_ns() - renaming)')
        source = prefix + source
    replace('function Patch.main(argv: {integer:string}): integer\n', 'function Patch.main(argv: {integer:string}): integer\n  local started = Time.monotonic_ns()\n')
    replace('  return 0\nend\n\nreturn Patch', '''  metrics.total_ns = Time.monotonic_ns() - started
  assert(Fs.put(Fs.stderr, assert(Json.encode(metrics)) .. "\\n"))
  return 0
end

return Patch''')
    return source


def manifest(stdout, details=None):
    result = {}
    for line in stdout.splitlines():
        name, path = line.split('\t')
        path = Path(path)
        digest = hashlib.sha256()
        entries = []
        files = dirs = total = 0
        for directory, subdirs, names in os.walk(path):
            subdirs.sort()
            names.sort()
            relative = str(Path(directory).relative_to(path))
            digest.update(f'd {relative} {stat.S_IMODE(os.stat(directory).st_mode)}\n'.encode())
            entries.append({'path': relative, 'kind': 'directory', 'mode': stat.S_IMODE(os.stat(directory).st_mode)})
            dirs += 1
            for name_in_dir in names:
                item = Path(directory) / name_in_dir
                data = item.read_bytes()
                files += 1
                total += len(data)
                digest.update(f'f {item.relative_to(path)} {stat.S_IMODE(item.stat().st_mode)} {len(data)}\n'.encode())
                digest.update(hashlib.sha256(data).digest())
                entries.append({'path': str(item.relative_to(path)), 'kind': 'file', 'mode': stat.S_IMODE(item.stat().st_mode), 'length': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        result[name] = {'key': path.name, 'digest': digest.hexdigest(), 'files': files, 'dirs': dirs, 'bytes': total}
        if details is not None: details[name] = {'key': path.name, 'entries': entries}
    return result


def synthetic_inputs(root):
    vendor = root / 'vendor/small'
    vendor.mkdir(parents=True)
    (vendor / 'PIN').write_text('owned benchmark fixture\n')
    for directory in range(100):
        folder = vendor / f'd{directory:03}'
        folder.mkdir()
        for item in range(20):
            (folder / f'f{item:02}.txt').write_text(f'{directory:03}-{item:02} ' + 'x' * 56 + '\n')
    patch = root / 'patch/small'
    patch.mkdir(parents=True)
    (patch / '001.txt').write_text('file: d000/f00.txt\nnote: owned benchmark record\n--- find\n000-00 ' + 'x' * 56 + '\n--- replace\n000-00 ' + 'y' * 56 + '\n--- end\n')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# One predeclared confirmation attempt; all limits include setup and verification.
PAIRS = 30
WARMUP_PAIRS = 3
DEADLINE_SECONDS = 280
MIN_FREE_BYTES = 6 * 1024 ** 3
MIN_FREE_INODES = 750000

# Fixed read-only observer: no command, path or environment supplied by its caller.
# EOF on stdin stops it even when the unprivileged coordinator cannot signal it.
SNAPSHOT_CODE = r'''
import os, sys, json, time, select
end = time.monotonic() + 280
request = 0
while time.monotonic() < end:
    rows, races = [], []
    collected = time.monotonic()
    for entry in os.scandir('/proc'):
        if not entry.name.isdigit(): continue
        try:
            base = entry.path
            raw = open(base + '/stat').read()
            left, right = raw.index('('), raw.rindex(')')
            fields = raw[right + 2:].split()
            uid = next(line.split()[1] for line in open(base + '/status') if line.startswith('Uid:'))
            try: exe = os.readlink(base + '/exe')
            except FileNotFoundError: exe = None
            cgroup = open(base + '/cgroup').read().strip()
            after = open(base + '/stat').read()
            after_fields = after[after.rindex(')') + 2:].split()
            if fields[19] != after_fields[19]:
                races.append(int(entry.name)); continue
            rows.append({'pid': int(entry.name), 'ppid': int(fields[1]),
                         'start': int(fields[19]), 'ticks': int(fields[11]) + int(fields[12]),
                         'uid': int(uid), 'comm': raw[left + 1:right], 'exe': exe,
                         'cgroup': cgroup, 'state': fields[0]})
        except (FileNotFoundError, ProcessLookupError):
            continue
    print(json.dumps({'at': collected, 'request': request, 'races': races, 'observer': os.getpid(),
                      'hz': os.sysconf('SC_CLK_TCK'), 'rows': rows}), flush=True)
    ready, _, _ = select.select([sys.stdin], [], [], 1)
    if ready:
        command = sys.stdin.buffer.read(1)
        if not command: break
        if command != b'?': raise RuntimeError('observer accepts only snapshot request or EOF')
        request += 1
'''

# Root-owned guest services are trusted only under their expected systemd unit.
# No initial process inventory is promoted wholesale into an allowlist.
SERVICE_EXECUTABLES = {
    'systemd-journald.service': ('/usr/lib/systemd/systemd-journald', '/lib/systemd/systemd-journald'),
    'systemd-resolved.service': ('/usr/lib/systemd/systemd-resolved', '/lib/systemd/systemd-resolved'),
    'systemd-timesyncd.service': ('/usr/lib/systemd/systemd-timesyncd', '/lib/systemd/systemd-timesyncd'),
    'systemd-udevd.service': ('/usr/lib/systemd/systemd-udevd', '/lib/systemd/systemd-udevd'),
    'systemd-logind.service': ('/usr/lib/systemd/systemd-logind', '/lib/systemd/systemd-logind'),
    'dbus.service': ('/usr/bin/dbus-daemon',),
    'cron.service': ('/usr/sbin/cron',),
    'rsyslog.service': ('/usr/sbin/rsyslogd',),
    'ssh.service': ('/usr/sbin/sshd',),
    'walinuxagent.service': ('/usr/bin/python3.12', '/usr/sbin/waagent'),
    'containerd.service': ('/usr/bin/containerd', '/usr/bin/containerd-shim-runc-v2'),
    'docker.service': ('/usr/bin/dockerd',),
}
ANCESTOR_FIXED = {'/usr/bin/bash', '/bin/bash', '/usr/bin/sh', '/bin/sh', '/usr/bin/dash',
                  '/bin/dash', '/usr/bin/sudo', '/usr/lib/systemd/systemd', '/lib/systemd/systemd'}
COMPETING = {'zig', 'cc', 'gcc', 'g++', 'clang', 'clang++', 'make', 'ninja',
             'cosmic', 'cosmic-core', 'cargo', 'rustc', 'pytest', 'ctest'}


def ancestor_allowed(row):
    exe = row['exe'] or ''
    if exe in ANCESTOR_FIXED:
        return True
    # GitHub's installed worker version is recorded and held, never arbitrary /usr code.
    return (exe.startswith('/home/runner/runners/') and
            (exe.endswith('/bin/Runner.Worker') or exe.endswith('/bin/Runner.Listener') or
             exe.endswith('/externals/node24/bin/node') or exe.endswith('/externals/node20/bin/node')))



def distribution(values):
    require(len(values) >= 6, 'at least six values required')
    ordered = sorted(values)
    n = len(ordered)
    probability, cumulative, rank = 2.0 ** -n, 0.0, 1
    for k in range(n // 2 + 1):
        cumulative += probability
        if cumulative > 0.025:
            break
        rank = k + 1
        probability *= (n - k) / (k + 1)
    return {'median': statistics.median(ordered), 'p95': ordered[math.ceil(n * .95) - 1],
            'low': ordered[rank - 1], 'high': ordered[n - rank]}


def compare(calibration, samples):
    noise = [row['b'] - row['a'] for row in calibration]
    changes = [row['b'] - row['a'] for row in samples]
    aa, delta = distribution(noise), distribution(changes)
    a, b = distribution([r['a'] for r in samples]), distribution([r['b'] for r in samples])
    resolution = max(abs(aa['low']), abs(aa['high']))
    aa_deviation = distribution([abs(x - aa['median']) for x in noise])
    ab_deviation = distribution([abs(x - delta['median']) for x in changes])
    checks = {'unbiased_calibration': aa['low'] <= 0 <= aa['high'],
              'benefit_beyond_resolution': delta['high'] < -resolution,
              'dispersion': ab_deviation['low'] <= aa_deviation['high'],
              'tail': b['p95'] - a['p95'] <= resolution}
    return {'a': a, 'b': b, 'calibration': aa, 'delta': delta, 'resolution': resolution,
            'calibration_deviation': aa_deviation, 'candidate_deviation': ab_deviation,
            'tail_delta': b['p95'] - a['p95'], 'checks': checks,
            'statistical_gates_pass': all(checks.values()), 'drift_review_required': True}


def baseline_service(row):
    units = row['cgroup'].replace('\n', '/').split('/')
    if row['uid'] != 0 or not row['exe']:
        return None
    if row['pid'] == 1 and row['exe'] in ('/usr/lib/systemd/systemd', '/lib/systemd/systemd'):
        return 'init'
    for unit, executables in SERVICE_EXECUTABLES.items():
        if unit in units and row['exe'] in executables:
            return unit
    if row['exe'] in ('/usr/bin/tail', '/bin/tail'):
        for unit in units:
            if re.fullmatch(r'docker-[a-f0-9]{64}\.scope', unit):
                return unit
    return None


class Quiet:
    def __init__(self, root, owner, deadline):
        self.root, self.owner, self.deadline = root, owner, deadline
        self.error, self.latest, self.prior, self.ancestors = None, None, None, None
        self.requested, self.acknowledged = 0, -1
        self.streaks, self.aggregate_streak = {}, 0
        self.window_start, self.window_cpu = None, {}
        self.stopping = False
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(['/usr/bin/sudo', '-n', '/usr/bin/python3', '-I', '-S', '-c', SNAPSHOT_CODE],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, start_new_session=True)
        self.thread = None
        try:
            self.thread = threading.Thread(target=self.read, daemon=True)
            self.thread.start()
            until = min(deadline, time.monotonic() + 3)
            while self.latest is None and self.error is None and time.monotonic() < until:
                time.sleep(.01)
            self.check()
        except BaseException:
            self.close()
            raise

    def accept(self, snap):
        require(snap['hz'] > 0, 'invalid process accounting clock')
        require(not snap['races'], 'process PID lifetime changed during snapshot')
        rows = {r['pid']: r for r in snap['rows']}
        require(self.owner in rows, 'coordinator missing from process inventory')
        owned = {self.owner}
        while True:
            more = {r['pid'] for r in rows.values() if r['ppid'] in owned}
            if more <= owned: break
            owned |= more
        require(snap['observer'] in owned and rows[snap['observer']]['uid'] == 0,
                'privileged observer is outside owned process subtree or lost privilege')
        if self.ancestors is None:
            self.ancestors = {}
            parent = rows[self.owner]['ppid']
            while parent:
                require(parent in rows, 'CI ancestry cannot be established')
                row = rows[parent]
                require(ancestor_allowed(row),
                        'unexpected CI ancestor: ' + row['comm'])
                self.ancestors[parent] = (row['start'], row['exe'], row['uid'])
                parent = row['ppid']
        for pid, identity in self.ancestors.items():
            require(pid in rows and (rows[pid]['start'], rows[pid]['exe'], rows[pid]['uid']) == identity,
                    'CI ancestor identity changed')
        prior_rows = {r['pid']: r for r in self.prior['rows']} if self.prior else {}
        elapsed = snap['at'] - self.prior['at'] if self.prior else None
        if elapsed is not None:
            require(0 < elapsed <= 2, 'process monitor gap exceeds two seconds')
        aggregate = 0
        for pid, row in rows.items():
            if pid in owned:
                continue
            if row['exe'] is None:
                # Kernel threads form the root-owned kthreadd subtree, not userspace.
                require(row.get('state') == 'Z' or (row['uid'] == 0 and (pid == 2 or row['ppid'] == 2)),
                        'process executable identity unavailable: ' + row['comm'])
                continue
            name = Path(row['exe']).name
            require(name not in COMPETING and not name.startswith(('cosmic-', 'clang-', 'gcc-')),
                    'competing compiler/test/benchmark: ' + name)
            old = prior_rows.get(pid)
            delta = row['ticks'] - old['ticks'] if old and old['start'] == row['start'] else row['ticks']
            require(delta >= 0, 'process CPU counter went backwards')
            service = 'ci-ancestors' if pid in self.ancestors else baseline_service(row)
            allowed = service is not None
            # At entry old process CPU is historical; a new unknown process later is not.
            if self.prior is not None:
                require(allowed or delta == 0, 'unexplained active userspace process: ' + name)
                if allowed:
                    self.window_cpu[service] = self.window_cpu.get(service, 0) + delta / snap['hz']
        if self.window_start is None:
            self.window_start = snap['at']
        span = snap['at'] - self.window_start
        if span >= 1:
            for key in set(self.window_cpu) | set(self.streaks):
                seconds = self.window_cpu.get(key, 0)
                self.streaks[key] = self.streaks.get(key, 0) + 1 if seconds / span > .1 else 0
                require(self.streaks[key] < 2, 'baseline service sustained CPU activity')
            aggregate = sum(self.window_cpu.values()) / span
            self.aggregate_streak = self.aggregate_streak + 1 if aggregate > .25 else 0
            require(self.aggregate_streak < 2, 'aggregate baseline service activity')
            self.window_start, self.window_cpu = snap['at'], {}
        self.prior = snap

    def read(self):
        out = None
        try:
            try:
                out = (self.root / 'processes.jsonl').open('x')
            except Exception as error:
                self.error = str(error)
            for line in self.proc.stdout:
                # Always drain, even after a failed guard or full output filesystem.
                try:
                    if out is not None:
                        out.write(line); out.flush()
                    snap = json.loads(line)
                    with self.lock:
                        if self.error is None:
                            self.accept(snap)
                        self.acknowledged = snap['request']
                        self.latest = time.monotonic()
                except Exception as error:
                    self.error = self.error or str(error)
            if not self.stopping:
                self.error = self.error or 'process observer exited before confirmation completed'
        except Exception as error:
            self.error = self.error or str(error)
        finally:
            if out is not None:
                out.close()

    def check(self):
        require(not self.error, 'quiet-host proof failed: ' + str(self.error))
        require(self.latest is not None and time.monotonic() - self.latest <= 2,
                'process observer missing or stale')
        require(time.monotonic() < self.deadline, 'confirmation exceeded 280-second deadline')

    def capture(self):
        self.check()
        self.requested += 1
        requested = self.requested
        self.proc.stdin.write('?'); self.proc.stdin.flush()
        until = min(self.deadline, time.monotonic() + 1.5)
        while self.acknowledged < requested and not self.error and time.monotonic() < until:
            time.sleep(.001)
        self.check()
        require(self.acknowledged >= requested, 'requested process snapshot unavailable')

    def close(self):
        self.stopping = True
        if self.proc.stdin and not self.proc.stdin.closed:
            self.proc.stdin.close()
        try:
            if self.thread is None or self.thread.ident is None:
                self.proc.stdin = None
                self.proc.communicate(timeout=2)
            else:
                self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.proc.kill(); self.proc.wait(timeout=1)
        if self.thread is not None and self.thread.ident is not None:
            self.thread.join(timeout=1)
            require(not self.thread.is_alive(), 'process observer reader did not finish')
        failure = self.proc.stderr.read() if not self.proc.stderr.closed else ''
        self.proc.stdout.close(); self.proc.stderr.close()
        require(self.proc.returncode == 0, 'process observer failed: ' + failure)
        require(not self.error, 'quiet-host proof failed: ' + str(self.error))


def save_json(path, value):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.' + path.name,
                                         suffix='.partial', delete=False) as out:
            temporary = Path(out.name)
            json.dump(value, out, indent=2)
            out.flush(); os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def space(root, initial=True):
    st = os.statvfs(root)
    facts = {'free_bytes': st.f_bavail * st.f_frsize, 'free_inodes': st.f_favail}
    require(facts['free_bytes'] >= (MIN_FREE_BYTES if initial else 512 * 1024 ** 2) and
            facts['free_inodes'] >= (MIN_FREE_INODES if initial else 25000),
            'insufficient confirmation storage headroom')
    return facts


def identity(repo, tool, scripts):
    files = {str(p.relative_to(repo)): sha(p) for p in
             [tool, repo / 'build/patch.tl', repo / 'ci/cosmic-driver.pin', repo / 'bin/zig.pin',
              repo / 'build.zig', repo / 'o/targets.tsv', repo / '.github/scripts/syncfs-diagnostic.py']}
    return {'repo_head': command_text(['git', 'rev-parse', 'HEAD'], cwd=repo).strip(),
            'repo_tree': command_text(['git', 'rev-parse', 'HEAD^{tree}'], cwd=repo).strip(),
            'tracked_status': command_text(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=repo),
            'files': files, 'scripts': {purpose: sha(path) for purpose, path in scripts.items()}}


def input_manifest(root):
    entries = []
    for subtree in ('vendor', 'patch'):
        for folder, dirs, names in os.walk(root / subtree):
            dirs.sort(); names.sort()
            for path in [Path(folder)] + [Path(folder) / name for name in names] + [Path(folder) / name for name in dirs if (Path(folder) / name).is_symlink()]:
                if COMMAND_DEADLINE is not None:
                    require(time.monotonic() < COMMAND_DEADLINE, 'deadline during input manifest')
                st = path.lstat()
                entry = {'path': str(path.relative_to(root)), 'mode': stat.S_IMODE(st.st_mode)}
                if stat.S_ISLNK(st.st_mode):
                    entry.update({'kind': 'symlink', 'target': os.readlink(path)})
                elif stat.S_ISDIR(st.st_mode):
                    entry['kind'] = 'directory'
                else:
                    require(stat.S_ISREG(st.st_mode), 'unsupported input file type')
                    entry.update({'kind': 'file', 'length': st.st_size, 'sha256': sha(path)})
                entries.append(entry)
    return entries


def end_child(child):
    errors = []
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as error:
            errors.append(str(error))
    stdout = stderr = ''
    try:
        stdout, stderr = child.communicate(timeout=1)
    except (subprocess.TimeoutExpired, OSError) as error:
        errors.append(str(error))
        try:
            child.kill()
            stdout, stderr = child.communicate(timeout=1)
        except (subprocess.TimeoutExpired, OSError) as final:
            errors.append(str(final))
    return {'exit_code': child.poll(), 'stdout': stdout, 'stderr': stderr, 'cleanup_errors': errors}


def measure(repo, root, began):
    global COMMAND_DEADLINE
    deadline = began + DEADLINE_SECONDS
    COMMAND_DEADLINE = deadline
    require(os.geteuid() != 0, 'the confirmation coordinator must be unprivileged')
    def remaining():
        value = deadline - time.monotonic()
        require(value > 0, 'confirmation exceeded 280-second deadline')
        return value
    def capture(argv):
        return subprocess.check_output(argv, cwd=root, text=True, timeout=min(5, remaining()))
    facts, devices = storage(root)
    initial_space = space(root)
    tool = repo / 'o/bin/cosmic'
    scripts = {}
    original = (repo / 'build/patch.tl').read_text()
    for purpose in ('timing', 'diagnostic'):
        scripts[purpose] = root / f'patch-{purpose}.tl'
        scripts[purpose].write_text(make_script(original, purpose == 'diagnostic'))
    frozen = identity(repo, tool, scripts)
    require(not frozen['tracked_status'], 'tracked source is dirty')
    runtime_code = "local A=require('build.artifact'); local J=require('cosmic.json'); local H=require('cosmic.hash'); local S=require('cosmic.store'); local c=assert(A.trusted_core()); print(assert(J.encode({sqlite=require('cosmic.sqlite').version,core_sha256=H.hex_sha256(c.bytes),target=c.target_id,configuration=c.configuration_id,runtime_basis=S.meta('runtime_basis'),boot_hash=S.meta('boot_hash')})))"
    runtime = json.loads(capture([str(tool), '-e', runtime_code]))
    require(runtime['target'] == 1 and runtime['configuration'] == 1,
            'expected x86_64 Linux release target/configuration')
    compiler = capture([str(tool), 'sql', '--store', "SELECT key,CAST(value AS TEXT) AS identity FROM meta WHERE key IN ('compiler','compiled_by') ORDER BY key"])
    require('compiler' in compiler and 'compiled_by' in compiler, 'compiler identity missing')
    require('1\t1\trelease\tx86_64-linux-musl\tLinux\tx86_64' in (repo / 'o/targets.tsv').read_text(),
            'target record does not confirm native release')
    synthetic_inputs(root / 'many-small')
    (root / 'destinations').mkdir()
    (root / 'manifests').mkdir()
    datasets = [('vendor', repo), ('many-small', root / 'many-small')]
    inputs = {name: input_manifest(source) for name, source in datasets}
    save_json(root / 'inputs.json', inputs)
    metadata = {'protocol': 'c3-confirmation-one-attempt-v1', 'pairs': PAIRS,
                'warmup_pairs': WARMUP_PAIRS, 'deadline_seconds': DEADLINE_SECONDS,
                'step_cap_seconds': 300, 'initial_space': initial_space,
                'kernel': os.uname().release, 'machine': os.uname().machine,
                'storage': facts, 'identity': frozen, 'runtime': runtime,
                'compiler': compiler, 'bootstrap_pin': (repo / 'ci/cosmic-driver.pin').read_text(),
                'zig_pin': (repo / 'bin/zig.pin').read_text(),
                'targets': (repo / 'o/targets.tsv').read_text(),
                'mountinfo': Path('/proc/self/mountinfo').read_text(),
                'cpuinfo': Path('/proc/cpuinfo').read_text(),
                'observer_code_sha256': hashlib.sha256(SNAPSHOT_CODE.encode()).hexdigest(),
                'observer_python_sha256': sha(Path('/usr/bin/python3')),
                'observer_sudo_sha256': sha(Path('/usr/bin/sudo')),
                'service_executables': SERVICE_EXECUTABLES,
                'clock_ticks': os.sysconf('SC_CLK_TCK'),
                'timing_scope': 'entrypoint only; common coordinator monitoring is not subtracted',
                'io_scope': 'ambient whole-device counters; never sum disk and partition',
                'durability_claim': False}
    save_json(root / 'metadata.json', metadata)
    quiet = Quiet(root, os.getpid(), deadline)
    timings, diagnostics, references = [], [], {}
    sequence = 0
    try:
        def checkpoint():
            remaining(); quiet.capture()
            require(identity(repo, tool, scripts) == frozen, 'immutable identity changed')
            current, _ = storage(root)
            require(current == facts, 'storage identity or mount changed')
            require({name: input_manifest(source) for name, source in datasets} == inputs, 'input tree identity changed')
            headroom = space(root, initial=False)
            with (root / 'checkpoints.jsonl').open('a') as out:
                out.write(json.dumps({'at': time.monotonic(), 'identity_unchanged': True, 'storage_unchanged': True, 'inputs_unchanged': True, 'headroom': headroom}) + '\n')
                out.flush(); os.fsync(out.fileno())
            remaining(); quiet.check()
        def trial(dataset, source, phase, pair, label, mode, warmup=False, warm=False):
            nonlocal sequence
            sequence += 1
            purpose = 'diagnostic' if phase == 'diagnostic' else 'timing'
            dest = root / 'destinations' / f'{phase}-{dataset}-{pair}-{label}'
            attempt = {'sequence': sequence, 'dataset': dataset, 'phase': phase,
                       'pair': pair, 'label': label, 'mode': mode, 'warmup': warmup,
                       'warm': warm, 'destination': str(dest), 'state': 'started'}
            attempt_path = root / f'attempt-{sequence:03}.json'
            save_json(attempt_path, attempt)
            child = None
            try:
                remaining(); quiet.capture()
                before = io_snapshot(devices)
                load = os.getloadavg()
                env = os.environ.copy(); env['COSMIC_PATCH_FLUSH'] = mode
                started = time.perf_counter_ns()
                child = subprocess.Popen([str(tool), '--standalone', str(scripts[purpose]), str(source), str(dest)],
                                         env=env, cwd=root, text=True, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, start_new_session=True)
                while True:
                    quiet.check()
                    try:
                        stdout, stderr = child.communicate(timeout=min(.1, remaining()))
                        break
                    except subprocess.TimeoutExpired:
                        pass
                elapsed = time.perf_counter_ns() - started
                after = io_snapshot(devices)
                attempt.update({'exit_code': child.returncode, 'stdout': stdout, 'stderr': stderr,
                                'wall_ms': elapsed / 1e6, 'load_before': load,
                                'load_after': os.getloadavg(), 'block_io': io_delta(before, after)})
                save_json(attempt_path, attempt)
                require(all(row['nondecreasing'] for row in attempt['block_io']['devices'].values()), 'block I/O counters decreased')
                require(child.returncode == 0, 'benchmark child failed')
                quiet.capture(); remaining()
                metrics = json.loads(stderr.splitlines()[-1])
                if purpose == 'timing':
                    require(set(metrics) == {'total_ns'}, 'timing child contains instrumentation')
                if warm:
                    require(all(metrics.get(k, 0) == 0 for k in ('fsync_calls', 'syncfs_calls', 'write_mode_ns')),
                            'warm diagnostic performed writes or flushes')
                details = {}
                payloads = manifest(stdout, details)
                save_json(root / 'manifests' / f'{sequence:03}.json', details)
                require(payloads, 'empty benchmark payload')
                references.setdefault(dataset, payloads)
                require(payloads == references[dataset], 'payload equality failed')
                quiet.check(); remaining()
                attempt.update({'state': 'complete', 'metrics': metrics, 'payloads': payloads,
                                'payloads_equal': True, 'manifest': f'manifests/{sequence:03}.json'})
                save_json(attempt_path, attempt)
                with (root / f'{purpose}.jsonl').open('a') as out:
                    out.write(json.dumps(attempt) + '\n'); out.flush(); os.fsync(out.fileno())
                (timings if purpose == 'timing' else diagnostics).append(attempt)
            except BaseException as error:
                attempt.update({'state': 'failed', 'error': str(error)})
                try:
                    if child is not None:
                        attempt.update(end_child(child))
                except BaseException as cleanup:
                    attempt['cleanup_error'] = str(cleanup)
                finally:
                    save_json(attempt_path, attempt)
                raise
        for dataset, source in datasets:
            for subtree in ('vendor', 'patch'):
                for path in (source / subtree).rglob('*'):
                    if path.is_file() and not path.is_symlink():
                        path.read_bytes(); remaining()
            for phase in ('aa', 'ab'):
                checkpoint()
                for pair in range(PAIRS + WARMUP_PAIRS):
                    labels = ('a', 'b') if pair % 2 == 0 else ('b', 'a')
                    for label in labels:
                        mode = 'syncfs' if phase == 'ab' and label == 'b' else 'fsync'
                        trial(dataset, source, phase, pair, label, mode, warmup=pair < WARMUP_PAIRS)
                checkpoint()
        for dataset, source in datasets:
            for mode in ('fsync', 'syncfs'):
                trial(dataset, source, 'diagnostic', 0, mode, mode)
                trial(dataset, source, 'diagnostic', 0, mode, mode, warm=True)
        checkpoint()
        require(len(timings) == 264 and len(diagnostics) == 8, 'incomplete fixed sample count')
        report = []
        for dataset, _ in datasets:
            groups = {}
            for phase in ('aa', 'ab'):
                rows = [r for r in timings if r['dataset'] == dataset and r['phase'] == phase and not r['warmup']]
                require(len(rows) == 60, 'incomplete phase')
                pairs = []
                for n in range(WARMUP_PAIRS, PAIRS + WARMUP_PAIRS):
                    found = {r['label']: r['metrics']['total_ns'] / 1e6 for r in rows if r['pair'] == n}
                    require(set(found) == {'a', 'b'}, 'incomplete pair')
                    pairs.append(found)
                groups[phase] = pairs
            report.append({'dataset': dataset, 'reading': compare(groups['aa'], groups['ab']),
                           'chronological_pairs': groups})
        save_json(root / 'payloads.json', references)
        save_json(root / 'summary.json', report)
        quiet.check()
        result = {'complete': True, 'statistical_gates_pass': all(r['reading']['statistical_gates_pass'] for r in report),
                  'independent_drift_and_scope_review_required': True}
    finally:
        quiet.close()
    remaining()
    result['elapsed_seconds'] = time.monotonic() - began
    return result


class Tee:
    def __init__(self, stream, log):
        self.stream, self.log = stream, log
    def write(self, data):
        self.stream.write(data)
        self.log.write(data)
        return len(data)
    def flush(self):
        self.stream.flush()
        self.log.flush()


def main(argv):
    began = time.monotonic()
    require(len(argv) == 3, 'usage: syncfs-diagnostic.py REPO NEW_OUTPUT_DIRECTORY')
    repo = Path(argv[1]).resolve(strict=True)
    requested = Path(argv[2]).absolute()
    # Resolve only the parent: an existing final symlink must also refuse reuse.
    root = requested.parent.resolve(strict=True) / requested.name
    root.mkdir(mode=0o700)
    with (root / 'driver.log').open('x') as log:
        # The upload step must not upload an old output after mkdir refuses reuse.
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as outputs:
                outputs.write('output_created=true\n')
        with contextlib.redirect_stdout(Tee(sys.stdout, log)), contextlib.redirect_stderr(Tee(sys.stderr, log)):
            try:
                result = measure(repo, root, began)
                save_json(root / 'completion.json', result)
                require(time.monotonic() - began < DEADLINE_SECONDS, 'deadline during finalization')
                print(json.dumps(result), flush=True)
                if not result['statistical_gates_pass']: return 1
            except BaseException as error:
                save_json(root / 'completion.json', {'complete': False, 'error': str(error), 'elapsed_seconds': time.monotonic() - began})
                print(f'No completed measurement: {error}', file=sys.stderr, flush=True)
                return 1
    return 0


if __name__ == '__main__':
    def cancelled(signum, frame):
        raise InterruptedError('confirmation cancelled by signal ' + str(signum))
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    sys.exit(main(sys.argv))
