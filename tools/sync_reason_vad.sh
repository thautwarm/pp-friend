#!/usr/bin/env bash
# 从 spellbench-linux 重新同步 vendored 的 reason-vad。
#
# 本地改动（见 rust/vendor/reason-vad/SOURCE.md）是 last_probability 那几处，
# 这个脚本会在覆盖前先把差异打出来，覆盖后需要手动重新应用。
set -euo pipefail

SRC="${1:-$HOME/backups/projects/hola/spellbench-linux/crates/reason-vad}"
DST="$(cd "$(dirname "$0")/.." && pwd)/rust/vendor/reason-vad"

if [[ ! -d "$SRC" ]]; then
  echo "源目录不存在：$SRC" >&2
  exit 1
fi

echo "== 本地改动（覆盖后会丢，需要手工重新应用）=="
diff -ru "$SRC/src" "$DST/src" || true

echo
echo "== 覆盖 =="
rm -rf "$DST"
mkdir -p "$(dirname "$DST")"
cp -R "$SRC" "$DST"
rm -rf "$DST/target"
echo "已同步到 $DST"
echo "别忘了重新应用 last_probability 那几处改动（SOURCE.md 里有清单）。"
