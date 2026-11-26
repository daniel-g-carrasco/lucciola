import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / ".github/scripts/scan-published-sboms.py"
spec = importlib.util.spec_from_file_location("scan_published_sboms", SCRIPT)
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)

IMAGE = "sha256:" + "1" * 64
SBOM = "sha256:" + "2" * 64
OTHER = "sha256:" + "3" * 64
BLOB = "sha256:" + "4" * 64


class PublishedInventoryTest(unittest.TestCase):
    def test_pins_aliases_to_one_scan_per_digest(self):
        tags = "stable.20261120\nstable.20261121\nfedora-kernel.20261121\npr-25"
        with patch.object(scan, "command", side_effect=[tags, IMAGE, IMAGE, IMAGE, OTHER, OTHER]):
            refs = scan.published_digests("fedora-kernel")
        self.assertEqual(refs, {IMAGE: ["stable", "fedora-kernel", "stable.20261121"],
                                OTHER: ["stable.20261120", "fedora-kernel.20261121"]})

    def test_signed_inventory_is_the_image_subject(self):
        discovered = {"referrers": [{"digest": SBOM, "artifactType": scan.SPDX_ARTIFACT}]}
        manifest = {"subject": {"digest": IMAGE}, "artifactType": scan.SPDX_ARTIFACT,
                    "layers": [{"digest": BLOB, "mediaType": "application/spdx+json"}]}
        with (tempfile.TemporaryDirectory() as work, patch.object(scan, "command") as run,
              patch.object(scan, "read_json", side_effect=[discovered, manifest]) as read):
            dest = Path(work) / "sbom.spdx.json"
            scan.fetch_sbom(IMAGE, dest)
            self.assertIn(("cosign", "verify", "--key", str(scan.KEY),
                           "--new-bundle-format=false", f"{scan.REPO}@{IMAGE}"),
                          [call.args for call in run.call_args_list])
            self.assertEqual(run.call_args_list[-1].args[:4],
                             ("oras", "blob", "fetch", f"{scan.REPO}@{BLOB}"))
            self.assertIn(f"{scan.REPO}@{SBOM}", read.call_args.args)
            manifest["subject"]["digest"] = OTHER
            run.reset_mock()
            read.side_effect = [discovered, manifest]
            with self.assertRaises(RuntimeError):
                scan.fetch_sbom(IMAGE, dest)
            self.assertFalse(any("blob" in call.args for call in run.call_args_list))

    def test_wrong_signature_stops_before_reading_inventory(self):
        with (patch.object(scan, "command", side_effect=RuntimeError("wrong key")),
              patch.object(scan, "read_json") as read):
            with self.assertRaisesRegex(RuntimeError, "wrong key"):
                scan.fetch_sbom(IMAGE, Path("unreachable.spdx.json"))
            read.assert_not_called()

    def test_older_digest_still_alerts_and_uses_its_own_inventory(self):
        advisory = {"matches": [{"vulnerability": {"severity": "High", "id": "CVE-2099-1000"}}]}
        with (patch("sys.argv", ["scan-published-sboms.py", "--digest", OTHER]),
              patch.object(scan, "fetch_sbom") as fetch, patch.object(scan, "read_json", return_value=advisory),
              patch("builtins.print")):
            self.assertEqual(scan.main(), 1)
            self.assertEqual(fetch.call_args.args[0], OTHER)

    def test_critical_and_high_are_advisories(self):
        data = {"matches": [{"vulnerability": {"severity": level, "id": ident}}
                             for level, ident in [("High", "CVE-2099-1000"),
                                                  ("Critical", "CVE-2099-2000"),
                                                  ("Medium", "CVE-2099-3000"),
                                                  ("High", "CVE-2099-1000")]]}
        self.assertEqual(scan.high_advisories(data),
                         [("Critical", "CVE-2099-2000"), ("High", "CVE-2099-1000")])
        with self.assertRaises(KeyError):
            scan.high_advisories({})


if __name__ == "__main__":
    unittest.main()
