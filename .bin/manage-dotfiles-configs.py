#!/usr/bin/env python3
"""dotfiles.toml に従って設定を配置・検証する。"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import shutil
import sys
import time
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FEATURES_HEADER = re.compile(r"^\s*\[\s*features\s*\]\s*(?:#.*)?$")


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


def feature_values(config: dict[str, object]) -> dict[str, bool]:
    configured_names = config.get("features")
    if not isinstance(configured_names, list) or not all(isinstance(name, str) for name in configured_names):
        raise ValueError(f"features を指定してください: {source_path(config)}")
    with source_path(config).open("rb") as file:
        source_features = tomllib.load(file).get("features", {})
    if not isinstance(source_features, dict):
        raise ValueError(f"[features] が不正です: {source_path(config)}")
    values = {name: source_features.get(name) for name in configured_names}
    if not all(isinstance(value, bool) for value in values.values()):
        raise ValueError(f"管理対象 feature は boolean にしてください: {source_path(config)}")
    return values


def merge_toml_features(config: dict[str, object]) -> bool:
    source, target = source_path(config), target_path(config)
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        print(f"導入  {target}")
        return True

    values = feature_values(config)
    original = target.read_text()
    try:
        target_features = tomllib.loads(original).get("features", {})
    except tomllib.TOMLDecodeError as error:
        print(f"NG    TOML を解析できません: {target}: {error}", file=sys.stderr)
        return False
    if not isinstance(target_features, dict):
        print(f"NG    [features] が不正です: {target}", file=sys.stderr)
        return False

    conflicts = {name: (target_features[name], value) for name, value in values.items() if name in target_features and target_features[name] != value}
    if conflicts:
        rendered = ", ".join(f"{name}={actual!r} (期待値 {expected!r})" for name, (actual, expected) in conflicts.items())
        print(f"NG    既存の Codex feature と競合します: {target}: {rendered}", file=sys.stderr)
        return False

    missing = {name: value for name, value in values.items() if name not in target_features}
    if not missing:
        print(f"一致  {target} の管理対象 feature")
        return True

    lines = original.splitlines(keepends=True)
    section_start = next((index for index, line in enumerate(lines) if FEATURES_HEADER.match(line)), None)
    additions = [f"{name} = {str(value).lower()}\n" for name, value in missing.items()]
    if section_start is None:
        if target_features:
            print(f"NG    [features] の inline table は管理できません: {target}", file=sys.stderr)
            return False
        suffix = "" if not original or original.endswith("\n") else "\n"
        updated = f"{original}{suffix}\n[features]\n{''.join(additions)}"
    else:
        section_end = next((index for index in range(section_start + 1, len(lines)) if lines[index].lstrip().startswith("[")), len(lines))
        insertion_point = section_end
        while insertion_point > section_start + 1 and not lines[insertion_point - 1].strip():
            insertion_point -= 1
        lines[insertion_point:insertion_point] = additions
        updated = "".join(lines)
    try:
        parsed = tomllib.loads(updated).get("features", {})
    except tomllib.TOMLDecodeError as error:
        print(f"NG    同期結果の TOML を解析できません: {target}: {error}", file=sys.stderr)
        return False
    if not isinstance(parsed, dict) or any(parsed.get(name) != value for name, value in values.items()):
        print(f"NG    同期結果を検証できません: {target}", file=sys.stderr)
        return False
    target.write_text(updated)
    print(f"同期  {target} の管理対象 feature: {', '.join(missing)}")
    return True


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


def sync() -> int:
    succeeded = True
    for config in configs():
        if config["mode"] == "merge-toml-features":
            succeeded = merge_toml_features(config) and succeeded
    return int(not succeeded)


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
        elif mode == "merge-toml-features":
            if not target.is_file():
                print(f"NG    設定: {config['target']}")
                failures += 1
                continue
            try:
                actual = tomllib.loads(target.read_text()).get("features", {})
                expected = feature_values(config)
                ok = isinstance(actual, dict) and all(actual.get(name) == value for name, value in expected.items())
            except (OSError, ValueError, tomllib.TOMLDecodeError):
                ok = False
            print(f"{'OK' if ok else 'NG'}    Codex feature: {config['target']}")
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
    parser.add_argument("command", choices=("link", "install", "sync", "doctor", "diff"))
    return globals()[parser.parse_args().command]()


if __name__ == "__main__":
    raise SystemExit(main())
