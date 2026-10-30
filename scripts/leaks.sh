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
if grep -rIlF -e "$HOME" -e "$(pwd -P)" -e "$(escaped "$HOME")" -e "$(escaped "$(pwd -P)")" forms adversarial modular captures; then
  echo "leaks.sh: the files above hold an absolute path of this Mac" >&2
  found=1
fi
uuids=$(grep -raoE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' captures | grep -vE ':00000000-0000-0000-0000-[0-9]{12}$' | cut -d: -f1 | sort -u)
if [ -n "$uuids" ]; then
  printf '%s\n' "$uuids"
  echo "leaks.sh: the files above hold a device's or simulator's id" >&2
  found=1
fi
exit $found
