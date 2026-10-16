#!/bin/zsh
# 起動中の iOS シミュレータの位置を、この Mac の現在地に合わせる。
#   tools/sim_here.sh            … 起動中のシミュレータすべて
#   tools/sim_here.sh <UDID>     … 指定したシミュレータ
# 初回は macOS が「現在地取得」アプリの位置情報の利用許可を求めるので「許可」を押す。
set -euo pipefail
cd "$(dirname "$0")"
[[ -d build/WhereAmI.app ]] || ./build_whereami.sh >/dev/null
rm -f build/out.txt build/err.txt
open -W --stdout "$PWD/build/out.txt" --stderr "$PWD/build/err.txt" build/WhereAmI.app
coords=$(grep -E '^-?[0-9.]+,-?[0-9.]+$' build/out.txt | tail -1)
if [[ -z "$coords" ]]; then
  cat build/err.txt >&2
  exit 1
fi
xcrun simctl location "${1:-booted}" set "$coords"
echo "シミュレータの位置を $coords に設定しました（$(grep 精度 build/err.txt || true)）"
