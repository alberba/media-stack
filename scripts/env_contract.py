#!/usr/bin/env python3
"""The Template's environment catalog and its Docker Compose-backed reader."""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
CATALOG = json.loads((REPO / "env/catalog.json").read_text())
ASSIGNMENT = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=")


def names(scope):
    return [name for name, item in CATALOG.items() if scope in item["scopes"]]


def file_names(path):
    found = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = ASSIGNMENT.match(line)
        if match:
            found.setdefault(match.group(1), []).append(number)
    return found


def interpolation_names(path):
    referenced = set()
    for line in path.read_text().splitlines():
        if not ASSIGNMENT.match(line):
            continue
        value = line.split("=", 1)[1].lstrip()
        if value.startswith("'"):
            continue
        for braced, plain in re.findall(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)|([A-Za-z_][A-Za-z0-9_]*))", value):
            referenced.add(braced or plain)
    return referenced


def values(path, scope, file_only=False, extra=None):
    """Let Compose parse and interpolate the chosen .env, including shell precedence."""
    selected = names(scope)
    if extra and extra not in selected:
        selected.append(extra)
    with tempfile.TemporaryDirectory() as directory:
        probe = Path(directory) / "compose.yaml"
        probe.write_text(
            "name: env-contract-probe\nservices:\n  probe:\n    image: alpine\n"
            "    environment:\n"
            + "".join(f"      {name}: ${{{name}-}}\n" for name in selected)
        )
        environment = os.environ.copy()
        if file_only:
            for name in set(selected) | set(file_names(path)) | interpolation_names(path):
                environment.pop(name, None)
            for name in ("COMPOSE_FILE", "COMPOSE_PROFILES", "COMPOSE_ENV_FILES", "COMPOSE_DISABLE_ENV_FILE"):
                environment.pop(name, None)
        command = [
            "docker", "compose", "--project-directory", str(path.parent.resolve()),
            "--env-file", str(path.resolve()), "-f", str(probe),
            "config", "--format", "json",
        ]
        try:
            result = subprocess.run(command, text=True, capture_output=True, env=environment)
        except OSError as error:
            raise ValueError(f"Docker Compose is unavailable: {error.strerror}") from error
    if result.returncode:
        raise ValueError(f"Docker Compose could not read {path}; check its .env syntax")
    resolved = json.loads(result.stdout)["services"]["probe"]["environment"]
    # `config` escapes dollar signs for another Compose pass; these values are for apps.
    return {name: resolved.get(name, "").replace("$$", "$") for name in selected}


def condition_applies(condition, current, profiles):
    if "profile" in condition:
        return condition["profile"] in profiles
    if "equals" in condition:
        return all(current.get(name) == value for name, value in condition["equals"].items())
    if "contains" in condition:
        return all(value in current.get(name, "") for name, value in condition["contains"].items())
    raise ValueError(f"unknown catalog condition: {condition}")


def condition_label(condition):
    if "profile" in condition:
        return f"needed by the {condition['profile']} Profile"
    if "equals" in condition:
        name, value = next(iter(condition["equals"].items()))
        return f"needed with {name}={value}"
    name, value = next(iter(condition["contains"].items()))
    return f"needed when {name} contains {value}"


def validate(path, scope):
    issues = file_names(path)
    for name, lines in issues.items():
        if name not in names(scope) and name not in ("COMPOSE_PROJECT_NAME", "COMPOSE_ENV_FILES", "COMPOSE_DISABLE_ENV_FILE"):
            print(f"warning: {name} is not in the {scope} catalog (line {lines[0]})", file=sys.stderr)
        if len(lines) > 1:
            print(f"warning: {name} occurs on lines {', '.join(map(str, lines))}; Compose's effective value wins", file=sys.stderr)
    current = values(path, scope)
    errors = []
    profiles = {item.strip() for item in current.get("COMPOSE_PROFILES", "").split(",") if item.strip()}
    for name in names(scope):
        setting = CATALOG[name]["scopes"][scope]
        value = current[name]
        condition = setting.get("required_if")
        active = bool(condition and condition_applies(condition, current, profiles))
        required = setting["required"] or active
        waived = False
        if active and "unless_file" in setting:
            exception = setting["unless_file"]
            state = Path(current[exception["root"]]) / exception["path"]
            waived = state.is_file() and state.stat().st_size > 0
        pattern = setting.get("pattern")
        if pattern and active and not waived and not re.fullmatch(pattern, value):
            detail = setting["pattern_description"]
            message = f"{name} must be {detail} ({condition_label(condition)})"
            if setting.get("hint"):
                message += f": {setting['hint']}"
            errors.append(message)
        elif required and not waived and not value:
            detail = f" ({condition_label(condition)})" if active else " in the effective environment"
            errors.append(f"{name} is empty{detail}")
        if setting.get("choices") and value and value not in setting["choices"]:
            options = " or ".join(repr(option) for option in setting["choices"])
            errors.append(f"{name} must be {options}, got {value!r}")
        if value and setting.get("exists_if") and condition_applies(setting["exists_if"], current, profiles):
            if not Path(value).is_dir():
                message = f"{name} {value} does not exist"
                if setting.get("exists_hint"):
                    message += f": {setting['exists_hint']}"
                errors.append(message)
        if value and setting.get("items_pattern") and condition_applies(setting["items_if"], current, profiles):
            for item in re.split(r"[\s,]+", value):
                if item and not re.fullmatch(setting["items_pattern"], item):
                    errors.append(f"{name}: '{item}' is not {setting['items_description']}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return not errors


def quote_value(value):
    """Write a literal value in Compose's .env syntax without shell evaluation."""
    if not re.search(r"[\s#'\"$\\]", value):
        return value
    if "'" not in value:
        return f"'{value}'"
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")
    return f'"{escaped}"'


def edit(path, name, value=None):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        raise ValueError("invalid setting name")
    lines = path.read_text().splitlines(keepends=True)
    active = re.compile(rf"^{re.escape(name)}=")
    example = re.compile(rf"^# {re.escape(name)}=")
    if value is None:
        lines = ["# " + line if active.match(line) else line for line in lines]
    else:
        assignment = f"{name}={quote_value(value)}\n"
        if any(active.match(line) for line in lines):
            lines = [assignment if active.match(line) else line for line in lines]
        elif any(example.match(line) for line in lines):
            first = next(index for index, line in enumerate(lines) if example.match(line))
            lines[first] = assignment
        else:
            if lines and not lines[-1].endswith("\n"):
                lines[-1] += "\n"
            lines.append(assignment)
    path.write_text("".join(lines))


def rendered_examples():
    result = {}
    for scope, source, destination in (
        ("instance", "env/instance.example.template", ".env.example"),
        ("worker", "env/worker.example.template", "worker/.env.example"),
    ):
        text = (REPO / source).read_text()
        declared = set(re.findall(r"^([A-Z_][A-Z0-9_]*)=@$", text, re.M))
        missing = set(names(scope)) - declared - ({"COMPOSE_FILE"} if scope == "instance" else set())
        if missing:
            raise ValueError(f"{source} lacks catalog settings: {', '.join(sorted(missing))}")
        for name in names(scope):
            marker = re.compile(rf"^{name}=@$", re.M)
            if marker.search(text):
                default = CATALOG[name]["scopes"][scope]["default"]
                text = marker.sub(lambda _: f"{name}={default}", text)
        result[destination] = text
    return result


def rendered_wire():
    path = REPO / "stacks/wire/compose.yaml"
    source = path.read_text()
    start = "    # BEGIN GENERATED ENV CONTRACT\n"
    end = "    # END GENERATED ENV CONTRACT\n"
    before, rest = source.split(start, 1)
    _, after = rest.split(end, 1)
    lines = []
    for name in names("instance"):
        if not CATALOG[name]["wire"]:
            continue
        setting = CATALOG[name]["scopes"]["instance"]
        expression = f"${{{name}:?set {name} in .env}}" if setting["required"] else f"${{{name}:-{setting['default']}}}"
        lines.append(f"    {name}: {expression}\n")
    return before + start + "".join(lines) + end + after


def generate(check=False):
    outputs = rendered_examples()
    outputs["stacks/wire/compose.yaml"] = rendered_wire()
    bad = False
    for name, content in outputs.items():
        path = REPO / name
        if check:
            if path.read_text() != content:
                print(f"out of date: {name}", file=sys.stderr)
                bad = True
        else:
            path.write_text(content)
    if check:
        for scope, roots in (("instance", [REPO / "compose.yaml", REPO / "compose.gpu.yaml", *REPO.glob("stacks/*/compose.yaml")]), ("worker", [REPO / "worker/compose.yaml"])):
            available = set(names(scope))
            for path in roots:
                source = path.read_text()
                for name in re.findall(r"\$\{([A-Z_][A-Z0-9_]*)", source):
                    if name not in available:
                        print(f"uncataloged Compose setting: {name} in {path.relative_to(REPO)}", file=sys.stderr)
                        bad = True
                for name, fallback in re.findall(r"\$\{([A-Z_][A-Z0-9_]*):-([^{}]*)\}", source):
                    if name not in available:
                        continue
                    setting = CATALOG[name]["scopes"][scope]
                    expected = setting.get("compose_default", setting["default"])
                    if fallback != expected:
                        print(f"Compose fallback for {name} differs from the catalog in {path.relative_to(REPO)}", file=sys.stderr)
                        bad = True
        for path in (REPO / "stacks/wire/wire").glob("*.py"):
            source = path.read_text()
            for name in re.findall(r'(?:self\.env\(|get\(environ,\s*|on\(environ,\s*|environ\.get\()["\']([A-Z_][A-Z0-9_]*)["\']', source):
                if name in CATALOG and not CATALOG[name]["wire"]:
                    print(f"Wiring reads {name} without catalog access in {path.relative_to(REPO)}", file=sys.stderr)
                    bad = True
    return not bad


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("resolve", "get", "validate", "overrides", "generate", "check", "fixture", "set", "comment"))
    parser.add_argument("--file", type=Path)
    parser.add_argument("--scope", choices=("instance", "worker"), default="instance")
    parser.add_argument("--name")
    parser.add_argument("--file-only", action="store_true")
    parser.add_argument("--label")
    args = parser.parse_args()
    if args.command in ("generate", "check"):
        try:
            return 0 if generate(args.command == "check") else 1
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
    if args.command == "fixture":
        for name in names(args.scope):
            if name == "COMPOSE_FILE":
                continue
            default = CATALOG[name]["scopes"][args.scope]["default"]
            if not default and (args.scope == "worker" or name not in ("COMPOSE_PROFILES", "BACKUP_SOURCE", "COMPOSE_FILE")):
                default = "dummy"
            print(f"{name}={default}")
        return 0
    path = args.file or REPO / (".env" if args.scope == "instance" else "worker/.env")
    if not path.is_file():
        print(f"error: no {path} found", file=sys.stderr)
        return 1
    try:
        if args.command in ("set", "comment"):
            edit(path, args.name, sys.stdin.read() if args.command == "set" else None)
            return 0
        if args.command == "validate":
            return 0 if validate(path, args.scope) else 1
        if args.command == "get":
            print(values(path, args.scope, file_only=True, extra=args.name)[args.name], end="")
        elif args.command == "resolve":
            for name, value in values(path, args.scope, file_only=args.file_only).items():
                sys.stdout.buffer.write(name.encode() + b"\0" + value.encode() + b"\0")
        elif args.command == "overrides":
            file_values = values(path, args.scope, file_only=True)
            effective = values(path, args.scope)
            label = args.label or path.name
            for name in names(args.scope):
                if effective[name] != file_values[name]:
                    if CATALOG[name]["secret"]:
                        print(f"warning: {name}: shell overrides {label} (secret value hidden)")
                    elif name not in os.environ:
                        print(f"warning: {name}: shell interpolation changes {label} (values hidden)")
                    else:
                        print(f"warning: {name}: shell value {effective[name]!r} overrides {label} value {file_values[name]!r}")
            for name in file_names(path):
                if name in CATALOG or name not in os.environ:
                    continue
                file_value = values(path, args.scope, file_only=True, extra=name)[name]
                if os.environ[name] != file_value:
                    print(f"warning: {name}: shell overrides {label} (unlisted value hidden)")
    except (ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
