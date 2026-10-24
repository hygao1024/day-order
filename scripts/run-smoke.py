#!/usr/bin/env python3
"""运行已构建的 Debug 应用，同时检查功能退出码和布局循环诊断。"""

import argparse
from pathlib import Path
import subprocess
import sys


def check_diagnostics(log: str) -> None:
    cycles = [line for line in log.splitlines() if "AttributeGraph: cycle detected" in line]
    if cycles:
        raise RuntimeError(f"检测到 {len(cycles)} 条 SwiftUI 布局循环警告。")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("smoke_arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    app = root / "build/DayOrder.app/Contents/MacOS/DayOrder"
    output = args.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=True)
    log_path = output / "runtime.log"
    try:
        with log_path.open("w") as log_file:
            result = subprocess.run(
                [str(app), "--smoke-test", str(output), *args.smoke_arguments],
                cwd=root, stdout=log_file, stderr=subprocess.STDOUT, timeout=300,
            )
        log = log_path.read_text(errors="replace")
        if log:
            print(log, end="" if log.endswith("\n") else "\n")
        if result.returncode != 0:
            raise RuntimeError(f"应用冒烟失败，退出码 {result.returncode}。")
        check_diagnostics(log)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"冒烟检查失败：{error} 日志：{log_path}", file=sys.stderr)
        return 1
    print(f"冒烟检查通过，未检测到布局循环警告。日志：{log_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
