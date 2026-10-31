"""发布边界：完整附件、草稿恢复、远端校验和正式更新渠道。"""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publish_release", Path(__file__).resolve().parents[1] / "publish-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def assets(self, version):
        for suffix in ["zip", "dmg"]:
            path = self.directory / f"DayOrder-{version}-arm64.{suffix}"
            path.write_bytes(b"package fixture")
            path.with_suffix(path.suffix + ".sha256").write_text(
                f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n")
        return release.verified_assets(self.directory, version)

    def state(self, assets, draft=True):
        return dict(draft=draft, html_url="https://github.com/hygao1024/day-order/releases/test",
                    assets=[dict(name=p.name, digest="sha256:" + hashlib.sha256(p.read_bytes()).hexdigest()) for p in assets])

    def test_prerelease_publishes_only_after_verified_upload(self):
        assets = self.assets("1.0.0-alpha.08")
        state = self.state(assets)
        with patch.object(release, "release_state", side_effect=[None, state, state]), patch.object(release, "gh") as gh:
            release.publish("v1.0.0-alpha.08", self.directory)
        calls = [call.args for call in gh.call_args_list]
        self.assertEqual([call[:2] for call in calls], [("release", "create"), ("release", "upload"), ("release", "edit")])
        self.assertIn("--draft", calls[0])
        self.assertIn("--draft=false", calls[-1])
        self.assertIn("--prerelease", calls[-1])
        self.assertIn("--latest=false", calls[-1])

    def test_new_draft_visibility_delay_is_retried(self):
        state = self.state(self.assets("1.0.0-alpha.08"))
        with patch.object(release, "release_state", side_effect=[None, None, None, state, state]), \
                patch.object(release.time, "sleep") as sleep, patch.object(release, "gh") as gh:
            release.publish("v1.0.0-alpha.08", self.directory)
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(gh.call_args_list[-1].args[:2], ("release", "edit"))

    def test_invisible_draft_times_out_without_upload(self):
        self.assets("1.0.0-alpha.08")
        with patch.object(release, "release_state", return_value=None), \
                patch.object(release.time, "monotonic", side_effect=[0, 61]), patch.object(release, "gh") as gh:
            with self.assertRaisesRegex(ValueError, "超时"):
                release.publish("v1.0.0-alpha.08", self.directory)
        self.assertEqual([call.args[:2] for call in gh.call_args_list], [("release", "create")])

    def test_stable_release_stays_draft(self):
        assets = self.assets("1.0.0")
        state = self.state(assets)
        with patch.object(release, "release_state", side_effect=[None, state, state]), patch.object(release, "gh") as gh:
            release.publish("v1.0.0", self.directory)
        self.assertEqual([call.args[:2] for call in gh.call_args_list], [("release", "create"), ("release", "upload")])
        self.assertIn("--prerelease=false", gh.call_args_list[0].args)

    def test_existing_draft_can_resume(self):
        state = self.state(self.assets("1.0.0-alpha.08"))
        with patch.object(release, "release_state", return_value=state), patch.object(release, "gh") as gh:
            release.publish("v1.0.0-alpha.08", self.directory)
        self.assertEqual(gh.call_args_list[0].args[:2], ("release", "upload"))

    def test_public_release_is_never_modified(self):
        state = self.state(self.assets("1.0.0-alpha.08"), draft=False)
        with patch.object(release, "release_state", return_value=state), patch.object(release, "gh") as gh:
            with self.assertRaisesRegex(ValueError, "已公开"):
                release.publish("v1.0.0-alpha.08", self.directory)
        gh.assert_not_called()

    def test_signed_draft_is_not_overwritten(self):
        state = self.state(self.assets("1.0.0"))
        state["assets"].append(dict(name="appcast.xml"))
        with patch.object(release, "release_state", return_value=state), patch.object(release, "gh") as gh:
            with self.assertRaisesRegex(ValueError, "签名更新清单"):
                release.publish("v1.0.0", self.directory)
        gh.assert_not_called()

    def test_changed_draft_state_stops_upload(self):
        state = self.state(self.assets("1.0.0-alpha.08"))
        public = dict(state, draft=False)
        with patch.object(release, "release_state", side_effect=[state, public]), patch.object(release, "gh") as gh:
            with self.assertRaisesRegex(ValueError, "状态已改变"):
                release.publish("v1.0.0-alpha.08", self.directory)
        gh.assert_not_called()

    def test_corrupt_remote_attachment_prevents_publication(self):
        state = self.state(self.assets("1.0.0-alpha.08"))
        state["assets"][0]["digest"] = "sha256:wrong"
        with patch.object(release, "release_state", return_value=state), patch.object(release, "gh") as gh:
            with self.assertRaisesRegex(ValueError, "远端附件校验失败"):
                release.publish("v1.0.0-alpha.08", self.directory)
        self.assertEqual([call.args[:2] for call in gh.call_args_list], [("release", "upload")])

    def test_missing_or_corrupt_local_attachment_never_calls_github(self):
        for fault in ["missing", "corrupt", "symlink"]:
            with self.subTest(fault=fault):
                assets = self.assets("1.0.0-alpha.08")
                target = assets[0]
                if fault == "missing":
                    target.unlink()
                elif fault == "corrupt":
                    target.write_bytes(b"changed")
                else:
                    target.unlink()
                    target.symlink_to(assets[2])
                with patch.object(release, "gh") as gh, self.assertRaises(ValueError):
                    release.publish("v1.0.0-alpha.08", self.directory)
                gh.assert_not_called()
                if target.is_symlink():
                    target.unlink()

    def test_draft_is_found_when_tag_endpoint_returns_404(self):
        draft = dict(tag_name="v1.0.0", draft=True, assets=[])
        error = subprocess.CalledProcessError(1, ["gh"], stderr="Not Found (HTTP 404)")
        with patch.object(release, "gh", side_effect=[error, json.dumps([[], [draft]])]):
            self.assertEqual(release.release_state("v1.0.0"), draft)

    def test_only_http_404_falls_back_to_release_list(self):
        for status in [404, 403, 500]:
            error = subprocess.CalledProcessError(1, ["gh"], stderr=f"error (HTTP {status})")
            with self.subTest(status=status), patch.object(release, "gh", side_effect=[error, "[[]]"]) as gh:
                if status == 404:
                    self.assertIsNone(release.release_state("v1.0.0"))
                    self.assertEqual(gh.call_count, 2)
                else:
                    with self.assertRaises(subprocess.CalledProcessError):
                        release.release_state("v1.0.0")
                    self.assertEqual(gh.call_count, 1)


if __name__ == "__main__":
    unittest.main()
