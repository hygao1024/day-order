#!/usr/bin/env python3
"""上传已验证的标签安装包；预发布版本公开，正式版本保留草稿等待签名更新清单。"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "hygao1024/day-order"
spec = importlib.util.spec_from_file_location("tag_build", ROOT / "scripts/build-tag.py")
tag_build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tag_build)


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, text=True, capture_output=True, timeout=180).stdout


def release_state(tag: str):
    try:
        return json.loads(gh("api", f"repos/{REPOSITORY}/releases/tags/{tag}"))
    except subprocess.CalledProcessError as error:
        if "HTTP 404" not in error.stderr:
            raise
    # 标签查询不返回草稿；完整列表可查询当前令牌可见的草稿。
    pages = json.loads(gh("api", f"repos/{REPOSITORY}/releases", "--paginate", "--slurp"))
    return next((item for page in pages for item in page if item["tag_name"] == tag), None)


def verified_assets(directory: Path, version: str) -> list[Path]:
    assets = []
    for extension in ["zip", "dmg"]:
        package = directory / f"DayOrder-{version}-arm64.{extension}"
        checksum = directory / f"{package.name}.sha256"
        for path in [package, checksum]:
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"缺少普通产物文件：{path.name}")
        expected = f"{hashlib.sha256(package.read_bytes()).hexdigest()}  {package.name}\n"
        if checksum.read_text() != expected:
            raise ValueError(f"安装包校验值不匹配：{package.name}")
        assets.extend([package, checksum])
    return assets


def publish(tag: str, directory: Path) -> str:
    version = tag_build.version_from_tag(tag)
    assets = verified_assets(directory, version)
    prerelease = "-" in version
    state = release_state(tag)
    if state is not None and not state["draft"]:
        raise ValueError("该 Release 已公开，拒绝覆盖附件；请使用新版本标签。")
    if state is None:
        notes = "适用于 Apple 芯片 Mac，要求 macOS 14 或更高版本。打开 DMG，将日序拖入应用程序。\n\n"
        notes += "应用采用临时代码签名，尚未经过 Apple Developer ID 签名或公证。\n"
        notes += "\n此预发布版本供手动安装，不进入正式自动更新渠道。\n" if prerelease else (
            "\n正式发布前须补充匹配此 ZIP 的签名 appcast.xml，并确认构建号递增，再发布并设为 Latest。\n")
        with tempfile.TemporaryDirectory(prefix="dayorder-release-") as temporary:
            path = Path(temporary) / "notes.md"
            path.write_text(notes)
            gh("release", "create", tag, "--repo", REPOSITORY, "--verify-tag", "--draft",
               f"--prerelease={str(prerelease).lower()}", "--latest=false", "--title", f"日序 {version}",
               "--notes-file", str(path))
    # 只更新未公开草稿中的同名文件；中断后可重跑，公开版本保持不可变。
    state = release_state(tag)
    if state is None or not state["draft"]:
        raise ValueError("上传前 Release 状态已改变，停止修改。")
    if any(asset["name"] == "appcast.xml" for asset in state["assets"]):
        raise ValueError("草稿已包含签名更新清单，拒绝替换安装包；请先确认发布状态。")
    gh("release", "upload", tag, *(str(path) for path in assets), "--repo", REPOSITORY, "--clobber")
    state = release_state(tag)
    if state is None or not state["draft"]:
        raise ValueError("附件上传后 Release 状态已改变，停止发布。")
    remote = {asset["name"]: asset for asset in state["assets"]}
    for path in assets:
        asset = remote.get(path.name, {})
        if asset.get("digest") != "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest():
            raise ValueError(f"远端附件校验失败，保留草稿：{path.name}")
    if prerelease:
        gh("release", "edit", tag, "--repo", REPOSITORY, "--draft=false", "--prerelease", "--latest=false")
    return f"https://github.com/{REPOSITORY}/releases/tag/{tag}" if prerelease else state["html_url"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        url = publish(args.tag, args.directory.resolve())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(1, f"Release 上传失败：{detail}\n")
    print(url)


if __name__ == "__main__":
    main()
