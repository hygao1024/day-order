#!/usr/bin/env python3
"""为正式版本生成 ARM64 安装包及签名更新清单，不上传 Release。"""

from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
ACCOUNT = "com.dayorder.calendar"
FEED = "https://github.com/hygao1024/day-order/releases/latest/download/appcast.xml"


def run(*args: str | Path) -> str:
    return subprocess.run([str(arg) for arg in args], check=True, text=True,
                          stdout=subprocess.PIPE, timeout=180).stdout.strip()


def package(app: Path, output_root: Path) -> Path:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("自动更新仅发布正式版本，版本号须为 X.Y.Z，不接受 alpha/beta。")
    if not re.fullmatch(r"[1-9]\d*", info["CFBundleVersion"]):
        raise ValueError("构建号须为递增正整数。")
    if info["CFBundleIdentifier"] != ACCOUNT or info.get("SUFeedURL") != FEED:
        raise ValueError("应用标识或更新源与日序正式发布配置不符。")
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("发布包必须校验更新清单与安装包签名。")
    public_key = (ROOT / "Assets/UpdatePublicKey.pub").read_text().strip()
    if info.get("SUPublicEDKey") != public_key or run(TOOLS / "generate_keys", "--account", ACCOUNT, "-p") != public_key:
        raise ValueError("应用、仓库公钥和钥匙串签名密钥不匹配。请恢复原签名密钥，不要重新生成替代密钥。")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if run("/usr/bin/lipo", "-archs", executable) != "arm64":
        raise ValueError("发布应用的主程序必须仅包含 arm64 架构。")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    destination = output_root / f"v{version}"
    if destination.exists():
        raise ValueError(f"输出已存在，拒绝覆盖：{destination}")
    output_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".package-", dir=output_root) as temporary:
        staging = Path(temporary)
        archive = staging / f"DayOrder-{version}-arm64.zip"
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        run(TOOLS / "generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0",
            "--download-url-prefix", f"https://github.com/hygao1024/day-order/releases/download/v{version}/", staging)
        feed = staging / "appcast.xml"
        run(TOOLS / "sign_update", "--account", ACCOUNT, "--verify", feed)
        enclosure = ET.parse(feed).find("./channel/item/enclosure")
        if enclosure is None:
            raise ValueError("更新清单缺少安装包。")
        signature = enclosure.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"]
        run(TOOLS / "sign_update", "--account", ACCOUNT, "--verify", archive, signature)
        shutil.move(staging, destination)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/DayOrder.app")
    parser.add_argument("--output-root", type=Path, default=ROOT / "build/releases")
    args = parser.parse_args()
    try:
        destination = package(args.app.resolve(), args.output_root.resolve())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"发布打包失败：{error}\n")
    print(f"已生成 {destination}；将其中 ZIP 和 appcast.xml 一起上传至对应正式 Release。")


if __name__ == "__main__":
    main()
