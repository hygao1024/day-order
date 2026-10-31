#!/usr/bin/env python3
"""按版本标签构建 ARM64 应用并生成 Actions 构建产物，不发布 Release。"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def version_from_tag(tag: str) -> str:
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)\.[0-9]+)?", tag):
        raise ValueError("标签须为 vX.Y.Z 或 vX.Y.Z-alpha.N、-beta.N、-rc.N。")
    return tag[1:]


def build_number(repository: Path) -> str:
    if subprocess.check_output(["git", "rev-parse", "--is-shallow-repository"], cwd=repository, text=True).strip() != "false":
        raise ValueError("标签构建需要完整 Git 历史，请使用 fetch-depth: 0。")
    return subprocess.check_output(["git", "rev-list", "--count", "HEAD"], cwd=repository, text=True).strip()


def run(*args: str | Path) -> None:
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True, timeout=600)


def verify_app(app: Path, version: str, number: str) -> None:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (
        "com.dayorder.calendar", version, number
    ):
        raise ValueError("应用标识、显示版本或构建号与标签构建不符。")
    architectures = subprocess.check_output(
        ["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/DayOrder")], text=True).strip()
    if architectures != "arm64":
        raise ValueError("标签安装包的主程序必须仅包含 arm64 架构。")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)


def verify_dmg(image: Path, version: str, number: str) -> None:
    run("/usr/bin/hdiutil", "verify", image)
    with tempfile.TemporaryDirectory(prefix="dayorder-mount-") as temporary:
        mount = Path(temporary) / "volume"
        mount.mkdir()
        try:
            run("/usr/bin/hdiutil", "attach", image, "-readonly", "-nobrowse", "-mountpoint", mount)
            verify_app(mount / "DayOrder.app", version, number)
            shortcut = mount / "Applications"
            if not shortcut.is_symlink() or shortcut.readlink() != Path("/Applications"):
                raise ValueError("DMG 必须包含指向 /Applications 的安装快捷入口。")
        finally:
            # 即使挂载后的检查失败，也只卸载本次创建的挂载点。
            if mount.is_mount():
                try:
                    run("/usr/bin/hdiutil", "detach", mount)
                except subprocess.CalledProcessError:
                    run("/usr/bin/hdiutil", "detach", "-force", mount)


def create_dmg(app: Path, image: Path, version: str, number: str) -> None:
    with tempfile.TemporaryDirectory(prefix="dayorder-dmg-") as temporary:
        contents = Path(temporary)
        run("/usr/bin/ditto", app, contents / "DayOrder.app")
        (contents / "Applications").symlink_to("/Applications", target_is_directory=True)
        run("/usr/bin/hdiutil", "create", "-volname", "DayOrder", "-srcfolder", contents,
            "-fs", "HFS+", "-format", "UDZO", image)
    verify_dmg(image, version, number)


def build(tag: str) -> Path:
    version = version_from_tag(tag)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("标签构建须在 Apple 芯片的 macOS 环境执行。")
    number = build_number(ROOT)
    output_root = ROOT / "build/tag-artifacts"
    destination = output_root / tag
    if destination.exists():
        raise ValueError(f"构建产物已存在，拒绝覆盖：{destination}")

    run(ROOT / "scripts/build-app.sh", "release")
    app = ROOT / "build/DayOrder.app"
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = number
    info_path.write_bytes(plistlib.dumps(info))
    run("/usr/bin/codesign", "--force", "--sign", "-", app)
    verify_app(app, version, number)

    output_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tag-build-", dir=output_root) as temporary:
        staging = Path(temporary)
        archive = staging / f"DayOrder-{version}-arm64.zip"
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        # 上传 ZIP 而非裸应用目录，保留 Sparkle 框架符号链接和可执行权限。
        with tempfile.TemporaryDirectory(prefix="dayorder-unpack-") as extracted:
            run("/usr/bin/ditto", "-x", "-k", archive, extracted)
            verify_app(Path(extracted) / "DayOrder.app", version, number)
        image = staging / f"DayOrder-{version}-arm64.dmg"
        create_dmg(app, image, version, number)
        for package in [archive, image]:
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            (staging / f"{package.name}.sha256").write_text(f"{digest}  {package.name}\n")
        staging.rename(destination)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="例如 v1.0.0 或 v1.1.0-beta.1")
    args = parser.parse_args()
    try:
        destination = build(args.tag)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"标签构建失败：{error}\n")
    print(f"已生成 {destination}")


if __name__ == "__main__":
    main()
