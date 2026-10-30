#!/bin/sh
# Fails when a committed fixture holds something of the Mac that made it: a path of its home folder or of this
# checkout, as written or as JSON escapes each slash (`\/`), or the id of one of its devices or simulators, which
# captures number from 00000000-0000-0000-0000-000000000001 instead. Ids are looked for in binary files too: an archived
# attachment can hold one as text.
# scripts/leaks.sh
set -eu
cd "$(dirname "$0")/.."
escaped() { printf '%s' "$1" | sed 's#/#\\/#g'; }
found=0
if grep -rIlF -e "$HOME" -e "$(pwd -P)" -e "$(escaped "$HOME")" -e "$(escaped "$(pwd -P)")" forms adversarial modular field captures; then
  echo "leaks.sh: the files above hold an absolute path of this Mac" >&2
  found=1
fi
# A temporary folder of this Mac (`/var/folders/…`, `/private/var/folders/…`), as written or with JSON's escaped slashes,
# in any file, binaries included: what a capture's neutraliser rewrites, so the two never disagree.
if grep -ralE '(/|\\/)var(/|\\/)folders(/|\\/)' forms adversarial modular field captures 2> /dev/null; then
  echo "leaks.sh: the files above hold a temporary folder of this Mac" >&2
  found=1
fi
# Any user's home folder, not only this Mac's, as written or JSON-escaped, macOS's own `USER` placeholder included, and
# any Linux one: a capture holds no one's, as xcrew's own privacy test checks every committed file.
if grep -ralE '(/|\\/)(U[s]ers|h[o]me)(/|\\/)' forms adversarial modular field captures 2> /dev/null; then
  echo "leaks.sh: the files above hold a user's home folder" >&2
  found=1
fi
uuids=$(grep -raoE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' captures | grep -vE ':00000000-0000-0000-0000-[0-9]{12}$' | cut -d: -f1 | sort -u)
if [ -n "$uuids" ]; then
  printf '%s\n' "$uuids"
  echo "leaks.sh: the files above hold a device's or simulator's id" >&2
  found=1
fi
exit $found
