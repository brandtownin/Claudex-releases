from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / 'scripts' / 'validate_channel_metadata.py'


def compact(value):
    return json.dumps(value, separators=(',', ':')).encode()


def run_validator(pointer, manifest):
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        manifest_bytes = compact(manifest)
        manifest_path = td / 'manifest.json'
        manifest_path.write_bytes(manifest_bytes)
        pointer = dict(pointer)
        pointer['manifest_sha256'] = hashlib.sha256(manifest_bytes).hexdigest()
        pointer_path = td / 'candidate.json'
        pointer_path.write_bytes(compact(pointer))
        return subprocess.run(
            [sys.executable, str(VALIDATOR), '--pointer-file', str(pointer_path), '--manifest-file', str(manifest_path)],
            text=True,
            capture_output=True,
        )


def valid_manifest():
    return {
        'schema': 1,
        'release': 'v3.4-r8',
        'title': 'Safer tool execution',
        'benefits': ['Tool mutations recover safely from retries.'],
        'preservation': 'Your machine identity, connector URL, projects and settings stay intact.',
        'published_at': '2026-08-20T15:00:00Z',
        'key_id': 'release-key-1',
        'artifacts': {
            'linux-x86_64': {'url': 'https://example.test/x86.tar.gz', 'sha256': 'a' * 64},
            'linux-aarch64': {'url': 'https://example.test/arm.tar.gz', 'sha256': 'b' * 64},
        },
    }


def valid_pointer():
    return {
        'schema': 1,
        'channel': 'candidate',
        'release': 'v3.4-r8',
        'manifest_url': 'https://example.test/manifest.json',
        'manifest_sha256': '0' * 64,
        'key_id': 'release-key-1',
        'published_at': '2026-08-20T15:00:00Z',
    }


class ReleaseMetadataGateTests(unittest.TestCase):
    def test_validator_exists(self):
        self.assertTrue(VALIDATOR.is_file())

    def test_rejects_manifest_without_release_note_bullets(self):
        manifest = valid_manifest()
        manifest['benefits'] = []
        result = run_validator(valid_pointer(), manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('benefits', result.stderr.lower())

    def test_accepts_complete_release_notes(self):
        result = run_validator(valid_pointer(), valid_manifest())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_repo_workflow_enforces_validator(self):
        workflow = ROOT / '.github' / 'workflows' / 'release-metadata-gate.yml'
        self.assertTrue(workflow.is_file(), 'release metadata gate workflow must exist')
        text = workflow.read_text(encoding='utf-8')
        self.assertIn('pull_request:', text)
        self.assertIn('branches: [main]', text)
        self.assertIn('scripts/validate_channel_metadata.py --pointer-file channels/candidate.json', text)
        self.assertIn('scripts/validate_channel_metadata.py --pointer-file channels/stable.json', text)


if __name__ == '__main__':
    unittest.main()
