"""标签输入与真实 Git 历史边界，不需要构建应用。"""

import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("tag_build", Path(__file__).resolve().parents[1] / "build-tag.py")
tag_build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tag_build)


class TagBuildTests(unittest.TestCase):
    def test_supported_tags(self):
        for tag in ["v1.0.0", "v0.2.3", "v1.0.0-alpha.05", "v2.1.0-beta.1", "v2.1.0-rc.2"]:
            with self.subTest(tag=tag):
                self.assertEqual(tag_build.version_from_tag(tag), tag[1:])

    def test_rejects_paths_shell_fragments_and_unsupported_versions(self):
        for tag in ["1.0.0", "v1.0", "v01.0.0", "v1.0.0\n", "v1.0.0/../../other", "v1.0.0$(id)",
                    "v1.0.0;echo bad", "v1.0.0-nightly", "v1.0.0+build.1", "v一.0.0"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                tag_build.version_from_tag(tag)

    def test_full_history_and_shallow_clone(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            shallow = Path(temporary) / "shallow"
            subprocess.run(["git", "init", str(source)], check=True, capture_output=True)
            for message in ["first", "second"]:
                subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", message],
                               cwd=source, check=True, capture_output=True)
            self.assertEqual(tag_build.build_number(source), "2")
            subprocess.run(["git", "clone", "--depth", "1", source.as_uri(), str(shallow)],
                           check=True, capture_output=True)
            with self.assertRaisesRegex(ValueError, "fetch-depth"):
                tag_build.build_number(shallow)

    def test_rejects_mismatched_bundle_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "DayOrder.app"
            (app / "Contents").mkdir(parents=True)
            info_path = app / "Contents/Info.plist"
            expected = dict(CFBundleIdentifier="com.dayorder.calendar", CFBundleShortVersionString="1.0.0", CFBundleVersion="42")
            for key, value in [("CFBundleIdentifier", "other.app"), ("CFBundleShortVersionString", "1.0.1"),
                               ("CFBundleVersion", "1")]:
                with self.subTest(key=key):
                    info_path.write_bytes(plistlib.dumps(dict(expected, **{key: value})))
                    with self.assertRaises(ValueError):
                        tag_build.verify_app(app, "1.0.0", "42")

    @unittest.skipUnless(sys.platform == "darwin", "需要 macOS 架构工具")
    def test_rejects_real_intel_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "DayOrder.app"
            binary = app / "Contents/MacOS/DayOrder"
            binary.parent.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
                CFBundleIdentifier="com.dayorder.calendar", CFBundleShortVersionString="1.0.0", CFBundleVersion="42")))
            subprocess.run(["/usr/bin/xcrun", "clang", "-arch", "x86_64", "-x", "c", "-", "-o", str(binary)],
                           input="int main(void) { return 0; }\n", text=True, check=True, capture_output=True)
            with self.assertRaisesRegex(ValueError, "arm64"):
                tag_build.verify_app(app, "1.0.0", "42")


if __name__ == "__main__":
    unittest.main()
