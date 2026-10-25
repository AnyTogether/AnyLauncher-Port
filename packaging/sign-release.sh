#!/bin/sh
# Signs the files of an AnyPS5 Desktop release with the AnyPS5 release key, as AnyPS5-ARM's
# releases are (docs/dev/SIGNED_UPDATES.md there), so that the launcher's update check accepts it:
#
#     packaging/sign-release.sh <file>...
#
# Run on the release Mac once the Windows and Linux builds are collected in one folder; writes
# SHA256SUMS and SHA256SUMS.sig beside the first file. Attach both to the release with the
# files. Uses AnyPS5-ARM's tools/release/sign.sh: ANYPS5_ARM names that checkout (default: the
# AnyPS5-ARM folder beside this one, ../anyps5/AnyPS5). Fails when the keys built into this
# launcher (lib/core/release_keys.dart) are not the release keys.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
arm="${ANYPS5_ARM:-$here/../anyps5/AnyPS5}"
[ -x "$arm/tools/release/sign.sh" ] || { echo "no AnyPS5-ARM checkout at $arm (set ANYPS5_ARM)" >&2; exit 1; }
[ $# -gt 0 ] || { echo "usage: $0 <file>..." >&2; exit 2; }
"$arm/tools/release/embed_keys.sh" --check "$here"
"$arm/tools/release/sign.sh" "$@"
