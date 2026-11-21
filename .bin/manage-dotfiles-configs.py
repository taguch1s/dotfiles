#!/usr/bin/env python3
"""dotfiles.toml に従って設定を配置・検証する。"""

from __future__ import annotations

import argparse
import copy
import difflib
import json
import os
import re
import shutil
import sys
import tempfile
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


HookKey = tuple[str, object, str]


def string_list(config: dict[str, object], name: str) -> list[str]:
    value = config.get(name, [])
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise ValueError(f"{name} は文字列の配列にしてください: {config.get('name', config['target'])}")
    return value


def hook_groups(settings: object, label: object) -> dict[str, list[dict]]:
    """settings の hooks を検証して返す。管理外の handler の中身は問わない。"""
    if not isinstance(settings, dict):
        raise ValueError(f"JSON の最上位がオブジェクトではありません: {label}")
    hooks = settings.get("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(f"hooks がオブジェクトではありません: {label}")
    for event, groups in hooks.items():
        if not isinstance(groups, list) or not all(isinstance(group, dict) and isinstance(group.get("hooks"), list) for group in groups):
            raise ValueError(f"hooks.{event} の形式が不正です: {label}")
    return hooks


def handler_command(handler: object) -> object:
    return handler.get("command") if isinstance(handler, dict) else None


def managed_json_source(config: dict[str, object], source: object) -> dict[HookKey, dict]:
    """source のうち dotfiles が持つ hook handler を (event, matcher, command) ごとに返す。"""
    commands = set(string_list(config, "hook_commands"))
    string_list(config, "keys")
    desired: dict[HookKey, dict] = {}
    for event, groups in hook_groups(source, source_path(config)).items():
        for group in groups:
            for handler in group["hooks"]:
                command = handler_command(handler)
                if command not in commands:
                    raise ValueError(f"source の hook command が hook_commands にありません: {event}: {command!r}")
                desired.setdefault((event, group.get("matcher"), command), handler)
    return desired


def merged_json(config: dict[str, object], source: object, current: object) -> dict:
    """current の管理対象 hook と keys だけを source に合わせた設定を返す。"""
    desired = managed_json_source(config, source)
    commands = set(string_list(config, "hook_commands"))
    result = copy.deepcopy(current)
    hooks = hook_groups(result, target_path(config))
    seen: set[HookKey] = set()
    for event in list(hooks):
        groups = hooks[event]
        kept_groups = []
        for group in groups:
            kept = []
            for handler in group["hooks"]:
                command = handler_command(handler)
                key = (event, group.get("matcher"), command)
                if command not in commands:
                    kept.append(handler)
                elif key in desired and key not in seen:
                    kept.append(copy.deepcopy(desired[key]))
                    seen.add(key)
            removed = len(kept) < len(group["hooks"])
            group["hooks"] = kept
            if kept or not removed:
                kept_groups.append(group)
        if kept_groups or not groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]

    for key, handler in desired.items():
        if key in seen:
            continue
        event, matcher, _ = key
        groups = hooks.setdefault(event, [])
        group = next((group for group in groups if group.get("matcher") == matcher), None)
        if group is None:
            group = {"matcher": matcher, "hooks": []} if matcher is not None else {"hooks": []}
            groups.append(group)
        group["hooks"].append(copy.deepcopy(handler))
    if hooks and "hooks" not in result:
        result["hooks"] = hooks

    for key in string_list(config, "keys"):
        if key in source:
            result[key] = copy.deepcopy(source[key])
        else:
            result.pop(key, None)
    return result


def render_json(value: object) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def managed_json_plan(config: dict[str, object]) -> tuple[str, object, dict]:
    """(現在の本文, 現在の値, 同期後の値) を返す。不正な source・target は ValueError。"""
    source, target = source_path(config), target_path(config)
    try:
        source_value = json.loads(source.read_text())
    except json.JSONDecodeError as error:
        raise ValueError(f"JSON を解析できません: {source}: {error}") from error
    original = target.read_text()
    try:
        current = json.loads(original)
    except json.JSONDecodeError as error:
        raise ValueError(f"JSON を解析できません: {target}: {error}") from error
    return original, current, merged_json(config, source_value, current)


def merge_json_managed(config: dict[str, object]) -> bool:
    source, target = source_path(config), target_path(config)
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        print(f"導入  {target}")
        return True
    try:
        original, current, planned = managed_json_plan(config)
    except (OSError, ValueError) as error:
        print(f"NG    {error}", file=sys.stderr)
        return False
    if planned == current:
        print(f"一致  {target} の管理対象 hook とキー")
        return True

    # 同じディレクトリの一時ファイルに書いてから rename し、途中の状態を Claude Code に読ませない。
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup_path = target.with_name(f"{target.name}.dotfiles-backup-{stamp}")
    suffix = 1
    while backup_path.exists():
        backup_path = target.with_name(f"{target.name}.dotfiles-backup-{stamp}-{suffix}")
        suffix += 1
    descriptor, temporary = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w") as file:
            file.write(render_json(planned))
        shutil.copymode(target, temporary)
        if target.read_text() != original:
            print(f"NG    同期中に {target} が変更されました。もう一度実行してください", file=sys.stderr)
            return False
        shutil.copy2(target, backup_path)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"同期  {target} の管理対象 hook とキー（変更前: {backup_path}）")
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
        elif config["mode"] == "merge-json-managed":
            succeeded = merge_json_managed(config) and succeeded
    return int(not succeeded)


def has_installed_link() -> bool:
    for config in configs():
        if config["mode"] != "link":
            continue
        source, target = source_path(config), target_path(config)
        if target.is_symlink() and target.resolve() == source.resolve():
            return True
    return False


def doctor_json_managed(config: dict[str, object], *, check_target: bool) -> bool:
    """installed checkout では端末の設定まで、worktree では宣言と source だけを検証する。"""
    label = config["target"]
    if not check_target:
        try:
            managed_json_source(config, json.loads(source_path(config).read_text()))
            ok = True
        except (OSError, ValueError) as error:
            print(f"NG    管理対象: {config['source']}: {error}", file=sys.stderr)
            return False
        print(f"OK    管理対象: {config['source']}（hook と {', '.join(string_list(config, 'keys'))}）")
        return ok
    if not target_path(config).is_file():
        print(f"NG    設定: {label}（make sync で導入できます）")
        return False
    try:
        _, current, planned = managed_json_plan(config)
    except (OSError, ValueError) as error:
        print(f"NG    設定: {label}: {error}")
        return False
    ok = planned == current
    hint = "" if ok else "（管理対象の hook かキーが古い・欠けています。make diff で確認し make sync で同期）"
    print(f"{'OK' if ok else 'NG'}    Claude 管理対象 hook とキー: {label}{hint}")
    return ok


def doctor(*, static: bool = False, auto: bool = False) -> int:
    if static and auto:
        raise ValueError("--static と --auto は同時に指定できません")

    check_links = not static and (not auto or has_installed_link())
    if not check_links:
        print("情報  worktree-safe static doctor: home link は installed checkout だけで検証します")

    failures = 0
    for config in configs():
        mode, target = str(config["mode"]), target_path(config)
        if mode == "link":
            source = source_path(config)
            if check_links:
                ok = target.is_symlink() and target.resolve() == source.resolve()
                print(f"{'OK' if ok else 'NG'}    リンク: {config['target']}")
            else:
                ok = source.exists()
                print(f"{'OK' if ok else 'NG'}    管理対象: {config['source']}")
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
        elif mode == "merge-json-managed":
            ok = doctor_json_managed(config, check_target=check_links)
            failures += not ok
        elif mode == "manual":
            print(f"情報  手動管理: {config['name']}（{config['reason']}）")
    return int(failures > 0)


def diff_json_managed(config: dict[str, object]) -> bool:
    """同期で変わる内容を表示し、変わるなら True を返す。"""
    target = target_path(config)
    if not target.exists():
        print(f"未導入 {config['target']}")
        return True
    try:
        original, current, planned = managed_json_plan(config)
    except (OSError, ValueError) as error:
        print(f"NG    {error}", file=sys.stderr)
        return True
    if planned == current:
        print(f"一致  {config['target']} の管理対象 hook とキー")
        return False
    print(f"差分  {config['target']}（make sync で管理対象の hook とキーだけを反映します）")
    before = render_json(current).splitlines(keepends=True)
    after = render_json(planned).splitlines(keepends=True)
    sys.stdout.writelines(difflib.unified_diff(before, after, f"{target}（現在）", f"{target}（同期後）"))
    return True


def diff() -> int:
    changed = False
    for config in configs():
        if config["mode"] == "merge-json-managed":
            changed = diff_json_managed(config) or changed
            continue
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
    parser.add_argument("--static", action="store_true", help="home link を変更せず source だけを検証する")
    parser.add_argument("--auto", action="store_true", help="installed checkout は full、linked worktree は static で検証する")
    args = parser.parse_args()
    if (args.static or args.auto) and args.command != "doctor":
        parser.error("--static と --auto は doctor だけで使用できます")
    if args.command == "doctor":
        return doctor(static=args.static, auto=args.auto)
    return globals()[args.command]()


if __name__ == "__main__":
    raise SystemExit(main())
