"""Check that public RunOrc bootstrap is pinned, syntax-valid and self-verifying."""
from pathlib import Path
import hashlib
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bootstrap.sh"
CHECKSUM = ROOT / "bootstrap.sha256"


class BootstrapDistributionTests(unittest.TestCase):
    def test_public_bytes_are_explicitly_checksummed(self):
        digest = hashlib.sha256(SCRIPT.read_bytes()).hexdigest()
        self.assertEqual(CHECKSUM.read_text().strip(), f"{digest}  bootstrap.sh")
        self.assertTrue(SCRIPT.read_bytes().startswith(b"#!/usr/bin/env bash\n"))

    def test_public_bootstrap_verifies_signed_release_metadata_and_package(self):
        source = SCRIPT.read_text()
        for expected in ("channels/candidate.json", "channels/beta.json",
                         "channels/stable.json", "openssl pkeyutl -verify",
                         "sha256sum -c", "validate_archive_paths",
                         "install/install.sh"):
            self.assertIn(expected, source)
        for prohibited in ("SUPABASE_SECRET_KEY", "GITHUB_TOKEN=",
                           "VERCEL_AUTOMATION_BYPASS_SECRET", "runorc-git-preview-"):
            self.assertNotIn(prohibited, source)
        result = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
