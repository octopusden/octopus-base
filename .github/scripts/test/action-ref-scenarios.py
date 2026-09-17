#!/usr/bin/env python3
"""Check reference extraction without depending on GitHub availability."""

import os
from pathlib import Path
import subprocess
import tempfile


validator = Path(".github/scripts/validate-github-action-refs.sh").resolve()
with tempfile.TemporaryDirectory(prefix="action-refs-") as directory:
    root = Path(directory)
    workflows = root / ".github/workflows"
    workflows.mkdir(parents=True)
    fixture = workflows / "fixture.yml"
    binaries = root / "bin"
    binaries.mkdir()
    gh = binaries / "gh"
    gh.write_text('#!/bin/sh\nprintf "%s\\n" "$2" >> "$CALL_LOG"\necho fixture-sha\n')
    gh.chmod(0o755)
    calls = root / "calls"
    env = {**os.environ, "PATH": f"{binaries}:{os.environ['PATH']}", "CALL_LOG": str(calls)}

    def validate():
        return subprocess.run(
            ["bash", str(validator), str(root)], env=env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )

    fixture.write_text("""\
jobs:
  reusable:
    uses: example/shared/.github/workflows/build.yml@v1
  build:
    steps:
      - uses: 'actions/checkout@v7'
      - name: Java
        uses: actions/setup-java@v6
      - uses: ./local-action
      - uses: docker://alpine:3
""")
    action = root / ".github/actions/fixture/action.yml"
    action.parent.mkdir(parents=True)
    action.write_text('runs:\n  using: composite\n  steps:\n    - uses: "example/composite@v2"\n')
    result = validate()
    assert result.returncode == 0, result.stdout
    assert set(calls.read_text().splitlines()) == {
        "repos/example/shared/commits/v1", "repos/actions/checkout/commits/v7",
        "repos/actions/setup-java/commits/v6", "repos/example/composite/commits/v2",
    }, result.stdout
    print("PASS scalar, list-item, quoted and composite refs; local/Docker refs excluded", flush=True)

    for prefix in ("    uses:", "    - uses:"):
        fixture.write_text(f"{prefix} actions/checkout\n")
        calls.write_text("")
        result = validate()
        assert result.returncode != 0, result.stdout
        assert "Invalid uses format (missing @ref): actions/checkout" in result.stdout, result.stdout
        assert not calls.read_text(), "Invalid input must fail before API calls"
        print(f"PASS missing ref rejected for {prefix.strip()}", flush=True)
