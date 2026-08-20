#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import urlopen

RELEASE_RE = re.compile(r'^v\d+\.\d+-r\d+$')
SHA256_RE = re.compile(r'^[0-9a-f]{64}$')
ARTIFACT_KEYS = ('linux-x86_64', 'linux-aarch64')


def fail(message: str) -> None:
    raise ValueError(message)


def load_json_bytes(data: bytes, label: str) -> dict:
    try:
        value = json.loads(data.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f'invalid {label} JSON: {exc}')
    if not isinstance(value, dict):
        fail(f'{label} must be a JSON object')
    return value


def is_https(value: object) -> bool:
    if not isinstance(value, str):
        return False
    parsed = urlparse(value)
    return parsed.scheme == 'https' and bool(parsed.netloc)


def validate_pointer(pointer: dict) -> None:
    if pointer.get('schema') != 1:
        fail('pointer schema must be 1')
    if pointer.get('channel') not in ('candidate', 'stable'):
        fail('pointer channel must be candidate or stable')
    if not isinstance(pointer.get('release'), str) or not RELEASE_RE.fullmatch(pointer['release']):
        fail('pointer release is invalid')
    if not is_https(pointer.get('manifest_url')):
        fail('manifest_url must be absolute HTTPS')
    if not isinstance(pointer.get('manifest_sha256'), str) or not SHA256_RE.fullmatch(pointer['manifest_sha256']):
        fail('manifest_sha256 is invalid')
    if not isinstance(pointer.get('key_id'), str) or not pointer['key_id'].strip():
        fail('pointer key_id is invalid')
    if not isinstance(pointer.get('published_at'), str) or not pointer['published_at'].strip():
        fail('pointer published_at is invalid')


def validate_manifest(pointer: dict, manifest: dict) -> None:
    if manifest.get('schema') != 1:
        fail('manifest schema must be 1')
    if manifest.get('release') != pointer['release']:
        fail('manifest release does not match pointer release')
    title = manifest.get('title')
    if not isinstance(title, str) or not title.strip():
        fail('manifest title is required')
    benefits = manifest.get('benefits')
    if not isinstance(benefits, list) or not benefits or any(not isinstance(item, str) or not item.strip() for item in benefits):
        fail('manifest benefits must contain at least one non-empty release-note bullet')
    preservation = manifest.get('preservation')
    if not isinstance(preservation, str) or not preservation.strip():
        fail('manifest preservation text is required')
    if manifest.get('key_id') != pointer['key_id']:
        fail('manifest key_id does not match pointer key_id')
    artifacts = manifest.get('artifacts')
    if not isinstance(artifacts, dict):
        fail('manifest artifacts are required')
    for key in ARTIFACT_KEYS:
        artifact = artifacts.get(key)
        if not isinstance(artifact, dict):
            fail(f'{key} artifact is required')
        if not is_https(artifact.get('url')):
            fail(f'{key} artifact URL must be absolute HTTPS')
        digest = artifact.get('sha256')
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            fail(f'{key} artifact SHA-256 is invalid')


def validate(pointer_bytes: bytes, manifest_bytes: bytes) -> None:
    pointer = load_json_bytes(pointer_bytes, 'channel pointer')
    validate_pointer(pointer)
    actual = hashlib.sha256(manifest_bytes).hexdigest()
    if actual != pointer['manifest_sha256']:
        fail('manifest digest does not match channel pointer')
    manifest = load_json_bytes(manifest_bytes, 'release manifest')
    validate_manifest(pointer, manifest)


def main() -> int:
    parser = argparse.ArgumentParser(description='Validate Claudex channel metadata and required dashboard release notes')
    parser.add_argument('--pointer-file', required=True, type=Path)
    parser.add_argument('--manifest-file', type=Path)
    args = parser.parse_args()

    try:
        pointer_bytes = args.pointer_file.read_bytes()
        pointer = load_json_bytes(pointer_bytes, 'channel pointer')
        if args.manifest_file:
            manifest_bytes = args.manifest_file.read_bytes()
        else:
            validate_pointer(pointer)
            with urlopen(pointer['manifest_url'], timeout=20) as response:
                manifest_bytes = response.read()
        validate(pointer_bytes, manifest_bytes)
    except (OSError, ValueError, TimeoutError) as exc:
        print(f'release metadata validation failed: {exc}', file=sys.stderr)
        return 1

    print('release metadata validation passed')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
