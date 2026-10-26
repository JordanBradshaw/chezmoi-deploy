#!/usr/bin/env bash
#
# Summarise a lock change as markdown for a PR body.
#
# Usage: lock-diff.sh OLD_LOCK NEW_LOCK TOOLS_LOCK
#
#   OLD_LOCK, NEW_LOCK  apps/locks/<profile>.lock (name<TAB>source<TAB>version)
#   TOOLS_LOCK          build-tools.sh's tools.lock
#                       (name source version sha256 how)
#
# Prints one "- NAME OLD → NEW" line per changed version ("(new)" / "(removed)"
# for tools added / dropped), then a "### Not built" list of tools whose how is
# fallback-cache or fallback-release. Prints nothing when no version changed.

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: ${0##*/} OLD_LOCK NEW_LOCK TOOLS_LOCK" >&2
    exit 2
fi

changes="$(awk -F'\t' '
    /^#/ || NF < 3 { next }
    FNR == NR { old[$1] = $3; next }
    { new[$1] = $3 }
    END {
        for (n in new) names[n] = 1
        for (n in old) names[n] = 1
        for (n in names) {
            o = (n in old) ? old[n] : "(new)"
            v = (n in new) ? new[n] : "(removed)"
            if (o != v) print "- " n " " o " → " v
        }
    }' "$1" "$2" | LC_ALL=C sort)"

[[ -n $changes ]] || exit 0
echo "$changes"

awk -F'\t' '
    /^#/ || NF < 5 { next }
    $5 == "fallback-cache" || $5 == "fallback-release" {
        if (!shown++) print "### Not built"
        print "- " $1 " (" $5 ")"
    }' "$3"
