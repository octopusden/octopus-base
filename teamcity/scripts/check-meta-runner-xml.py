#!/usr/bin/env python3
"""Check TeamCity settings structurally; script-content drift is checked by the Bash suites."""

import sys
import xml.etree.ElementTree as ET


def check(root, runner_name, bindings):
    errors = []
    runners = root.findall("./settings/build-runners/runner")
    selected = [runner for runner in runners if runner.get("name") == runner_name]
    if len(selected) != 1:
        return [f"expected exactly one runner named {runner_name!r}"]
    runner = selected[0]
    if runner.get("type") != "simpleRunner":
        errors.append("runner must be a Command Line step (simpleRunner)")

    def require_param(parent, name, value):
        params = [p for p in parent.findall("./parameters/param") if p.get("name") == name]
        if len(params) != 1 or params[0].get("value") != value:
            errors.append(f"expected one parameter {name}={value!r} in {parent.tag}")

    for name in ("use.custom.script", "log.stderr.as.errors"):
        require_param(runner, name, "true")
    if any(p.get("name", "").startswith("env.") for p in runner.findall("./parameters/param")):
        errors.append("env. parameters must be declared in settings, not the runner")
    settings = root.find("./settings")
    for name, value in bindings.items():
        require_param(settings, name, value)

    disabled = {
        reference.get("ref")
        for reference in root.findall("./settings/disabled-settings/setting-ref")
    }
    if not any(
        requirement.get("name") == "teamcity.agent.jvm.os.name"
        and requirement.get("value") == "Windows"
        and requirement.get("disabled") != "true"
        and requirement.get("id") not in disabled
        for requirement in root.findall("./settings/requirements/does-not-contain")
    ):
        errors.append("runner must exclude Windows agents in settings/requirements")
    return errors


def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} XML_FILE RUNNER_NAME [PARAMETER=VALUE ...]", file=sys.stderr)
        return 2
    path, runner_name, *bindings = sys.argv[1:]
    try:
        if any("=" not in binding for binding in bindings):
            raise ValueError("each binding must have the form PARAMETER=VALUE")
        errors = check(ET.parse(path).getroot(), runner_name, dict(b.split("=", 1) for b in bindings))
    except (OSError, ET.ParseError, ValueError) as error:
        errors = [str(error)]
    for error in errors:
        print(f"FAIL [{error}]")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
