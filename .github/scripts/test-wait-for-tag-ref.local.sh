#!/usr/bin/env bash
# Local runner for the same cases the CI workflow asserts. Uses a stub `gh` on PATH so no
# network and no real repository are involved; the stub decides how many lookups fail first.
set -uo pipefail
S="$PWD/.github/scripts/wait-for-tag-ref.sh"
stub_dir=$(mktemp -d); trap 'rm -rf "$stub_dir"' EXIT
cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
# Stands in for `gh`. Accepts ONLY the lookup that `gh release create --verify-tag` itself
# performs — the GraphQL repository.ref(qualifiedName:) query (cli/cli pkg/cmd/release/create/
# http.go, remoteTagExists). Any other lookup, the REST ref endpoint included, is rejected on
# every attempt: REST can answer while GraphQL is still stale, so polling it proves nothing.
[ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ] || {
    echo "stub: refusing non-GraphQL lookup: $*" >&2; exit 1
}
printf '%s\n' "$@" | grep -q 'ref(qualifiedName:' || {
    echo "stub: query does not resolve a ref: $*" >&2; exit 1
}
# The tag must be asked for as a FULLY QUALIFIED ref. GraphQL matches qualifiedName literally,
# so "v1.2.3" instead of "refs/tags/v1.2.3" would never resolve — and without this assertion a
# script that dropped the prefix would pass every case here while never working in production.
printf '%s\n' "$@" | grep -qx "tagName=refs/tags/${EXPECT_TAG}" || {
    echo "stub: tagName is not refs/tags/${EXPECT_TAG}: $*" >&2; exit 1
}
# Emit a realistic response and apply the caller's own --jq filter to it, rather than emitting
# what a correct filter would have produced. Otherwise the filter is never under test: an
# absent tag yields the JSON below, and it is the filter's job to turn that into nothing.
filter=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && filter="$a"; prev="$a"; done
n=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$COUNTER"
if [ "$n" -le "${FAIL_TIMES:-0}" ]; then
    case "${FAIL_MODE:-error}" in
        # GraphQL reports an absent tag as a SUCCESSFUL response carrying a null ref, so the
        # exit status says nothing about whether the tag is there.
        null) body='{"data":{"repository":{"ref":null}}}' ;;
        *)    echo "gh: HTTP 502" >&2; exit 1 ;;
    esac
else
    body='{"data":{"repository":{"ref":{"id":"REF_kwDOabcdef"}}}}'
fi
if [ -n "$filter" ]; then printf '%s' "$body" | jq -r "$filter"; else printf '%s' "$body"; fi
STUB
chmod +x "$stub_dir/gh"; export PATH="$stub_dir:$PATH"
export WAIT_ATTEMPTS=5 WAIT_INTERVAL=0 EXPECT_TAG=v1.2.3

pass=0; fail=0
check() { # name expected_rc actual_rc
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1));
  else echo "  FAIL $1 — expected rc=$2, got rc=$3"; fail=$((fail+1)); fi
}
run() { COUNTER=$(mktemp) FAIL_TIMES=$1 bash "$S" octopusden/x v1.2.3 >/dev/null 2>&1; echo $?; }

echo "case: visible immediately";         check "rc 0" 0 "$(run 0)"
echo "case: visible on 3rd attempt";      check "rc 0" 0 "$(run 2)"
echo "case: never visible within budget"; check "rc 1" 1 "$(run 99)"
echo "case: empty ref is not visible";    check "rc 1" 1 "$(FAIL_MODE=null run 99)"
echo "case: empty ref then visible";      check "rc 0" 0 "$(FAIL_MODE=null run 2)"
echo "--- passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
