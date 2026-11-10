#!/bin/sh
# Legacy-pattern ratchet: fail if any ast-grep rule count goes up vs. the base.
# Usage: .ast-grep/ratchet.sh <base-ref>   (run from anywhere inside the repo)
# Needs: ast-grep (0.51.1), jq, git. No baseline file: both sides are counted
# with this checkout's .ast-grep/ rules.
set -eu

if [ $# -ne 1 ]; then
  echo "usage: $0 <base-ref>" >&2
  exit 2
fi
base_ref=$1

root=$(git rev-parse --show-toplevel)
cd "$root"

# count <dir>: prints "<ruleId> <count>" per rule, sorted by rule id
count() {
  # scan to a file first so an ast-grep failure stops the script (no pipefail in sh)
  (cd "$1" && ast-grep scan -c .ast-grep/sgconfig.yml --json=stream . >"$tmp/scan.json")
  jq -r .ruleId "$tmp/scan.json" | sort | uniq -c | awk '{print $2, $1}'
}

tmp=$(mktemp -d)
wt="$tmp/base"
cleanup() {
  git worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

base_sha=$(git merge-base "$base_ref" HEAD)

count "$root" >"$tmp/head.txt"

git worktree add --quiet --detach "$wt" "$base_sha"
rm -rf "$wt/.ast-grep"
cp -R "$root/.ast-grep" "$wt/.ast-grep"
count "$wt" >"$tmp/base.txt"

# Rule ids from both sides plus every rule file, so zero-count rules show up.
for f in "$root"/.ast-grep/rules/*.yml; do
  sed -n 's/^id:[[:space:]]*//p' "$f"
done >"$tmp/ids.txt"

echo "ast-grep ratchet: base $base_ref ($base_sha) vs HEAD"
awk '
  FILENAME == ARGV[1] { base[$1] = $2; ids[$1] = 1; next }
  FILENAME == ARGV[2] { head[$1] = $2; ids[$1] = 1; next }
  { ids[$1] = 1 }
  END {
    printf "%-28s %6s %6s %7s\n", "rule", "base", "head", "change"
    n = 0
    for (id in ids) sorted[++n] = id
    for (i = 2; i <= n; i++) {           # insertion sort, portable awk
      v = sorted[i]; j = i - 1
      while (j > 0 && sorted[j] > v) { sorted[j + 1] = sorted[j]; j-- }
      sorted[j + 1] = v
    }
    rose = ""
    for (i = 1; i <= n; i++) {
      id = sorted[i]; b = base[id] + 0; h = head[id] + 0; d = h - b
      printf "%-28s %6d %6d %+7d\n", id, b, h, d
      if (d > 0) rose = rose " " id
    }
    if (rose != "") {
      print ""
      print "FAIL: legacy-pattern count rose for:" rose
      print "Use the preferred pattern named in the rule message (ast-grep scan -c .ast-grep/sgconfig.yml)."
      exit 1
    }
    print ""
    print "OK: no legacy-pattern count rose."
  }
' "$tmp/base.txt" "$tmp/head.txt" "$tmp/ids.txt"
