#!/bin/sh
#
# FEAT-021 — stamp the built bundle's CFBundleVersion from git, on every build.
#
# Runs as the last build phase of both HermesMobile and HermesLiveActivity (see
# `postBuildScripts` in project.yml), which is the only place that survives two
# things at once: `xcodegen generate`, which rewrites the .xcodeproj from
# project.yml and erases anything written into the project by hand, and a plain
# Cmd-R in Xcode, which is how a build actually reaches the phone.
#
# The number is `git rev-list --count HEAD` — the number of commits behind the
# code being built. Properties, stated honestly:
#
#   * It rises on every commit, so it rises on every build of new work, with
#     nobody remembering to bump anything.
#   * Two builds of the *same* commit get the *same* number. That is deliberate:
#     the number's job is to name the code a phone is running, and a number that
#     changed while the code did not would stop naming anything.
#   * It can go DOWN when checking out a branch behind main. Monotonic along
#     main is the guarantee; monotonic across arbitrary checkouts is not.
#   * Uncommitted edits do not move it. A build made on a dirty tree carries the
#     number of its last commit.
#
# MARKETING_VERSION is deliberately untouched: which release this is stays a
# human decision (FEAT-002's rules), and so does `git tag`.
#
# BUG-064 changed two things about how this fails, and both are reversals of
# what the header used to say.
#
#   1. **It now fails the build.** The old text read "a build that says the
#      wrong number is a smaller problem than a Cmd-R that does not run", and
#      every failure path warned and exited 0. That is true for a phone and
#      false for a submission: an .ipa whose embedded extension carries a
#      different CFBundleVersion than its host app is rejected at App Store
#      Connect validation, and the fallback `0` in project.yml is below every
#      build this project could ever ship, which is separately an upload
#      monotonicity rejection. Both of those are silent until the upload. A
#      build that stops with an error naming the plist it could not write is
#      strictly cheaper than an archive that looks fine and is not.
#
#   2. **The app target stamps the extension it has embedded, not only its own
#      plist.** Both targets carry this phase and both declare
#      `basedOnDependencyAnalysis: false`, so neither can be skipped as up to
#      date — but a run-script phase with no declared outputs is not part of the
#      .appex product's producer chain, so under parallel target builds the
#      app's copy task can consume the .appex before the extension's script has
#      rewritten its plist. The observed symptom was exactly that: one gate red
#      with the app at 301 and the embedded appex at 2, a sibling gate green at
#      the same tip. Stamping the *embedded* copy — which the app's own phase
#      runs after, verified in the generated project: Embed Foundation
#      Extensions precedes this phase — removes the ordering question instead of
#      trying to win it. The extension keeps its own phase, so in the healthy
#      case the embedded plist already agrees and this writes nothing.
#
#   3. **The app's own plist needed the same ordering guarantee and did not
#      get it until 2026-08-30.** A stamp only survives if nothing writes the
#      plist afterwards, and Xcode's own ProcessInfoPlistFile does exactly
#      that: it re-expands CFBundleVersion from CURRENT_PROJECT_VERSION, which
#      is the fallback 0. With no declared inputs these phases had no edge to
#      that task, and on an incremental build they ran first and were undone —
#      app 0, embedded .appex 415, which is the same submission blocker seen
#      from the other side. The fix is not in this file: both phases now
#      declare their built Info.plist as an `inputFiles` entry in project.yml,
#      and that is what orders them after the task that produces it. If a
#      bundle ever reports 0 again, check that those inputFiles survived
#      `xcodegen generate` before looking here.
#
# Standalone: `sh scripts/stamp-build-number.sh` prints the number it would
# stamp and writes nothing.

set -u

# The highest build App Store Connect has processed an upload of for the current
# MARKETING_VERSION. It is 0 because nothing has been uploaded yet.
#
# Processed, not approved: App Store Connect requires every upload for a
# marketing version to carry a higher build string than any earlier upload it
# processed, whether or not App Review ever approved that upload. So raise this
# floor after each processed upload, to that upload's number — a rejected or
# withdrawn build still burns its number.
#
# It is NOT the same concept as project.yml's CURRENT_PROJECT_VERSION, which is
# the never-ship sentinel a bundle carries when the stamp phase did not run at
# all. They are different concepts. They coincided at 0 until the first
# processed upload, 1.0.0 (3) on 2026-10-13, raised the floor to 3; leave the
# sentinel at 0 forever. This guard tests the *derived* commit count, and the
# sentinel is caught on the other side by BuildNumberTests reading the built
# bundle.
ACCEPTED_BUILD_FLOOR=3

warn() { echo "warning: FEAT-021 build number: $*"; }
fail() { echo "error: FEAT-021 build number: $*"; exit 1; }

REPO="${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"

BUILD="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || true)"
case "$BUILD" in
    '' | *[!0-9]*)
        # Was warn-and-continue. A build with no git metadata — an exported zip,
        # a detached copy — leaves BOTH bundles on project.yml's fallback of 0,
        # which is the never-ship sentinel and is below every build this project
        # could ship. Uploading it is rejected; not noticing until then is the
        # expensive part.
        fail "git could not count the commits in \"$REPO\", so no build number can be derived. Build from a git checkout, or set CURRENT_PROJECT_VERSION deliberately and remove this phase."
        ;;
esac

# Not an Xcode build phase: say what would be stamped and stop. Print mode
# reports the derived count even when it is at or below the accepted-build
# floor so a local check still answers "what number would this stamp".
if [ -z "${TARGET_BUILD_DIR:-}" ] && [ -z "${INFOPLIST_PATH:-}" ]; then
    echo "$BUILD"
    exit 0
fi

# App Store Connect rejects a build number that is not greater than every build
# it has already processed an upload of for the version, so a derived count at
# or below ACCEPTED_BUILD_FLOOR must not reach an archive. At floor 0 this
# catches only the genuinely impossible case (a tree with zero commits); after
# the first processed upload raises the floor, it catches a checkout behind the
# last uploaded tip as well. Test hosts and SwiftUI previews are exempt: they still need a
# buildable product even when the checkout is thin, and they never go to App
# Store Connect.
is_test_or_preview=0
case "${TARGET_NAME:-}" in
    *Tests|*UITests) is_test_or_preview=1 ;;
esac
if [ "${ENABLE_PREVIEWS:-}" = "YES" ] || [ "${XCODE_RUNNING_FOR_PREVIEWS:-}" = "1" ]; then
    is_test_or_preview=1
fi
if [ "$is_test_or_preview" != 1 ] && [ "$BUILD" -le "$ACCEPTED_BUILD_FLOOR" ]; then
    fail "derived build number $BUILD is not above the accepted-build floor $ACCEPTED_BUILD_FLOOR, so App Store Connect would reject it. Build from a checkout at or ahead of the last shipped tip, or set CURRENT_PROJECT_VERSION deliberately and remove this phase."
fi

PLISTBUDDY=/usr/libexec/PlistBuddy

# Re-sign a bundle whose Info.plist this script just rewrote.
#
# The embed phase copies the .appex without Code Sign On Copy, so the signature
# it carries is the one its own target's build produced — and editing a sealed
# bundle's Info.plist invalidates it. In the healthy case `stamp` writes nothing
# and this never runs; when it does run, an unsigned nested bundle is a failure
# to install, which is worse than the wrong number this is fixing.
resign() {
    _bundle="$1"
    _label="$2"
    # Unsigned test/simulator builds set CODE_SIGNING_ALLOWED=NO and never
    # expect a nested signature. Everything else must re-sign after the rewrite.
    [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] || return 0
    _identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    # stamp() already rewrote Info.plist. An empty identity here means the seal
    # is broken and the build must stop rather than report success.
    [ -n "$_identity" ] || fail "rewrote CFBundleVersion in $_label but EXPANDED_CODE_SIGN_IDENTITY is empty; the bundle's signature is now invalid"
    if codesign --force --sign "$_identity" \
        --preserve-metadata=identifier,entitlements,flags "$_bundle" >/dev/null 2>&1; then
        echo "note: FEAT-021: re-signed $_label after stamping it"
        return 0
    fi
    # A bundle with nothing to preserve (never signed) rejects the flag rather
    # than ignoring it.
    if codesign --force --sign "$_identity" "$_bundle" >/dev/null 2>&1; then
        echo "note: FEAT-021: re-signed $_label after stamping it"
        return 0
    fi
    fail "rewrote CFBundleVersion in $_label but could not re-sign it; the bundle's signature is now invalid"
}

# stamp <plist> <label> [bundle-to-resign]
stamp() {
    _plist="$1"
    _stamp_label="$2"
    _resign_bundle="${3:-}"
    [ -f "$_plist" ] || fail "no built Info.plist at \"$_plist\" for $_stamp_label"
    _current="$("$PLISTBUDDY" -c "Print :CFBundleVersion" "$_plist" 2>/dev/null || true)"
    if [ "$_current" = "$BUILD" ]; then
        return 0
    fi
    if [ -z "$_current" ]; then
        _action="Add :CFBundleVersion string $BUILD"
    else
        _action="Set :CFBundleVersion $BUILD"
    fi
    "$PLISTBUDDY" -c "$_action" "$_plist" >/dev/null 2>&1 \
        || fail "could not write CFBundleVersion into \"$_plist\"; it still says \"${_current:-unset}\" and the app will say $BUILD"
    echo "note: FEAT-021: $_stamp_label CFBundleVersion ${_current:-unset} -> $BUILD"
    if [ -n "$_resign_bundle" ]; then
        resign "$_resign_bundle" "$_stamp_label"
    fi
    return 0
}

# This target's own product.
stamp "${TARGET_BUILD_DIR:-}/${INFOPLIST_PATH:-}" "${PRODUCT_NAME:-target}"

# And, for the app, everything it has already embedded. This is the leg that
# makes the mismatch impossible rather than unlikely: whatever the extension's
# own phase did or did not manage, the bundle that ships is the one under
# PlugIns and this stamps that one.
if [ "${WRAPPER_EXTENSION:-}" = "app" ]; then
    PLUGINS="${TARGET_BUILD_DIR:-}/${PLUGINS_FOLDER_PATH:-${CONTENTS_FOLDER_PATH:-}/PlugIns}"
    if [ -d "$PLUGINS" ]; then
        FOUND=0
        for APPEX in "$PLUGINS"/*.appex; do
            [ -d "$APPEX" ] || continue
            FOUND=1
            stamp "$APPEX/Info.plist" "$(basename "$APPEX")" "$APPEX"
        done
        if [ "$FOUND" != 1 ]; then
            fail "\"$PLUGINS\" exists but contains no .appex; the embed phase produced nothing to stamp"
        fi
    else
        # This project embeds HermesLiveActivity. Missing PlugIns means the
        # embed phase did not run, so the .appex the App Store would validate
        # was never stamped. Fail rather than warn.
        fail "no embedded extensions found at \"$PLUGINS\"; the embed phase did not produce a PlugIns directory to stamp"
    fi
fi
