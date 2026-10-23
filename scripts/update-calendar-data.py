#!/usr/bin/env python3
"""从香港天文台公历农历对照表提取月首和节气，校验全部年份后更新离线资源。"""
import concurrent.futures
import argparse
import bisect
import datetime
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NAMES = "小寒 大寒 立春 雨水 惊蛰 春分 清明 谷雨 立夏 小满 芒种 夏至 小暑 大暑 立秋 处暑 白露 秋分 寒露 霜降 立冬 小雪 大雪 冬至".split()
URL = "https://www.hko.gov.hk/en/gts/time/calendar/text/files/T{}e.txt"
ARCHIVE_URL = "https://raw.githubusercontent.com/hungtcs/traditional-chinese-calendar-database/master/database/all.json.zip"
ARCHIVE_SHA256 = "3945aa14c96521c4af0c0ff9b166d4744311ffcc57545346950910a930706a7b"


def fetch(year):
    cache = ROOT / ".build/calendar-sources" / f"T{year}e.txt"
    if cache.exists():
        source = cache.read_bytes().decode("latin1")
    else:
        cache.parent.mkdir(parents=True, exist_ok=True)
        # curl 重试时会重置输出文件；标准输出可能拼接失败的半份响应和后续完整响应。
        with tempfile.TemporaryDirectory(prefix="download-", dir=cache.parent) as temporary:
            output = Path(temporary) / "calendar.txt"
            subprocess.run(
                ["curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "40",
                 "--retry", "2", "--output", str(output), URL.format(year)], check=True, capture_output=True)
            source = output.read_bytes().decode("latin1")
    dates = []
    for line in source.splitlines():
        match = re.match(r"^(\d{4})/(\d{1,2})/(\d{1,2})\s+.*?(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+(.+?)\s*$", line)
        if match and match.group(4).strip():
            day = datetime.date(*map(int, match.group(1, 2, 3)))
            dates.append(day)
    if len(dates) != 24 or len(set(dates)) != 24 or dates != sorted(dates):
        raise ValueError(f"{year} 年节气表不完整：{len(dates)} 项")
    if any(day.year != year or day.month != index // 2 + 1 for index, day in enumerate(dates)):
        raise ValueError(f"{year} 年节气顺序不符")
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_bytes(source.encode("latin1"))
    return {day.isoformat(): name for day, name in zip(dates, NAMES)}


def lunar_months():
    rows = []
    for year in range(1901, 2101):
        source = (ROOT / ".build/calendar-sources" / f"T{year}e.txt").read_bytes().decode("latin1")
        for line in source.splitlines():
            match = re.match(r"^(\d{4})/(\d{1,2})/(\d{1,2})\s+(.+?)\s+(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)", line)
            if match:
                rows.append((datetime.date(*map(int, match.group(1, 2, 3))), match.group(4).strip()))
    first = datetime.date(1901, 1, 1)
    last = datetime.date(2100, 12, 31)
    if [day for day, _ in rows] != [first + datetime.timedelta(days=i) for i in range((last - first).days + 1)]:
        raise ValueError("公历日期存在缺失、重复或乱序")
    next_month = int(re.match(r"\d+", next(label for _, label in rows if not label.isdigit())).group())
    month = (next_month - 2) % 12 + 1
    start = first - datetime.timedelta(days=int(rows[0][1]) - 1)
    months = {start.isoformat(): month}
    for day, label in rows:
        if label.isdigit():
            if int(label) != (day - start).days + 1 or not 1 <= int(label) <= 30:
                raise ValueError(f"{day} 农历日序不连续")
        else:
            match = re.fullmatch(r"(\d+)(?:st|nd|rd|th) Lunar [Mm]onth", label)
            if not match or (day - start).days not in (29, 30):
                raise ValueError(f"{day} 农历月首不合法：{label}")
            number = int(match.group(1))
            if number not in (abs(month), abs(month) % 12 + 1) or (month < 0 and number == abs(month)):
                raise ValueError(f"{day} 农历月份顺序不合法")
            month = -number if number == abs(month) else number
            start = day
            months[day.isoformat()] = month
    return months


def from_archive(path):
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("存档校验和不符；需要人工核对来源变更")
    rows = json.loads(gzip.decompress(raw))
    month_names = "正 二 三 四 五 六 七 八 九 十 十一 十二".split()
    months = {"1900-12-22": 11}
    terms = {}
    for year in range(1901, 2101):
        annual = [row for row in rows if row["gregorian"]["year"] == year]
        dates = []
        for row in annual:
            g = row["gregorian"]
            key = datetime.date(g["year"], g["month"], g["date"]).isoformat()
            if row.get("solarTerm"):
                dates.append(key)
            if row["lunar"]["date"] == "初一":
                name = row["lunar"]["month"].replace("閏", "").removesuffix("月")
                number = month_names.index(name) + 1
                months[key] = -number if row["lunar"]["leapMonth"] else number
        if len(dates) != 24 or dates != sorted(set(dates)):
            raise ValueError(f"{year} 存档节气不完整")
        terms.update(zip(dates, NAMES))
    starts = sorted(datetime.date.fromisoformat(key) for key in months)
    if len(starts) != 2475 or any((b - a).days not in (29, 30) for a, b in zip(starts, starts[1:])):
        raise ValueError("存档农历月份不连续")
    verified = []
    for source in sorted((ROOT / ".build/calendar-sources").glob("T*e.txt")):
        year = int(source.stem[1:-1])
        for key, value in fetch(year).items():
            if terms.get(key) != value:
                raise ValueError(f"存档与官方节气不一致：{key}")
        for line in source.read_bytes().decode("latin1").splitlines():
            match = re.match(r"^(\d{4})/(\d{1,2})/(\d{1,2})\s+(.+?)\s+(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)", line)
            if not match:
                continue
            day = datetime.date(*map(int, match.group(1, 2, 3)))
            start = starts[bisect.bisect_right(starts, day) - 1]
            label = match.group(4).strip()
            if label.isdigit():
                valid = int(label) == (day - start).days + 1
            else:
                valid = day == start and int(re.match(r"\d+", label).group()) == abs(months[start.isoformat()])
            if not valid:
                raise ValueError(f"存档与官方农历不一致：{day}")
        verified.append(year)
    return terms, months, {"archive": ARCHIVE_URL, "sha256": ARCHIVE_SHA256, "verifiedOfficialYears": verified}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="使用固定校验和的公开存档，并对照已缓存的官方表")
    args = parser.parse_args()
    if args.archive:
        terms, months, provenance = from_archive(args.archive)
    else:
        terms = {}
        failures = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = {pool.submit(fetch, year): year for year in range(1901, 2101)}
            for index, future in enumerate(concurrent.futures.as_completed(futures), 1):
                try:
                    terms.update(future.result())
                except Exception as error:
                    failures.append(futures[future])
                    print(f"读取 {futures[future]} 年失败：{error}", flush=True)
                if index % 10 == 0:
                    print(f"已读取 {index}/200 年", flush=True)
        if failures:
            raise SystemExit(f"未写入资源。请重试失败年份：{failures}")
        months = lunar_months()
        provenance = {"official": URL, "verifiedOfficialYears": list(range(1901, 2101))}
    target = ROOT / "Sources/DayOrderCore/Resources/calendar-data.json"
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps({"solarTerms": terms, "lunarMonths": months, "provenance": provenance}, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    temporary.replace(target)
    print(f"已保存 {len(terms)} 项节气日期、{len(months)} 个农历月首")
