#!/usr/bin/env python3
"""通过隔离应用包、本地 HTTP 源和 Sparkle 真实安装器验证更新。"""

from __future__ import annotations

import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
ACCOUNT = "com.dayorder.calendar"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def run(*args: str | Path, expected: int | None = 0, env=None, log: Path | None = None):
    result = subprocess.run([str(arg) for arg in args], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180, env=env)
    if log:
        log.write_text(result.stdout)
    if expected is not None and result.returncode != expected:
        raise RuntimeError(f"{args[0]} 退出码 {result.returncode}：{result.stdout}")
    return result


def copy_app(source: Path, target: Path, **changes):
    run("/usr/bin/ditto", source, target)
    path = target / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info.update(changes)
    path.write_bytes(plistlib.dumps(info))
    run("/usr/bin/codesign", "--force", "--sign", "-", target)


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def build_cli(root: Path) -> Path:
    # 使用 Swift Package 锁定的上游 CLI 源码和同一框架，避免另下载一个不同版本的安装器。
    app = root / "sparkle.app"
    contents = app / "Contents"
    executable = contents / "MacOS/sparkle"
    executable.parent.mkdir(parents=True)
    framework_directory = ROOT / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
    run("/usr/bin/ditto", framework_directory / "Sparkle.framework", contents / "Frameworks/Sparkle.framework")
    source = ROOT / ".build/checkouts/Sparkle/sparkle-cli"
    run("/usr/bin/xcrun", "clang", "-fobjc-arc", "-arch", "arm64", "-mmacosx-version-min=14.0",
        "-DSPU_OBJC_DIRECT=__attribute__((objc_direct))", "-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))",
        "-F", framework_directory, "-framework", "Foundation", "-framework", "AppKit", "-framework", "Sparkle",
        "-Wl,-rpath,@executable_path/../Frameworks", source / "main.m", source / "SPUCommandLineDriver.m",
        source / "SPUCommandLineUserDriver.m", "-o", executable)
    (contents / "Info.plist").write_bytes(plistlib.dumps(dict(
        CFBundleExecutable="sparkle", CFBundleIdentifier="com.dayorder.update-test.cli", CFBundleName="Update Test",
        CFBundlePackageType="APPL", CFBundleVersion="1", LSUIElement=True, LSMinimumSystemVersion="14.0",
        NSAppTransportSecurity={"NSAllowsLocalNetworking": True})))
    run("/usr/bin/codesign", "--force", "--sign", "-", app)
    return executable


def verify(output: Path):
    output.mkdir(parents=True, exist_ok=True)
    source = ROOT / "build/DayOrder.app"
    identifier = "com.dayorder.update-test." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="dayorder-updates-") as temporary:
        root = Path(temporary)
        cli = build_cli(root)
        web = root / "web"
        web.mkdir()
        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(web)))
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}/"
            old = root / "old/DayOrder.app"
            new = root / "new/DayOrder.app"
            properties = dict(CFBundleIdentifier=identifier, SUFeedURL=base + "appcast.xml")
            copy_app(source, old, **properties)
            copy_app(source, new, **properties, CFBundleVersion="999999", CFBundleShortVersionString="99.0.0")
            archive = web / "DayOrder-99.0.0-arm64.zip"
            run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", new, archive)
            run(TOOLS / "generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0",
                "--download-url-prefix", base, web)
            feed = web / "appcast.xml"
            original = feed.read_bytes()

            def check_ui(name: str, expected: str):
                env = dict(os.environ, DAYORDER_UPDATE_TEST_BUNDLE=str(old), DAYORDER_UPDATE_TEST_EXPECTED=expected)
                directory = output / name
                directory.mkdir(exist_ok=True)
                run(source / "Contents/MacOS/DayOrder", "--smoke-test", directory, "--updates-smoke",
                    env=env, log=directory / "runtime.log")
                if "AttributeGraph: cycle detected" in (directory / "runtime.log").read_text():
                    raise RuntimeError("更新设置出现布局循环。")
                if not (directory / "result.txt").exists():
                    raise RuntimeError("更新设置未完成验证。")

            check_ui("available", "发现新版本 99.0.0")
            tree = ET.fromstring(original)
            tree.find("./channel/item/" + SPARKLE + "version").text = "1"
            feed.write_bytes(ET.tostring(tree, encoding="utf-8", xml_declaration=True))
            run(TOOLS / "sign_update", "--account", ACCOUNT, feed)
            check_ui("no-update", "未发现适用于此 Mac")
            feed.write_bytes(original.replace(b"99.0.0", b"98.0.0"))
            check_ui("invalid-feed", "更新未完成")
            feed.write_bytes(original)
            archive_bytes = archive.read_bytes()
            corrupted = bytearray(archive_bytes)
            corrupted[len(corrupted) // 2] ^= 1
            archive.write_bytes(corrupted)
            rejected = run(cli, old, "--check-immediately", "--verbose", expected=None,
                           log=output / "invalid-archive.log")
            if rejected.returncode == 0 or plistlib.loads((old / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "999999":
                raise RuntimeError("损坏的安装包未被拒绝。")
            if not any(term in rejected.stdout.lower() for term in ["signature", "improperly signed"]):
                raise RuntimeError("损坏安装包未到达签名拒绝路径。")
            archive.write_bytes(archive_bytes)
            # CLI 在安装器完成退出前就可能报告校验失败；后续启动需等待辅助进程收敛。
            time.sleep(2)
            run(cli, old, "--check-immediately", "--verbose", log=output / "installation.log")
            installed = plistlib.loads((old / "Contents/Info.plist").read_bytes())
            if installed["CFBundleVersion"] != "999999" or installed["CFBundleIdentifier"] != identifier:
                raise RuntimeError("真实安装器未替换临时应用。")
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", old)

            spec = spec_from_file_location("package_release", ROOT / "scripts/package-release.py")
            package_release = module_from_spec(spec)
            spec.loader.exec_module(package_release)
            prerelease = root / "prerelease/DayOrder.app"
            copy_app(source, prerelease, CFBundleShortVersionString="99.0.0-beta.1")
            try:
                package_release.package(prerelease, root / "rejected")
            except ValueError as error:
                if "alpha/beta" not in str(error):
                    raise
            else:
                raise RuntimeError("预发布版本未被拒绝。")
            release = root / "release/DayOrder.app"
            copy_app(source, release, CFBundleShortVersionString="99.0.0", CFBundleVersion="999999")
            package_release.package(release, root / "packages")
            (output / "result.txt").write_text("设置控件、偏好持久化、新版本、无更新、损坏清单、损坏安装包拒绝、真实安装及正式发布打包验证通过。\n")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            run("/usr/bin/defaults", "delete", identifier, expected=None)
    print(f"更新验证通过：{output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/updates-smoke")
    args = parser.parse_args()
    verify(args.output.resolve())


if __name__ == "__main__":
    main()
