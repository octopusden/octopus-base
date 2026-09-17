#!/usr/bin/env python3
"""Exercise the reusable workflow's real run steps against consumer fixtures."""

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap


workflow = Path(".github/workflows/common-workflow-lint.yml").read_text()


def run_body(step_name):
    step = workflow.split(f"      - name: {step_name}\n", 1)[1]
    step = step.split("\n      - ", 1)[0]
    body = step.split("        run: ", 1)[1]
    if body.startswith("|\n"):
        return textwrap.dedent(body[2:])
    return body.strip()


lint = run_body("Validate GitHub Actions workflows")
if sys.argv[1:] == ["--native-actionlint"]:
    lint = "actionlint -color"
shell_check = run_body("Validate shell helper syntax")
valid_workflow = """\
name: Fixture
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
"""

with tempfile.TemporaryDirectory(prefix="workflow-lint-") as directory:
    root = Path(directory).resolve()
    # The actionlint image runs as guest; TemporaryDirectory defaults to mode 0700.
    root.chmod(0o755)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    workflows = root / ".github/workflows"
    workflows.mkdir(parents=True)
    for name in ("common-workflow-lint.yml", "common-gradle-dependency-submission.yml"):
        shutil.copyfile(Path(".github/workflows") / name, workflows / name)
    fixture = workflows / "fixture.yml"
    fixture.write_text(valid_workflow)
    (workflows / "consumer-lint.yml").write_text("""\
name: Consumer lint
on: pull_request
permissions:
  contents: read
jobs:
  workflow-lint:
    uses: ./.github/workflows/common-workflow-lint.yml
""")
    caller = workflows / "consumer-dependencies.yml"
    caller.write_text("""\
name: Consumer dependencies
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: write
jobs:
  dependencies:
    uses: ./.github/workflows/common-gradle-dependency-submission.yml
    with:
      java-version: '21'
""")

    def check(name, command, error=None):
        result = subprocess.run(
            command, cwd=root, env={**os.environ, "PWD": str(root)},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        if (result.returncode == 0) != (error is None) or (error and error not in result.stdout):
            raise AssertionError(f"{name}: exit {result.returncode}\n{result.stdout}")
        print(f"PASS {name}", flush=True)

    check("valid consumer workflow", ["bash", "-e", "-c", lint])
    check("consumer without shell helpers", ["python3", "-c", shell_check])
    fixture.write_text(valid_workflow.replace("ubuntu-latest", "${{ invalid.runner }}"))
    check("invalid workflow expression fails", ["bash", "-e", "-c", lint], 'undefined variable "invalid"')
    fixture.write_text(valid_workflow)
    caller.write_text(caller.read_text().replace("    with:\n      java-version: '21'\n", ""))
    check("missing required JDK fails consumer validation", ["bash", "-e", "-c", lint], 'input "java-version" is required')
    helper = root / ".github/helper with spaces.sh"
    helper.write_text("#!/bin/bash\necho ok\n")
    check("valid helper, including spaces in its name", ["python3", "-c", shell_check])
    helper.write_text("#!/bin/bash\nif true\n")
    check("invalid shell helper fails", ["python3", "-c", shell_check], "syntax error: unexpected end of file")
