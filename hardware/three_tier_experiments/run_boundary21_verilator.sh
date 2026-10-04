#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <hetero_pending_depth> <packets_per_leaf> <object_dir>" >&2
    exit 2
fi

pending_depth=$1
packets_per_leaf=$2
object_dir=$3
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
rtl_dir="$script_dir/../BMW_PIFO_SRAM_vPIFO"

cd "$rtl_dir"
exec verilator --binary --timing -Wno-fatal -j 4 \
    -DHETERO21_DUT \
    -GMIDDLE_COUNT=4 \
    -GLEAF_COUNT=16 \
    -GMTW=32 \
    -GHETERO_PENDING_DEPTH="$pending_depth" \
    -GPACKETS_PER_LEAF="$packets_per_leaf" \
    --top-module ThreeTierScheduler_tb \
    generated/vpifo_config_pkg.sv \
    INFER_SDPRAM.v \
    TaskFIFO.sv \
    TaskDistribute.sv \
    PIFO_SRAM.sv \
    PIFO_SRAM_TOP.sv \
    ShardDirectory.sv \
    PopResultFIFO.sv \
    LogicalRequestBuffer.sv \
    HeterogeneousPIFO.sv \
    "$script_dir/ThreeTierHeterogeneousVPIFO.sv" \
    "$script_dir/ThreeTierHeterogeneousVPIFO21.sv" \
    "$script_dir/ThreeTierScheduler_tb.sv" \
    -Mdir "$object_dir"
