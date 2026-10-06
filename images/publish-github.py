#!/usr/bin/env python3
"""Publish a smoke-tested image as an immutable, per-target GitHub prerelease.

Run after smoke-test.sh. Upload a draft first; never expose partially uploaded
images. Retrying verifies the existing release instead of replacing assets.
"""
import argparse
import hashlib
import json
import lzma
from pathlib import Path
import re
import subprocess
import tempfile


def gh(*args, data=None):
    return subprocess.check_output(['gh', *args], input=data, text=True)


def validate(directory, target):
    manifest = json.loads((directory / 'manifest.json').read_text())
    expected = 'airos-rpi4.img' if target == 'rpi4' else f'airos-{target}.iso'
    if manifest['target'] != target or manifest['image'] != expected:
        raise ValueError('Image target does not match manifest')
    commit = manifest['haiku']['commit']
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Invalid source commit')
    image = directory / (expected + '.xz')
    if not 0 < image.stat().st_size < 2 * 1024**3:
        raise ValueError('Image must fit the GitHub Releases per-file limit')
    checksum = directory / (image.name + '.sha256')
    fields = checksum.read_text().strip().split()
    if len(fields) != 2 or fields[1].lstrip('*') != image.name:
        raise ValueError('Checksum must name exactly this image')
    with image.open('rb') as f:
        digest = hashlib.file_digest(f, 'sha256').hexdigest()
    if fields[0] != digest:
        raise ValueError('Image checksum mismatch')
    raw_hash = hashlib.sha256()
    raw_size = 0
    with lzma.open(image, 'rb') as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            raw_hash.update(chunk)
            raw_size += len(chunk)
    if raw_size != manifest['image_bytes'] or raw_hash.hexdigest() != manifest['image_sha256']:
        raise ValueError('Uncompressed image does not match manifest')
    smoke = (directory / 'smoke.log').read_text()
    if 'SMOKE FAIL' in smoke or 'SMOKE PASS:' not in smoke:
        raise ValueError('A successful smoke test is required')
    if target != 'rpi4' and f'SMOKE PASS: {target} {image.name}' not in smoke:
        raise ValueError('Smoke test is for a different target')
    return manifest, [image, checksum, directory / 'manifest.json'], digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=['x86_64', 'arm64', 'rpi4'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--repo', default='jmgasper/haiku')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    manifest, files, digest = validate(args.directory, args.target)
    commit = manifest['haiku']['commit']
    stamp = re.sub(r'[^0-9]', '', manifest['built'].split('+')[0])
    tag = f'image-{args.target}-{stamp}-{commit[:10]}'
    if args.check:
        print(f'Validated {tag}: {digest}')
        return
    test = ('Booted to the desktop in QEMU. This is not a test on every physical device.'
            if args.target != 'rpi4' else 'SD card boot files and partition layout checked. This CI check does not boot a physical Pi.')
    notes = (f'airOS development image for **{args.target}**, built {manifest["built"]}.\n\n'
             f'Haiku source: [{commit[:10]}](https://github.com/jmgasper/haiku/commit/{commit}).\n\n'
             f'Validation: {test}\n\n'
             'Download the compressed image, checksum and package manifest below. '
             'Check hardware notes at https://jmgasper.github.io/airos-website/hardware/ before installing. '
             'These are experimental builds; back up your data first.\n\n'
             f'`{files[0].name}` SHA-256: `{digest}`\n')
    existing = subprocess.run(['gh', 'release', 'view', tag, '--repo', args.repo, '--json', 'isDraft'], capture_output=True, text=True)
    if existing.returncode == 0:
        release = json.loads(existing.stdout)
        if not release['isDraft']:
            release = json.loads(gh('api', f'repos/{args.repo}/releases/tags/{tag}'))
            assets = {a['name']: a for a in release['assets']}
            for file in files:
                with file.open('rb') as stream:
                    expected = 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()
                if assets.get(file.name, {}).get('digest') != expected:
                    raise RuntimeError('Published release differs from local image: ' + file.name)
            print('Already published and verified: ' + tag)
            return
    else:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.md', dir=args.directory) as note:
            note.write(notes)
            note.flush()
            gh('release', 'create', tag, '--repo', args.repo, '--target', commit,
               '--draft', '--prerelease', '--title', f'airOS {args.target} · {manifest["built"][:10]} · {commit[:7]}',
               '--notes-file', note.name)
    gh('release', 'upload', tag, '--repo', args.repo, '--clobber', *(str(f) for f in files))
    # GitHub's tag endpoint can return 404 for a draft. Resolve its numeric
    # release endpoint via gh, which supports looking up drafts by tag.
    endpoint = json.loads(gh('release', 'view', tag, '--repo', args.repo, '--json', 'apiUrl'))['apiUrl']
    remote = json.loads(gh('api', endpoint))
    assets = {a['name']: a for a in remote['assets']}
    for file in files:
        with file.open('rb') as stream:
            expected = 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()
        asset = assets.get(file.name, {})
        if asset.get('digest') != expected or asset.get('state') != 'uploaded':
            raise RuntimeError('Uploaded asset failed verification: ' + file.name)
    gh('release', 'edit', tag, '--repo', args.repo, '--draft=false')
    print(f'Published https://github.com/{args.repo}/releases/tag/{tag}')


if __name__ == '__main__':
    main()
