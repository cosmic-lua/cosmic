#!/usr/bin/env python3
"""Temporary C3 pilot; remove together with its CI steps before merge."""
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


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command_json(argv):
    return json.loads(subprocess.check_output(argv, text=True))


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


def manifest(stdout):
    result = {}
    for line in stdout.splitlines():
        name, path = line.split('\t')
        path = Path(path)
        digest = hashlib.sha256()
        files = dirs = total = 0
        for directory, subdirs, names in os.walk(path):
            subdirs.sort()
            names.sort()
            relative = str(Path(directory).relative_to(path))
            digest.update(f'd {relative} {stat.S_IMODE(os.stat(directory).st_mode)}\n'.encode())
            dirs += 1
            for name_in_dir in names:
                item = Path(directory) / name_in_dir
                data = item.read_bytes()
                files += 1
                total += len(data)
                digest.update(f'f {item.relative_to(path)} {stat.S_IMODE(item.stat().st_mode)} {len(data)}\n'.encode())
                digest.update(hashlib.sha256(data).digest())
        result[name] = {'key': path.name, 'digest': digest.hexdigest(), 'files': files, 'dirs': dirs, 'bytes': total}
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


def measure(repo, root):
    facts, devices = storage(root)
    print('storage ' + json.dumps(facts, sort_keys=True), flush=True)
    tool = repo / 'o/bin/cosmic'
    scripts = {}
    original = (repo / 'build/patch.tl').read_text()
    for purpose in ('timing', 'diagnostic'):
        scripts[purpose] = root / f'patch-{purpose}.tl'
        scripts[purpose].write_text(make_script(original, purpose == 'diagnostic'))
    synthetic_inputs(root / 'many-small')
    (root / 'destinations').mkdir()
    metadata = {'kernel': os.uname().release, 'machine': os.uname().machine, 'storage': facts,
                'tool_sha256': sha(tool), 'script_sha256': {key: sha(path) for key, path in scripts.items()},
                'driver_sha256': sha(Path(__file__)), 'host_mounts': Path('/proc/self/mountinfo').read_text(),
                'repo_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
                'warm_input_reads': True, 'fresh_destinations': True, 'no_shared_cache_deletion': True,
                'block_io_scope': 'ambient whole-device counters around child only; excludes subsequent manifest verification; never sum partition and parent'}
    (root / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    references, timings, diagnostics = {}, [], []
    def trial(dataset, source, purpose, round_no, mode, warm=False):
        dest = root / 'destinations' / f'{purpose}-{dataset}-{round_no}-{mode}'
        env = os.environ.copy()
        env['COSMIC_PATCH_FLUSH'] = mode
        load = os.getloadavg()
        before = io_snapshot(devices)
        start = time.perf_counter_ns()
        run = subprocess.run([str(tool), '--standalone', str(scripts[purpose]), str(source), str(dest)],
                             env=env, cwd=root, text=True, capture_output=True, timeout=120)
        elapsed = time.perf_counter_ns() - start
        after = io_snapshot(devices)
        require(run.returncode == 0, f'{dataset} {mode}: {run.stderr}')
        metrics = json.loads(run.stderr.splitlines()[-1])
        if purpose == 'timing':
            require(set(metrics) == {'total_ns'}, 'pilot timing contains phase instrumentation')
        if warm:
            require(all(metrics.get(key, 0) == 0 for key in ('fsync_calls', 'syncfs_calls', 'write_mode_ns')), 'warm repeat performed writes or flushes')
        payloads = manifest(run.stdout)
        require(payloads, 'empty benchmark payload')
        references.setdefault(dataset, payloads)
        require(payloads == references[dataset], f'payload mismatch {dataset} {mode}')
        row = {'dataset': dataset, 'purpose': purpose, 'round': round_no, 'mode': mode, 'warm': warm,
               'wall_ms': elapsed / 1e6, 'load_before': load, 'load_after': os.getloadavg(),
               'metrics': metrics, 'block_io': io_delta(before, after), 'payloads_equal': True}
        with (root / f'{purpose}.jsonl').open('a') as log:
            log.write(json.dumps(row) + '\n')
        print('trial ' + json.dumps(row, sort_keys=True), flush=True)
        (timings if purpose == 'timing' else diagnostics).append(row)
    datasets = [('vendor', repo), ('many-small', root / 'many-small')]
    # All paired pilot trials finish before any instrumented diagnostic run.
    for dataset, source in datasets:
        for subtree in ('vendor', 'patch'):
            for path in (source / subtree).rglob('*'):
                if path.is_file() and not path.is_symlink():
                    path.read_bytes()
        for round_no in range(6):
            for mode in (('fsync', 'syncfs') if round_no % 2 == 0 else ('syncfs', 'fsync')):
                trial(dataset, source, 'timing', round_no, mode)
    for dataset, source in datasets:
        for mode in ('fsync', 'syncfs'):
            trial(dataset, source, 'diagnostic', 0, mode)
            trial(dataset, source, 'diagnostic', 0, mode, warm=True)
    summary = []
    for dataset, _ in datasets:
        groups = {mode: [row['metrics']['total_ns'] / 1e6 for row in timings if row['dataset'] == dataset and row['mode'] == mode] for mode in ('fsync', 'syncfs')}
        pairs = [{'round': index, 'syncfs_minus_fsync_ms': sync - per_file, 'syncfs_over_fsync': sync / per_file}
                 for index, (per_file, sync) in enumerate(zip(groups['fsync'], groups['syncfs']))]
        summary.append({'dataset': dataset, 'timing_only': True,
                        'modes': {mode: {'median_ms': statistics.median(values), 'min_ms': min(values), 'max_ms': max(values)} for mode, values in groups.items()},
                        'pairs': pairs, 'median_paired_difference_ms': statistics.median(pair['syncfs_minus_fsync_ms'] for pair in pairs)})
    (root / 'payloads.json').write_text(json.dumps(references, indent=2))
    (root / 'summary.json').write_text(json.dumps(summary, indent=2))
    print('summary ' + json.dumps(summary, sort_keys=True), flush=True)
    print('Pilot only: no optimization or physical-durability conclusion. Confirmation requires predeclared A/A calibration and A/B sampling. Timings exclude phase/call instrumentation. Block I/O includes ambient traffic.', flush=True)


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
                measure(repo, root)
            except Exception as error:
                print(f'No completed measurement: {error}', file=sys.stderr, flush=True)
                return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
