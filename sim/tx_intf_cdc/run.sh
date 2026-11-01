#!/bin/bash
# CDC regression for tx_intf/dac_intf (P25). Needs Vivado 2025.1 in PATH and
# the generated headers (clock_speed.v, board_def.v, tx_intf_pre_def.v) in
# HDR, e.g. the hw build work copy ip/tx_intf/src.
#   HDR=<dir> ./run.sh [delays.txt]
# delays.txt: 32 lines, per-bit transport delay (ns) on the iq bus.
# Pass: every run prints corrupt 0 dup 0 drop 0, and the latency of one run
# does not change at a fixed phase.
set -euo pipefail
cd "$(dirname "$0")"
HDR=${HDR:?set HDR to the directory with the generated headers}
SRC=../../ip/tx_intf/src
X=$(dirname "$(dirname "$(command -v vivado)")")/data
DLY=${1:-}
xvlog -sv "$X/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" "$X/ip/xpm/xpm_memory/hdl/xpm_memory.sv" "$X/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv" >xvlog.txt
xvlog -i "$HDR" "$SRC/tx_iq_intf.v" "$SRC/csi_fuzzer.v" "$SRC/dac_intf.v" "$X/verilog/src/glbl.v" >>xvlog.txt
xvlog -sv tb_dac_intf_cdc.sv >>xvlog.txt
xelab -debug off -relax tb_dac_intf_cdc glbl -s tb_dac_intf_cdc -timescale 1ns/1fs >xelab.txt
args=()
[ -n "$DLY" ] && args+=(--testplusarg "delays=$DLY")
: >results.txt
# The board clocks are PLL-related (acc = 5/2 dac): fixed phases 0..10 ns.
for i in $(seq 0 40); do
  off=$(awk -v i="$i" 'BEGIN{printf "%.3f", 0.05 + i*0.25}')
  xsim tb_dac_intf_cdc -R --log /dev/null --testplusarg ppm=0 --testplusarg dac_off="$off" \
    --testplusarg nsamp=15000 --testplusarg out=r.txt "${args[@]}" >/dev/null
  cat r.txt >>results.txt
done
# Phase sweeps, in case the clocks are ever made asynchronous.
for p in 100 -100 37 -11 3; do
  xsim tb_dac_intf_cdc -R --log /dev/null --testplusarg ppm="$p" --testplusarg nsamp=100000 \
    --testplusarg out=r.txt "${args[@]}" >/dev/null
  cat r.txt >>results.txt
done
if grep -q INCOMPLETE results.txt || grep -vq ' corrupt 0 dup 0 drop 0 ' results.txt; then
  echo "CDC_SIM_FAIL"; exit 1
fi
echo "CDC_SIM_PASS $(wc -l < results.txt) runs"
