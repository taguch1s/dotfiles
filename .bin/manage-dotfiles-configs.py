#!/usr/bin/env python3
"""dotfiles.toml に従って設定を配置・検証する。"""

from __future__ import annotations

import argparse
import difflib
import os
import shutil
import sys
import time
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def configs() -> list[dict[str, object]]:
    with (ROOT / "dotfiles.toml").open("rb") as file:
        return tomllib.load(file)["config"]


def target_path(config: dict[str, object]) -> Path:
    target = str(config["target"])
    if target.startswith("/"):
        return Path(target)
    return Path.home() / target


def source_path(config: dict[str, object]) -> Path:
    return ROOT / str(config["source"])


def backup(target: Path) -> None:
    stamp = time.strftime("%Y%m%d%H%M%S")
    destination = target.with_name(f"{target.name}.dotfiles-backup-{stamp}")
    shutil.move(target, destination)
    print(f"退避  {target} → {destination}")


def link() -> int:
    for config in configs():
        if config["mode"] != "link":
            continue
        source, target = source_path(config), target_path(config)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink() and target.resolve() == source.resolve():
            print(f"OK    リンク: {config['target']}")
            continue
        if target.exists() or target.is_symlink():
            backup(target)
        target.symlink_to(source)
        if config.get("executable"):
            source.chmod(source.stat().st_mode | 0o111)
        print(f"リンク {target} → {source}")
    return 0


def install() -> int:
    for config in configs():
        if config["mode"] != "copy-if-missing":
            continue
        source, target = source_path(config), target_path(config)
        if target.exists():
            print(f"保持  {target}（差分は make diff で確認できます）")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        print(f"導入  {target}")
    return 0


def doctor() -> int:
    failures = 0
    for config in configs():
        mode, target = str(config["mode"]), target_path(config)
        if mode == "link":
            source = source_path(config)
            ok = target.is_symlink() and target.resolve() == source.resolve()
            print(f"{'OK' if ok else 'NG'}    リンク: {config['target']}")
            failures += not ok
        elif mode == "copy-if-missing":
            ok = target.is_file()
            print(f"{'OK' if ok else 'NG'}    設定: {config['target']}")
            failures += not ok
        elif mode == "manual":
            print(f"情報  手動管理: {config['name']}（{config['reason']}）")
    return int(failures > 0)


def diff() -> int:
    changed = False
    for config in configs():
        if config["mode"] != "copy-if-missing":
            continue
        source, target = source_path(config), target_path(config)
        if not target.exists():
            print(f"未導入 {config['target']}")
            changed = True
            continue
        before = source.read_text().splitlines(keepends=True)
        after = target.read_text().splitlines(keepends=True)
        if before == after:
            print(f"一致  {config['target']}")
            continue
        changed = True
        print(f"差分  {config['target']}（端末固有・生成済みの設定は取り込まないでください）")
        sys.stdout.writelines(difflib.unified_diff(before, after, str(source), str(target)))
    return int(changed)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("link", "install", "doctor", "diff"))
    return globals()[parser.parse_args().command]()


if __name__ == "__main__":
    raise SystemExit(main())
