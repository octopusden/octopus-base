# Sub-Agent Playbook: Repository Discovery & Classification

## Purpose

Produce a structured classification report for a consumer JVM repository so that the
orchestrator can fill in the template parameters required by `consumer-implementer.md`.

## Parameter (filled in by the orchestrator)

| Placeholder    | Example value              |
|----------------|----------------------------|
| `{{REPO_NAME}}`| `octopus-release-plugin`   |

---

## Procedure

Work through each detection step below.  Collect all findings; do **not** stop early.

### D1 — Build system

Check the repository root (and each directory listed in `settings.gradle.kts` / `settings.gradle`):

| File present            | Build system              |
|-------------------------|---------------------------|
| `build.gradle.kts`      | Gradle — Kotlin DSL       |
| `build.gradle`          | Gradle — Groovy DSL       |
| `pom.xml`               | Maven                     |

If multiple files exist in the root, Kotlin DSL takes precedence over Groovy DSL.

```bash
ls build.gradle.kts build.gradle pom.xml 2>/dev/null
```

### D2 — Languages

Scan `src/` recursively for source file extensions:

```bash
find . -path '*/src/*' -type f \( -name "*.kt" -o -name "*.java" -o -name "*.groovy" \) \
  -not -path '*/build/*' -not -path '*/node_modules/*' \
  | sed 's|.*\.||' | sort | uniq -c | sort -rn
```

Map extensions to `{{LANGUAGES}}` value:
- `.kt` → `kotlin`
- `.java` → `java`
- `.groovy` → `groovy`

Report all languages found; list them most-frequent first.

> **Note:** `{{FLOW_TYPE}}` (`public` | `hybrid`) is determined by the orchestrator based on
> the repo's existing build workflow, not from language detection. Do not set it here.

### D3 — CI runtime JDK

Inspect every file in `.github/workflows/`:

```bash
grep -r 'java-version' .github/workflows/ | grep -v '^Binary'
```

Extract the numeric version (e.g. `17`, `21`).
If multiple distinct values appear, flag a **conflict** for human review and use the value
from the primary build workflow (typically `build.yml` or `ci.yml`).

This value becomes `{{JAVA_VERSION}}`.

### D4 — Module structure

Check for multi-module setup:

```bash
grep 'include(' settings.gradle.kts settings.gradle 2>/dev/null
```

List every included sub-project path.  Indicate whether the project is:
- Single-module (no `include(` lines)
- Multi-module (one or more `include(` lines)

### D5 — Frontend

Check for `package.json` in any sub-project directory:

```bash
find . -name 'package.json' -not -path '*/node_modules/*'
```

Report: **yes** (path) or **no**.

### D6 — Functional / integration tests

Check for signals that the repo runs FT or integration tests:

```bash
# Docker Compose files
find . -name 'docker-compose*.yml' -not -path '*/.git/*'

# Gradle task names
grep -rwE 'integrationTest|functionalTest|FunctionalTest|IntegrationTest' \
  build.gradle.kts build.gradle */build.gradle.kts */build.gradle 2>/dev/null | head -30
grep -wE 'ft' \
  build.gradle.kts build.gradle */build.gradle.kts */build.gradle 2>/dev/null | head -30

# Sub-projects named ft or integration-test
grep -E '"ft"|"integration"' settings.gradle.kts settings.gradle 2>/dev/null
```

Record:
- Whether Docker Compose is present (path if yes)
- Gradle task names detected
- Sub-project names that suggest FT scope

This informs the `{{FT_EXCLUSIONS}}` placeholder (leave empty if none found).

### D7 — Existing workflows inventory

List all workflow files and their triggers:

```bash
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  grep -A 10 '^on:' "$f" | head -15
done
```

For each file, record:
- File name
- Triggers present (`push`, `pull_request`, `schedule`, `workflow_dispatch`, `workflow_call`)

Flag any workflow that already has `pull_request:` in addition to `push:` (these are candidates
for trigger-stripping in Step 5 of `consumer-implementer.md`).

### D8 — Coverage baseline

If the repo uses Kover (Kotlin) or JaCoCo (Java/Groovy), attempt to read the current
coverage figure:

```bash
# Kover report (if already generated)
find . -name 'report.xml' -path '*/kover/*' | head -1

# JaCoCo report
find . -name 'jacoco.xml' -o -name 'jacocoTestReport.xml' | head -5
```

Parse the `<counter type="LINE">` (JaCoCo) or `<report>` (Kover) element to extract
a percentage.  If no report exists locally, set `{{COVERAGE_ENABLED}}` based on whether
a coverage plugin is already declared in `build.gradle.kts`.

---

## Output Format

Produce a structured report in **both** JSON (machine-readable) and markdown (human-readable).

### JSON block

```json
{
  "repo": "{{REPO_NAME}}",
  "build_system": "gradle-kotlin-dsl",
  "languages": ["kotlin", "java"],
  "java_version": "17",
  "module_structure": "multi-module",
  "subprojects": ["core", "plugin", "ft"],
  "frontend": false,
  "ft_signals": {
    "docker_compose": ["ft/docker-compose.yml"],
    "gradle_tasks": ["integrationTest", "ft"],
    "ft_subprojects": ["ft"]
  },
  "ft_exclusions": "",
  "coverage_enabled": true,
  "coverage_baseline_pct": 67,
  "existing_workflows": [
    {"file": "build.yml",    "triggers": ["push", "pull_request"]},
    {"file": "release.yml",  "triggers": ["workflow_dispatch"]}
  ],
  "pull_request_trigger_conflicts": ["build.yml"]
}
```

### Markdown summary

| Field                  | Value                              |
|------------------------|------------------------------------|
| Build system           | Gradle — Kotlin DSL                |
| Languages              | kotlin, java                       |
| CI JDK                 | 17                                 |
| Module structure       | multi-module                       |
| Sub-projects           | core, plugin, ft                   |
| Frontend               | no                                 |
| FT signals             | docker-compose, task `ft`          |
| FT exclusions          | (none — orchestrator to decide)    |
| Coverage enabled       | yes — baseline 67 %                |
| PR-trigger conflicts   | `build.yml`                        |

### Recommended orchestrator parameters

```
REPO_NAME        = {{REPO_NAME}}
JAVA_VERSION     = 17
FLOW_TYPE        = <determined by orchestrator from existing build workflow>
FT_EXCLUSIONS    =
COVERAGE_ENABLED = true
LANGUAGES        = kotlin,java
```
