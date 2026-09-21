# Meta-runner scripts are bash, and their runners refuse Windows agents

`OctopusCalculateBuildParameters` and `OctopusCheckReleaseVersionIsNew` carry bash scripts in
Command Line runners, and both declare `teamcity.agent.jvm.os.name does-not-contain Windows`.

TeamCity's Command Line runner does not choose an interpreter. On a Unix agent it writes the
custom script to a file and the shebang picks bash; on a Windows agent it writes the same text to
a `.cmd` and hands it to `cmd.exe`, which reads `#!/usr/bin/env bash` as a command name. Every
line then fails with *is not recognized as an internal or external command* and the step exits
255 without having run any of the logic. Nothing inside the script can catch this, because cmd
never reaches it. This is not hypothetical: on 2026-09-20 the version step failed exactly this
way on the pool's Windows agents while succeeding on the Linux agents in the same batch, and
the step had been a `kotlinScript` runner — which is OS-independent — until 2026-09.

## Considered options

- **Rewrite the version calculation in Kotlin**, as the `Read CURRENT_COMMIT` step in the same
  meta-runner already is. Genuinely cross-platform, and it would sidestep the `%%` escaping trap
  below almost entirely. Rejected for now because roughly half of what
  `calculate-project-version.sh` says is bash-specific defensive reasoning that a reviewer has
  already read and a suite already pins — the `read` difference between bash 5.2 and 5.3, musl's
  regex leftmost-match, CRLF, git's stderr, zero-padded tags. Reimplementing that in another
  language is a rewrite of release-critical logic to buy an agent pool we do not need. It stays
  the fallback if a consumer ever has to build on Windows.
- **A cmd/bash polyglot trampoline** — a leading `:<<'WINDOWS'` heredoc that cmd reads as a label
  and bash skips, whose Windows branch re-invokes the file through the `bash.exe` that Git for
  Windows installs next to the `git.exe` the agents already use. It works, and it is the only
  option that keeps the Windows agents. Rejected: bash re-reading the `.cmd` also executes TeamCity's
  own `@echo off` and `rem` preamble and reports two errors per build, the Git-for-Windows bash
  is an undeclared dependency, and the whole construction is a puzzle in a file that decides
  which version gets published.
- **An agent requirement on the failing build configuration only.** Rejected: 38 configurations
  use this meta-runner and 17 of them can still land on Windows. The constraint belongs to the
  runner, which knows it is bash, not to each caller, which does not. TeamCity drops XML
  comments when it round-trips a meta-runner, so this file is the only copy of the reasoning
  that survives on a server.

## Consequences

Configurations that can currently land on a Windows agent lose those agents and keep the rest.
That is not a new regime: 21 of the 38 consumers of this meta-runner, and all 31 consumers of
`OctopusCheckReleaseVersionIsNew`, are already restricted to non-Windows agents by their own
settings — which is precisely why the second bash meta-runner has never hit this fault.

No absolute agent counts appear here on purpose. The pool is elastic: the same configuration
measured 34 compatible agents (12 of them Windows) and, an hour later, 54 (17 Windows). Any
runbook comparing against a remembered number is wrong before it is followed.

`OctopusCheckReleaseVersionIsNew` declares the requirement too, although all 31 of its consumers
are already restricted and it therefore changes nothing today. Those restrictions are incidental
— each configuration carries its own, and a configuration created later from the wrong starting
point would be eligible for a Windows agent and fail with an unexplained exit 255 during release
post-processing, which is the worst moment to learn it. A constraint that belongs to the runner
is declared on the runner.

This was argued the other way first, on the grounds that the check below cannot fail for that
runner, so the requirement could never be shown to have taken effect. That conflates two
questions. Whether TeamCity propagates `<requirements>` to configurations that already carry a
step is one global question about TeamCity, answered once, on a runner where it *is* observable.
Whether a runner declares the constraint is a fact about this repository, asserted by its test
suite. Only the first needs an upload to answer.

### Verifying an upload

Because a meta-runner is stored by runner type and resolved at build time, re-uploading it should
apply the requirement to configurations that already carry the step. TeamCity does not document
this for `<requirements>`, so it is verified, not assumed — and verified as a property rather
than a count, since counts move on their own:

1. Pick a configuration that **can currently land on a Windows agent** — one whose compatible
   list still contains agents whose OS is Windows. Only those can show the change. On the other
   21, and on every consumer of `OctopusCheckReleaseVersionIsNew`, the check cannot fail, so it
   proves nothing there: answer the propagation question once, here.
2. After uploading, inspect this endpoint for **every affected configuration**. In each compatible
   agent list, no Windows agent may remain and at least one non-Windows agent must remain:

   ```
   GET /app/rest/agents?locator=compatible:(buildType:(id:<btId>)),authorized:true,connected:any,count:500
   ```

   If Windows agents are still listed, requirements are copied at add-time, every affected
   configuration needs the requirement itself, and the Kotlin rewrite becomes the cheaper answer.
   If no agent remains, do not queue the configuration: its own requirements conflict with the
   meta-runner's constraint. Restore a compatible non-Windows agent, relax the conflicting caller
   requirement, or replace the bash step with the Kotlin implementation.
3. Then run **one build** on the Windows-capable configuration before relying on the change across
   the fleet, and read its log. The agent count says nothing about the `%` escaping, which has the
   file, and read its log. The agent count says nothing about the `%` escaping, which has the
   larger blast radius and cannot be verified by any test in this repository:
   - the step must print a real `Release line:` and a `##teamcity[buildNumber …]`;
   - a service message must carry **its text**, not a bare `%`. If the escaping model were wrong,
     `printf '%%s'` would reach the agent unchanged, print `%` and drop its argument, so every
     `buildProblem` and message across all 69 configurations would say `%` and nothing else —
     silent, and only on error paths nobody exercises.

## The related trap: `%` in `script.content`

TeamCity resolves parameter references inside `script.content`, where `%%` is the escape for one
literal `%`. The agent therefore receives the embedded script with every `%%` already collapsed,
which turned bash's longest-match `${var%%pattern}` into the shortest-match `${var%pattern}`: the
newest-tag fallback returned the whole tag list but its last line, and the trailing-space trim
dropped one blank instead of all of them. The repository's copy of the script was correct
throughout; only what the server ran was wrong, and the drift test compared the two copies
byte-for-byte, so it saw nothing.

Every `%` in both embedded copies is now doubled, and the drift test escapes the source the same
way before comparing. Doubling *every* `%`, not only the pairs, is deliberate: a lone `%` does
survive resolution today, but relying on that is how `${var%%…}` got shipped in the first place,
and full escaping also makes a stray `%PARAM%` in the script body impossible to resolve.
