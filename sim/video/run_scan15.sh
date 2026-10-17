#!/usr/bin/env bash
# Build and run the m2_scan15 bench (needs Verilator 5). From anywhere:
#   sim/video/run_scan15.sh [mode] [D_PX] [frames]      mode 0 = 273/274, 1 = 268/269, 2 = 262/263
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode="${1:-2}"; dpx="${2:-991}"; frames="${3:-14}"
obj="/tmp/scan15_${mode}_${dpx}"
cd "$root"
rm -rf "$obj"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_m2_scan15 "-GDPX=$dpx" --Mdir "$obj" \
  sim/video/tb_m2_scan15.sv rtl/video/m2_scan15.sv rtl/video/m2_video_timing.sv -o tb > "$obj.build.log" 2>&1 || { tail -30 "$obj.build.log"; exit 1; }
echo "=== mode $mode  D_PX $dpx"
"$obj/tb" "+mode=$mode" "+frames=$frames" 2>&1 | grep -E "mode |pixels checked|hsync|margin|PASS|FAIL|TIMEOUT|RING|PIXEL" | head -14
