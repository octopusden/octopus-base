#!/usr/bin/env bash
#
# Runs the Maven Central publication guard's inspection against a hand-built local repository.
#
# The Python is read out of common-java-gradle-release.yml, so what runs here is the text the
# workflow runs. No Gradle: the guard only reads files off disk, so crafted archives exercise every
# branch in a second — including combinations no real build in this organisation produces yet.
#
# The two axes are what this covers. "Not a library" (an -all classifier, a BOOT-INF/ entry) now
# has a destination, so its bypass is deprecated; "a big library" is legitimate and has its own
# narrow list. The list for the second must not admit the first, which is the assertion that makes
# the split worth anything.
#
# Usage: bash .github/scripts/test/central-guard-fixture.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
WORKFLOW="$root/.github/workflows/common-java-gradle-release.yml"
[ -f "$WORKFLOW" ] || { echo "common-java-gradle-release.yml not found"; exit 1; }

pass=0; fail=0
tmp="$(mktemp -d)"
GUARD="$tmp/guard.py"

# The heredoc body of the guard's inspection. Anchored on the step name and the marker, for the
# reason the routing fixture learned the hard way: a looser match eats body lines. Dedented,
# because the body carries the YAML block's indentation and Python — unlike Groovy — cares.
awk '
  /- name: Guard against publishing fat jars to Maven Central/ { instep = 1 }
  instep && !inbody && /python3 - .* <<.PY./ { inbody = 1; next }
  inbody && $1 == "PY" { exit }
  inbody { print }
' "$WORKFLOW" | python3 -c 'import sys, textwrap; sys.stdout.write(textwrap.dedent(sys.stdin.read()))' > "$GUARD"
opens="$(grep -c 'def \|for \|if ' "$GUARD" || true)"
if [ ! -s "$GUARD" ] || ! grep -q 'oversize' "$GUARD" || [ "$opens" -lt 5 ]; then
  echo "FAIL  could not extract the guard's Python from $WORKFLOW (step renamed, or the heredoc changed)"
  sed 's/^/    /' "$GUARD"
  exit 1
fi
python3 -c "compile(open('$GUARD').read(), 'guard', 'exec')" || {
  echo "FAIL  extracted Python does not compile — the extractor dropped a line"
  exit 1
}

# A local repository laid out the way publishToMavenLocal leaves one:
#   <group path>/<artifactId>/<version>/<file>
m2="$tmp/m2"
python3 - "$m2" <<'PY'
import sys, zipfile
from pathlib import Path

repo = Path(sys.argv[1])

def jar(artifact, filename, entries, pad=0):
    d = repo / "org" / "fixture" / artifact / "1.0"
    d.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(d / filename, "w") as z:
        for name, body in entries.items():
            z.writestr(name, body)
        if pad:
            # Stored, not deflated: the guard measures the file on disk, and random-ish
            # incompressible bytes are the cheapest way to reach a real size.
            z.writestr("padding.bin", bytes(range(256)) * (pad * 4096),
                       compress_type=zipfile.ZIP_STORED)

MAIN = "Manifest-Version: 1.0\nMain-Class: org.fixture.Main\n"
SHADED = {f"{r}/C.class": "x" for r in ("kotlin", "org", "com", "net", "io")}

# A thin library that happens to declare Main-Class — ordinary, and the reason the shaded
# heuristic cannot fire on Main-Class alone.
jar("thin", "thin-1.0.jar", {"META-INF/MANIFEST.MF": MAIN, "org/fixture/A.class": "x"})
# Recognized executable artifacts: by name, and by marker.
jar("fat", "fat-1.0-all.jar", {"org/fixture/A.class": "x"})
jar("boot", "boot-1.0.jar", {"BOOT-INF/classes/A.class": "x"})
# A genuine library that is merely large: no Main-Class, one package root.
jar("biglib", "biglib-1.0.jar", {"org/fixture/A.class": "x"}, pad=400)
# A shadow jar with the classifier stripped: no -all, no BOOT-INF/, only size and shape.
jar("stripped", "stripped-1.0.jar", {"META-INF/MANIFEST.MF": MAIN, **SHADED}, pad=400)
PY

# guard <fat-allowlist> <oversize-allowlist> -> output in $tmp/out, status in $tmp/rc
guard() {
  FAT_JAR_ALLOWLIST="$1" OVERSIZE_ALLOWLIST="$2" MAX_ARTIFACT_MB=1 \
    python3 "$GUARD" "$m2" > "$tmp/out" 2>&1
  echo $? > "$tmp/rc"
}

check() {
  local rc=$?
  if [ "$rc" = "0" ]; then echo "PASS  $1"; pass=$((pass+1)); else
    echo "FAIL  $1 ($2)"; fail=$((fail+1))
    echo "--- guard output:"; sed 's/^/    /' "$tmp/out"
  fi
}

echo "-- with no exceptions, every unfit artifact is refused --------------------"
guard "" ""
[ "$(cat "$tmp/rc")" != "0" ]; check "fails the release" "the guard passed a publication set containing a fat jar"
grep -q 'fat-1.0-all.jar' "$tmp/out"; check "names the -all artifact" "the -all classifier was not reported"
grep -q 'boot-1.0.jar' "$tmp/out"; check "names the BOOT-INF artifact" "the Spring Boot marker was not reported"
grep -q 'biglib-1.0.jar' "$tmp/out"; check "names the oversized library" "the size rule did not fire"
! grep -q 'thin-1.0.jar.*—' "$tmp/out"; check \
  "leaves a thin jar with Main-Class alone" \
  "a small library declaring Main-Class was reported — Main-Class alone must never be a violation"

echo "-- oversize-library-allowlist covers size, and ONLY size -----------------"
guard "" "biglib"
grep -q 'biglib' "$tmp/out" && ! grep -qE '^  biglib.*—' "$tmp/out"; check \
  "admits a legitimately large library" "biglib was still refused despite being listed"
guard "" "fat,boot"
[ "$(cat "$tmp/rc")" != "0" ]; check \
  "does NOT admit an executable artifact" \
  "the size-only list let an -all jar or a BOOT-INF jar onto Central, which is the whole point of splitting the lists"
grep -qE 'fat-1\.0-all\.jar.*shadow/uber' "$tmp/out"; check \
  "still reports why the executable artifact is unfit" "the reason was lost"

echo "-- the deprecated list still works, and says so ---------------------------"
guard "fat" ""
grep -q 'title=fat-jar-publication-allowlist is deprecated' "$tmp/out"; check \
  "warns that the input is deprecated" "no deprecation warning, so consumers get no signal to migrate"
grep -q 'github-packages-publications' "$tmp/out"; check \
  "points at the replacement" "the warning does not say what to do instead"
! grep -qE '^  fat:' "$tmp/out"; check \
  "still admits the artifact" "the deprecated input stopped working, which would break consumers before they have migrated"

echo "-- a shadow jar with the classifier stripped is surfaced, not blocked -----"
# On its own, so the exit status reflects the heuristic and nothing else: the repository above also
# holds artifacts that are refused for unrelated reasons.
lone="$tmp/m2-stripped"
mkdir -p "$lone/org/fixture/stripped/1.0"
cp "$m2/org/fixture/stripped/1.0/stripped-1.0.jar" "$lone/org/fixture/stripped/1.0/"
FAT_JAR_ALLOWLIST="" OVERSIZE_ALLOWLIST="stripped" MAX_ARTIFACT_MB=1 \
  python3 "$GUARD" "$lone" > "$tmp/out" 2>&1
echo $? > "$tmp/rc"

grep -q 'title=Unclassified jar looks like a shadow jar' "$tmp/out"; check \
  "warns about the hidden shape" "a 1.5 MB jar with Main-Class and five package roots drew no warning, so this shape stays invisible"
grep -q 'stripped-1.0.jar' "$tmp/out"; check "names it" "the warning does not identify the artifact"
[ "$(cat "$tmp/rc")" = "0" ]; check \
  "does not fail the release on the heuristic" \
  "the heuristic blocked a release — Main-Class plus a package-root count is not certain enough to gate on"
guard "" ""
! grep -q 'title=Unclassified jar looks like a shadow jar.*thin-1.0.jar' "$tmp/out"; check \
  "does not warn about an ordinary thin jar" "the heuristic fired on a small single-root jar, which would make it noise"

echo
echo "passed=$pass failed=$fail"
rm -rf "$tmp"
[ "$fail" -eq 0 ]
