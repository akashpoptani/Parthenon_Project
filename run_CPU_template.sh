#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# run_CPU_template.sh
#
# Template runner for the Parthenon-VIBE / Burgers AMR benchmark on a multi-
# core CPU node. Hardware-agnostic: works on Intel SPR, AMD EPYC, ARM Grace.
# Switches between plain runs and several profilers based on the active
# config file.
#
# Usage:
#   ./run_CPU_template.sh <config-file> [extra Parthenon args...]
#
# Where <config-file> is a *.env file in configs/ exporting at least:
#   NX, NXB, NLIM, NUMLEVEL, RANKS, OUTPUT_DIR, TAG
# Optional knobs (any combination):
#   PROFILER                    one of: none vtune perf mica kokkos_kt kokkos_mem
#   RECORD_PEAK_MEM_CPU         0 / 1
#   VTUNE_COLLECT               e.g. hotspots, memory-access, threading
#   KOKKOS_TOOLS_LIB            absolute path to .so for Kokkos profile lib
#   PIN_ROOT, MICA_CONF         only used when PROFILER=mica
#   PERF_EVENTS                 events list for "perf stat" (optional)
#   TIME_BIN                    GNU time binary (default: /usr/bin/time)
#   MEM_SAMPLE_INTERVAL         seconds between top samples (default: 1)
#   CPU_BIND                    extra mpirun bind/map flags (optional)
#   MODULES                     space-separated `module load` args
#
# Anything left after the config file path is forwarded to the executable
# as extra Parthenon overrides (e.g. parthenon/job/problem_id=...).
# ----------------------------------------------------------------------------

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <config-file> [extra Parthenon args...]" >&2
    exit 64
fi

CONFIG="$1"; shift
EXTRA_ARGS=("$@")

if [[ ! -f "$CONFIG" ]]; then
    echo "config file not found: $CONFIG" >&2
    exit 66
fi

# ---- Load defaults, then user config ----------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$SCRIPT_DIR/configs/common.env"
[[ -f "$COMMON" ]] && source "$COMMON"
source "$CONFIG"

# ---- Required parameters ----------------------------------------------------
: "${NX:?NX must be set in the config (mesh size)}"
: "${NXB:?NXB must be set in the config (mesh-block size)}"
: "${NLIM:?NLIM must be set in the config (cycle limit)}"
: "${NUMLEVEL:?NUMLEVEL must be set in the config (AMR levels)}"
: "${RANKS:?RANKS must be set in the config (MPI ranks)}"
: "${TAG:?TAG must be set in the config (run identifier)}"

OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/results}"
PROFILER="${PROFILER:-none}"
RECORD_PEAK_MEM_CPU="${RECORD_PEAK_MEM_CPU:-1}"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
MEM_SAMPLE_INTERVAL="${MEM_SAMPLE_INTERVAL:-1}"
PERF_EVENTS="${PERF_EVENTS:-task-clock,cycles,instructions,cache-references,cache-misses,branch-misses,page-faults}"
CPU_BIND="${CPU_BIND:-}"

# ---- Resolve binary ---------------------------------------------------------
PARTHENON_DIR="${PARTHENON_DIR:-$SCRIPT_DIR/parthenon}"
BUILD_DIR_CPU="${BUILD_DIR_CPU:-$PARTHENON_DIR/build_cpu}"
BENCHMARK_BIN="${BENCHMARK_BIN:-$BUILD_DIR_CPU/benchmarks/burgers/burgers-benchmark}"
BENCHMARK_PIN="${BENCHMARK_PIN:-$PARTHENON_DIR/benchmarks/burgers/burgers.pin}"

# ---- Optional module loads --------------------------------------------------
if [[ -n "${MODULES:-}" ]]; then
    set +u
    if command -v module >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        module load $MODULES || true
    fi
    set -u
fi

# ---- Build if needed --------------------------------------------------------
if [[ ! -x "$BENCHMARK_BIN" ]]; then
    echo "[build] Parthenon CPU build not found at $BENCHMARK_BIN; building..."
    mkdir -p "$BUILD_DIR_CPU"
    pushd "$BUILD_DIR_CPU" >/dev/null
    cmake \
        -DPARTHENON_DISABLE_HDF5=ON \
        -DPARTHENON_ENABLE_PYTHON_MODULE_CHECK=OFF \
        -DREGRESSION_GOLD_STANDARD_SYNC=OFF \
        -DPARTHENON_ENABLE_TESTING=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        "$PARTHENON_DIR"
    make -j
    popd >/dev/null
fi

[[ -x "$BENCHMARK_BIN" ]] || { echo "executable not found: $BENCHMARK_BIN" >&2; exit 70; }

# ---- Output directory + run id ---------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_NAME="cpu_${TAG}_${NX}_${NXB}_${NUMLEVEL}_r${RANKS}_${PROFILER}_${STAMP}"
RUN_DIR="$OUTPUT_DIR/$RUN_NAME"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/run.log"
META="$RUN_DIR/meta.txt"

{
    echo "host:        $(hostname)"
    echo "uname:       $(uname -a)"
    echo "config:      $CONFIG"
    echo "tag:         $TAG"
    echo "profiler:    $PROFILER"
    echo "ranks:       $RANKS"
    echo "mesh:        nx=$NX nxb=$NXB nlim=$NLIM nlvl=$NUMLEVEL"
    echo "binary:      $BENCHMARK_BIN"
    echo "extra args:  ${EXTRA_ARGS[*]:-}"
    echo "started:     $STAMP"
} > "$META"

# ---- Common Parthenon arguments --------------------------------------------
PARTHENON_ARGS=(
    -i "$BENCHMARK_PIN"
    "parthenon/mesh/nx1=$NX" "parthenon/mesh/nx2=$NX" "parthenon/mesh/nx3=$NX"
    "parthenon/meshblock/nx1=$NXB" "parthenon/meshblock/nx2=$NXB" "parthenon/meshblock/nx3=$NXB"
    "parthenon/time/nlim=$NLIM"
    "parthenon/mesh/numlevel=$NUMLEVEL"
)
PARTHENON_ARGS+=("${EXTRA_ARGS[@]}")

# ---- Build the mpirun prefix -----------------------------------------------
MPIRUN=(mpirun -n "$RANKS")
if [[ -n "$CPU_BIND" ]]; then
    # shellcheck disable=SC2206
    MPIRUN+=( $CPU_BIND )
fi

# ---- Optional peak-memory sampler ------------------------------------------
SAMPLER_PID=""
start_mem_sampler() {
    [[ "$RECORD_PEAK_MEM_CPU" == "1" ]] || return 0
    local out="$RUN_DIR/cpu_mem_samples.txt"
    (
        while true; do
            ts=$(date +%s)
            free_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo "NA")
            total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "NA")
            echo "$ts $total_kb $free_kb"
            sleep "$MEM_SAMPLE_INTERVAL"
        done
    ) > "$out" 2>/dev/null &
    SAMPLER_PID=$!
}
stop_mem_sampler() {
    [[ -n "$SAMPLER_PID" ]] || return 0
    kill "$SAMPLER_PID" 2>/dev/null || true
    wait "$SAMPLER_PID" 2>/dev/null || true
}
trap stop_mem_sampler EXIT

# ---- Profiler dispatch ------------------------------------------------------
case "$PROFILER" in
    none)
        APP=( "${MPIRUN[@]}" "$BENCHMARK_BIN" "${PARTHENON_ARGS[@]}" )
        ;;

    vtune)
        : "${VTUNE_COLLECT:=hotspots}"
        APP=( "${MPIRUN[@]}" vtune
              -collect "$VTUNE_COLLECT"
              -target-duration-type=medium
              -trace-mpi
              -r "$RUN_DIR/vtune_$VTUNE_COLLECT"
              -- "$BENCHMARK_BIN" "${PARTHENON_ARGS[@]}" )
        ;;

    perf)
        APP=( "${MPIRUN[@]}" perf stat -e "$PERF_EVENTS"
              -o "$RUN_DIR/perf_stat.txt"
              -- "$BENCHMARK_BIN" "${PARTHENON_ARGS[@]}" )
        ;;

    mica)
        : "${PIN_ROOT:?PIN_ROOT must be set for PROFILER=mica}"
        : "${MICA_CONF:=$SCRIPT_DIR/profiling_tools/pin/mica.conf}"
        cp "$MICA_CONF" "$RUN_DIR/mica.conf"
        # MICA emits its output files in CWD; give it a fresh dir.
        cd "$RUN_DIR"
        APP=( "${MPIRUN[@]}" "$PIN_ROOT/pin"
              -t "$PIN_ROOT/MICA/obj-intel64/mica.so"
              -- "$BENCHMARK_BIN" "${PARTHENON_ARGS[@]}" )
        ;;

    kokkos_kt)
        : "${KOKKOS_TOOLS_LIB:?Set KOKKOS_TOOLS_LIB to libkp_kernel_timer.so}"
        export KOKKOS_TOOLS_LIBS="$KOKKOS_TOOLS_LIB"
        # The kernel timer writes a *.dat file in CWD.
        cd "$RUN_DIR"
        APP=( "${MPIRUN[@]}" "$BENCHMARK_BIN" "${PARTHENON_ARGS[@]}" )
        ;;

    kokkos_mem)
        : "${KOKKOS_TOOLS_LIB:?Set KOKKOS_TOOLS_LIB to libkp_memory_events.so or libkp_hwm.so}"
        export KOKKOS_TOOLS_LIBS="$KOKKOS_TOOLS_LIB"
        cd "$RUN_DIR"
        APP=( "${MPIRUN[@]}" "$BENCHMARK_BIN" "${PARTHENON_ARGS[@]}" )
        ;;

    *)
        echo "unknown PROFILER=$PROFILER" >&2
        exit 64
        ;;
esac

# ---- Run --------------------------------------------------------------------
start_mem_sampler

if [[ "$RECORD_PEAK_MEM_CPU" == "1" ]] && command -v "$TIME_BIN" >/dev/null 2>&1; then
    "$TIME_BIN" -v -o "$RUN_DIR/time.txt" "${APP[@]}" 2>&1 | tee "$LOG"
else
    "${APP[@]}" 2>&1 | tee "$LOG"
fi
RC=${PIPESTATUS[0]}

stop_mem_sampler
echo "exit code:   $RC"  >> "$META"
echo "finished:    $(date +%Y%m%d-%H%M%S)" >> "$META"

# Cheap FOM extraction (Parthenon prints "zone-cycles/wallsecond" near the end).
grep -Eai 'zone-cycles' "$LOG" | tee "$RUN_DIR/fom.txt" || true

echo "[done] outputs in: $RUN_DIR"
exit "$RC"
