#!/bin/sh
# Testes no computador (macOS/Linux): checagem de sintaxe + cenários de ponta a ponta
# nas telas, em retrato e paisagem do Kindle Paperwhite 11 (1236x1648, 300 ppi).
# Uso: tests/run_tests.sh <pasta do ankiviewer.koplugin descompactado> [--previews]
# Requer: lua (5.1+), luac, python3 (o SQLite dos testes é o do Python).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
AV_DIR=${1:?informe a pasta do ankiviewer.koplugin}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== sintaxe"
find "$HERE/../vocab2deck.koplugin" -name '*.lua' -print0 | xargs -0 -n1 luac -p
echo "ok"

status=0
for size in 1236x1648 1648x1236; do
  w=${size%x*}; h=${size#*x}
  snap=""
  if [ "${2:-}" = "--previews" ]; then snap="$HERE/previews/$size"; rm -rf "$snap"; mkdir -p "$snap"; fi
  echo "== cenários $size"
  mkdir -p "$TMP/$size"
  SCREEN_W=$w SCREEN_H=$h DPI_SCALE=1.875 SNAP_DIR="$snap" lua "$HERE/run.lua" "$TMP/$size" "$AV_DIR" || status=1
done
exit $status
