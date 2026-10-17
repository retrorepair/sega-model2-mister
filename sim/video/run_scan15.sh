#!/usr/bin/env bash
# Build and run the m2_scan15 bench (needs Verilator 5). From anywhere:
#   sim/video/run_scan15.sh [mode] [D_PX] [frames] [filt] [swp] [cad] [ph]    mode 0 = 273/274, 1 = 268/269, 2 = 262/263
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode="${1:-2}"; dpx="${2:-1660}"; frames="${3:-14}"; filt="${4:-1}"
obj="/tmp/scan15_${mode}_${dpx}"
cd "$root"
rm -rf "$obj"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_m2_scan15 "-GDPX=$dpx" --Mdir "$obj" \
  sim/video/tb_m2_scan15.sv rtl/video/m2_scan15.sv rtl/video/m2_video_timing.sv -o tb > "$obj.build.log" 2>&1 || { tail -30 "$obj.build.log"; exit 1; }
echo "=== mode $mode  D_PX $dpx"
"$obj/tb" "+mode=$mode" "+frames=$frames" "+filt=$filt" "+swp=${5:-0}" "+cad=${6:-2}" "+ph=${7:-0}" 2>&1 | grep -E "FS frame|PAIRBAD|image cadence|mode |pixels checked|hsync|margin|PASS|FAIL|TIMEOUT|RING|PIXEL|STEP" | head -14
