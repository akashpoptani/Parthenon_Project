#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# run_GPU_template.sh
#
# Template runner for the Parthenon-VIBE / Burgers AMR benchmark on a multi-
# GPU + multi-rank node. NVIDIA-only (uses CUDA / nsys / ncu / nvidia-smi
# / MPS). Switches between plain runs and several profilers based on the
# active config file.
#
# Usage:
#   ./run_GPU_template.sh <config-file> [extra Parthenon args...]
#
# Required env vars (typically set in configs/*.env):
#   NX, NXB, NLIM, NUMLEVEL, NUM_GPUS, RANKS, TAG
# Optional:
#   USE_MPS                     0/1 (auto-on when RANKS > NUM_GPUS)
#   CUDA_VISIBLE_DEVICES        e.g. 0,1
#   PROFILER                    none | nsys | ncu | kokkos_kt | kokkos_mem
#   RECORD_PEAK_MEM_GPU         0/1 (uses nvidia-smi sampler)
#   GPU_MEM_SAMPLE_MS           sampling period for nvidia-smi (default 100)
#   KOKKOS_TOOLS_LIB            absolute path to .so for Kokkos profile lib
#   NSYS_TRACE                  trace categories (default: cuda,nvtx,mpi)
#   NSYS_METRIC_DEVICE          GPU index for --gpu-metrics-device (default 0)
#   NCU_METRICS                 metrics list (defaults to ncu README list)
#   NCU_ROI_PROFILE             0/1 -> --profile-from-start off when 1
#   MPIRUN_EXTRA                extra mpirun flags (e.g. --map-by ppr:...:node:pe=1)
#   MODULES                     "module load" args for the cluster
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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$SCRIPT_DIR/configs/common.env"
[[ -f "$COMMON" ]] && source "$COMMON"
source "$CONFIG"

# ---- Required ---------------------------------------------------------------
: "${NX:?NX must be set}"
: "${NXB:?NXB must be set}"
: "${NLIM:?NLIM must be set}"
: "${NUMLEVEL:?NUMLEVEL must be set}"
: "${NUM_GPUS:?NUM_GPUS must be set}"
: "${RANKS:?RANKS must be set}"
: "${TAG:?TAG must be set}"

OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/results}"
PROFILER="${PROFILER:-none}"
USE_MPS="${USE_MPS:-auto}"
RECORD_PEAK_MEM_GPU="${RECORD_PEAK_MEM_GPU:-1}"
GPU_MEM_SAMPLE_MS="${GPU_MEM_SAMPLE_MS:-100}"
NSYS_TRACE="${NSYS_TRACE:-cuda,nvtx,mpi}"
NSYS_METRIC_DEVICE="${NSYS_METRIC_DEVICE:-0}"
NCU_ROI_PROFILE="${NCU_ROI_PROFILE:-0}"
MPIRUN_EXTRA="${MPIRUN_EXTRA:-}"

# Auto-decide MPS:  ranks > visible GPUs => MPS on.
if [[ "$USE_MPS" == "auto" ]]; then
    if (( RANKS > NUM_GPUS )); then USE_MPS=1; else USE_MPS=0; fi
fi

# ---- Resolve binary ---------------------------------------------------------
PARTHENON_DIR="${PARTHENON_DIR:-$SCRIPT_DIR/parthenon}"
BUILD_DIR_GPU="${BUILD_DIR_GPU:-$PARTHENON_DIR/build_gpu}"
BENCHMARK_BIN="${BENCHMARK_BIN:-$BUILD_DIR_GPU/benchmarks/burgers/burgers-benchmark}"
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
    echo "[build] Parthenon GPU build not found at $BENCHMARK_BIN; building..."
    mkdir -p "$BUILD_DIR_GPU"
    pushd "$BUILD_DIR_GPU" >/dev/null
    cmake \
        -DKokkos_ENABLE_CUDA=ON \
        -DKokkos_ARCH_HOPPER90=ON \
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
RUN_NAME="gpu_${TAG}_${NX}_${NXB}_${NUMLEVEL}_g${NUM_GPUS}_r${RANKS}_${PROFILER}_${STAMP}"
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
    echo "num_gpus:    $NUM_GPUS"
    echo "ranks:       $RANKS"
    echo "use_mps:     $USE_MPS"
    echo "cuda_visible:${CUDA_VISIBLE_DEVICES:-unset}"
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

# ---- mpirun prefix ----------------------------------------------------------
MPIRUN=( mpirun -n "$RANKS" )
if [[ -n "$MPIRUN_EXTRA" ]]; then
    # shellcheck disable=SC2206
    MPIRUN+=( $MPIRUN_EXTRA )
fi
if [[ -n "${CUDA_VISIBLE_DEVICES:-}" ]]; then
    MPIRUN+=( -x "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES" )
fi

# ---- MPS bring-up -----------------------------------------------------------
mps_started=0
start_mps() {
    [[ "$USE_MPS" == "1" ]] || return 0
    if command -v nvidia-cuda-mps-control >/dev/null 2>&1; then
        echo "[mps] starting"
        nvidia-cuda-mps-control -d || true
        mps_started=1
    else
        echo "[mps] nvidia-cuda-mps-control not found; skipping" >&2
    fi
}
stop_mps() {
    [[ "$mps_started" == "1" ]] || return 0
    echo "[mps] stopping"
    echo quit | nvidia-cuda-mps-control || true
    mps_started=0
}

# ---- GPU memory sampler -----------------------------------------------------
SMI_PID=""
start_gpu_mem_sampler() {
    [[ "$RECORD_PEAK_MEM_GPU" == "1" ]] || return 0
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    local out="$RUN_DIR/gpu_mem_samples.csv"
    nvidia-smi \
        --query-gpu=timestamp,index,memory.used,memory.free,memory.total,utilization.gpu \
        --format=csv,nounits \
        --loop-ms="$GPU_MEM_SAMPLE_MS" \
        > "$out" 2>/dev/null &
    SMI_PID=$!
}
stop_gpu_mem_sampler() {
    [[ -n "$SMI_PID" ]] || return 0
    kill "$SMI_PID" 2>/dev/null || true
    wait "$SMI_PID" 2>/dev/null || true
    SMI_PID=""
}

cleanup() { stop_gpu_mem_sampler; stop_mps; }
trap cleanup EXIT

# ---- Profiler dispatch ------------------------------------------------------
case "$PROFILER" in
    none)
        APP=( "${MPIRUN[@]}" "$BENCHMARK_BIN" "${PARTHENON_ARGS[@]}" )
        ;;

    nsys)
        # nsys wraps mpirun, so each rank is profiled.
        NSYS_PREFIX=( nsys profile
                      -o "$RUN_DIR/nsys_prof"
                      -t "$NSYS_TRACE"
                      --cuda-memory-usage=true
                      --gpu-metrics-device="$NSYS_METRIC_DEVICE"
                      --stats=true
                      --cudabacktrace=true )
        APP=( "${NSYS_PREFIX[@]}" "${MPIRUN[@]}" "$BENCHMARK_BIN" "${PARTHENON_ARGS[@]}" )
        ;;

    ncu)
        : "${NCU_METRICS:=sm__sass_thread_inst_executed_op_fp16_pred_on,sm__sass_thread_inst_executed_op_fp32_pred_on,sm__sass_thread_inst_executed_op_fp64_pred_on,sm__sass_thread_inst_executed_op_fp8_pred_on,sm__throughput.avg.pct_of_peak_sustained_active,sm__warps_active.avg.pct_of_peak_sustained_active,dram__bytes,smsp__thread_inst_executed_per_inst_executed.ratio}"
        NCU_PFS=on
        [[ "$NCU_ROI_PROFILE" == "1" ]] && NCU_PFS=off
        NCU_PREFIX=( ncu
                     -o "$RUN_DIR/ncu_prof"
                     --metrics "$NCU_METRICS"
                     --target-processes all
                     --replay-mode application
                     --profile-from-start "$NCU_PFS"
                     --csv )
        APP=( "${NCU_PREFIX[@]}" "${MPIRUN[@]}" "$BENCHMARK_BIN" "${PARTHENON_ARGS[@]}" )
        # Also dump the raw csv after the run.
        POST_NCU_CSV=1
        ;;

    kokkos_kt)
        : "${KOKKOS_TOOLS_LIB:?Set KOKKOS_TOOLS_LIB to libkp_kernel_timer.so}"
        export KOKKOS_TOOLS_LIBS="$KOKKOS_TOOLS_LIB"
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
start_mps
start_gpu_mem_sampler

"${APP[@]}" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

stop_gpu_mem_sampler
stop_mps

# Post-process Nsight Compute results into a flat CSV.
if [[ "${POST_NCU_CSV:-0}" == "1" && -f "$RUN_DIR/ncu_prof.ncu-rep" ]]; then
    ncu --page raw --import "$RUN_DIR/ncu_prof.ncu-rep" --csv \
        > "$RUN_DIR/ncu_prof.csv" 2>/dev/null || true
fi

echo "exit code:   $RC"  >> "$META"
echo "finished:    $(date +%Y%m%d-%H%M%S)" >> "$META"

grep -Eai 'zone-cycles' "$LOG" | tee "$RUN_DIR/fom.txt" || true

echo "[done] outputs in: $RUN_DIR"
exit "$RC"
