#!/bin/sh
#
# FEAT-021 — does the changelog still describe what is about to ship?
#
# Reads every commit subject since the last release, collects the BUG-0NN and
# FEAT-0NN ids named in them, and asks whether CHANGELOG.md's Unreleased section
# mentions each one. It is a check, not a generator: entries written by hand say
# what changed for a person holding the phone, and anything derived from commit
# subjects would be worse than what is there now (FEAT-021's report says so
# outright). So this asks the question and never answers it in the file.
#
# "The last release" is the most recent git tag, because tags are cut by hand
# when a build actually goes on a phone (FEAT-002's fourth rule). Until the first
# tag exists there are none, so the fallback is the commit that added
# CHANGELOG.md — everything after it belongs in the unreleased batch.
#
# Standalone:    sh scripts/check-changelog.sh            (exit 1 when something is missing)
# In the build:  sh "$SRCROOT/scripts/check-changelog.sh" --warn-only
#
# Options:
#   --repo DIR        repository to read (default: $SRCROOT, else the script's parent)
#   --changelog PATH  changelog to read (default: <repo>/CHANGELOG.md)
#   --base REF        compare against REF instead of the last tag
#   --warn-only       always exit 0, printing anything wrong as an Xcode `warning:` line
#   -h, --help        this text

set -u

usage() { sed -n '3,26p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; }

WARN_ONLY=0
REPO=""
CHANGELOG=""
BASE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:-}"; shift 2 ;;
        --changelog) CHANGELOG="${2:-}"; shift 2 ;;
        --base) BASE="${2:-}"; shift 2 ;;
        --warn-only) WARN_ONLY=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "check-changelog.sh: unknown option \"$1\"" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$REPO" ] || REPO="${SRCROOT:-}"
[ -n "$REPO" ] || REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
[ -n "$CHANGELOG" ] || CHANGELOG="$REPO/CHANGELOG.md"

FAILED=0
problem() {
    if [ "$WARN_ONLY" -eq 1 ]; then
        echo "warning: CHANGELOG: $*"
    else
        echo "check-changelog.sh: $*" >&2
    fi
    FAILED=1
}
finish() {
    [ "$WARN_ONLY" -eq 1 ] && exit 0
    exit "$FAILED"
}

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "note: CHANGELOG: \"$REPO\" is not a git repository; nothing to check against"
    exit 0
fi

if [ ! -f "$CHANGELOG" ]; then
    problem "no changelog at \"$CHANGELOG\""
    finish
fi

if [ -z "$BASE" ]; then
    BASE="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || true)"
fi
if [ -z "$BASE" ]; then
    BASE="$(git -C "$REPO" log --diff-filter=A --format=%H -- "$(basename -- "$CHANGELOG")" 2>/dev/null | tail -1)"
fi
if [ -z "$BASE" ]; then
    echo "note: CHANGELOG: no tag and no changelog history to measure from; nothing to check"
    exit 0
fi

IDS="$(git -C "$REPO" log --format=%s "$BASE..HEAD" 2>/dev/null |
    grep -oE '([Bb][Uu][Gg]|[Ff][Ee][Aa][Tt])-[0-9]{3}' |
    tr '[:lower:]' '[:upper:]' |
    sort -u)"

# The Unreleased section: from the first `## ...Unreleased...` heading to the
# next `## ` heading.
SECTION="$(awk '
    /^## / {
        if (inside) exit
        if (tolower($0) ~ /unreleased/) { inside = 1; next }
    }
    inside { print }
' "$CHANGELOG")"

if [ -z "$IDS" ]; then
    echo "note: CHANGELOG: no BUG- or FEAT- item committed since ${BASE}; nothing to check"
    exit 0
fi

if [ -z "$SECTION" ]; then
    problem "no Unreleased section in \"$CHANGELOG\", but there are items committed since ${BASE}"
    finish
fi

COUNT=0
for ID in $IDS; do
    COUNT=$((COUNT + 1))
    if ! printf '%s\n' "$SECTION" | grep -qF -- "$ID"; then
        problem "the Unreleased section does not mention $ID, which was committed since ${BASE}"
    fi
done

[ "$FAILED" -eq 0 ] && echo "note: CHANGELOG: the Unreleased section covers all $COUNT item(s) committed since ${BASE}"
finish
