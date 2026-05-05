# Parthenon-VIBE Reproducibility Artifact

A turnkey workflow for re-running every experiment in
`Parthenon_Characterised.pdf` (Poptani et al., "Characterizing Adaptive Mesh
Refinement on Heterogeneous Platforms with Parthenon-VIBE") on a Lighthouse
cluster node (96-core Intel Sapphire Rapids + up to 8 NVIDIA H100). The
workflow is modular: every run is described by a small `*.env` file in
[configs/](configs/) and dispatched through one of two template scripts.
Profilers, monitors, and rank/hardware combinations are all selected by
swapping the active config — no edits to the run scripts required.

> **Hardware portability** — the CPU template is hardware-agnostic (Intel
> SPR, AMD EPYC, ARM Grace). The GPU template is NVIDIA-only because it
> uses CUDA / `nvidia-smi` / `nsys` / `ncu` / MPS. Other architectures slot
> in via `MODULES`, `CPU_BIND`, and the Kokkos `Kokkos_ARCH_*` keyword in
> the GPU template's CMake call.

## Repository layout

| Path                                  | What it is                                                |
|---------------------------------------|-----------------------------------------------------------|
| [parthenon/](parthenon/)              | upstream Parthenon source (with the Burgers-VIBE benchmark) |
| [kokkos-tools/](kokkos-tools/)        | upstream Kokkos profiling/debugging tools                  |
| [profiling_tools/](profiling_tools/)  | NCU / nsys / Pin+MICA helper scripts (Alireza)            |
| [configs/](configs/)                  | one `*.env` file per run + [configs/README.md](configs/README.md) |
| [experiments/](experiments/)          | Python drivers per figure / table                          |
| [run_CPU_template.sh](run_CPU_template.sh) | CPU runner — sources a config, dispatches to a profiler  |
| [run_GPU_template.sh](run_GPU_template.sh) | GPU runner — same idea, NVIDIA stack                     |
| [SCRATCH.md](SCRATCH.md)              | author's running notes (Lighthouse SLURM lines, MPS, etc.) |
| [RESULTS.txt](RESULTS.txt)            | numerical results to reproduce                             |
| [EXPERIMENTS.txt](EXPERIMENTS.txt)    | experiment list (goal / config / resources)                |
| [RECORD.md](RECORD.md)                | change log of every agent edit (mandatory)                 |
| [Parthenon_Characterised.pdf](Parthenon_Characterised.pdf) | full paper                              |

## Quick smoke test

After cloning, run the dry-run path to make sure every config is wired up:

```bash
python3 experiments/exp1_mesh_size_scaling.py --dry-run
python3 experiments/exp_profiling.py        --dry-run
```

Both should print the planned commands without launching anything.

---

## Section 1 — Building and running Parthenon-VIBE

### 1.1 Allocating a Lighthouse node

```bash
# CPU-only smoke test (1 GPU is requested only because the CPU partition
# requires GPU resources on this cluster; it is not used)
salloc --partition=project_l --nodes=1 --tasks-per-node=96 \
       --mem=256G --gres=gpu:1

# 1 H100
salloc --partition=project_l --nodes=1 --mem=256G \
       --ntasks=16 --cpus-per-task=1 --gres=gpu:1

# 2 H100s
salloc --partition=project_l --nodes=1 --tasks-per-node=2 \
       --mem=512G --gres=gpu:2

# Find a node with the right resources first
for node in $(sinfo -p ramanvr -N -h -o "%N"); do
    echo "--- $node ---"
    scontrol show node $node | grep -E "CfgTRES|AllocTRES"
done
```

### 1.2 Building Parthenon

The runners build automatically the first time they cannot find the
executable, but you can also build explicitly:

```bash
# CPU
module load nvhpc-openmpi4
mkdir -p parthenon/build_cpu && cd parthenon/build_cpu
cmake -DPARTHENON_DISABLE_HDF5=ON \
      -DPARTHENON_ENABLE_PYTHON_MODULE_CHECK=OFF \
      -DREGRESSION_GOLD_STANDARD_SYNC=OFF \
      -DPARTHENON_ENABLE_TESTING=OFF \
      -DCMAKE_BUILD_TYPE=Release ..
make -j

# GPU (Hopper / H100)
module load gcc/10.3.0 openmpi/4.1.6-cuda
mkdir -p parthenon/build_gpu && cd parthenon/build_gpu
cmake -DKokkos_ENABLE_CUDA=ON -DKokkos_ARCH_HOPPER90=ON \
      -DPARTHENON_DISABLE_HDF5=ON ..
make -j
```

### 1.3 Plain runs

```bash
# CPU (16-core SPR baseline)
./run_CPU_template.sh configs/cpu_baseline.env

# 1 H100
./run_GPU_template.sh configs/gpu_1h100.env

# 2 H100
./run_GPU_template.sh configs/gpu_2h100.env

# 2 H100 with 4 ranks via MPS
./run_GPU_template.sh configs/gpu_2h100_4ranks_mps.env
```

Each invocation creates `results/<descriptive-name>-<timestamp>/` containing
`run.log`, `meta.txt`, `time.txt` (CPU `/usr/bin/time -v` output if enabled),
`cpu_mem_samples.txt` and/or `gpu_mem_samples.csv`, the FOM line in
`fom.txt`, and any tool-specific artifacts.

### 1.4 Overriding the sweep parameters

The configs treat `NX`, `NXB`, `NUMLEVEL`, `NLIM` as overridable, so you can
re-use the same config for every experiment row:

```bash
NX=128 NXB=8 NUMLEVEL=3 NLIM=250 \
    ./run_GPU_template.sh configs/gpu_2h100_4ranks_mps.env
```

The Python drivers in `experiments/` do exactly this internally.

---

## Section 2 — Running with Intel vTune (CPU)

```bash
module load nvhpc-openmpi4 vtune
./run_CPU_template.sh configs/cpu_vtune.env
```

The runner translates this into roughly:

```bash
mpirun -n 16 vtune \
    -collect hotspots -target-duration-type=medium -trace-mpi \
    -r results/<run-dir>/vtune_hotspots \
    -- parthenon/build_cpu/benchmarks/burgers/burgers-benchmark \
       -i parthenon/benchmarks/burgers/burgers.pin \
       parthenon/mesh/nx{1,2,3}=$NX parthenon/meshblock/nx{1,2,3}=$NXB \
       parthenon/time/nlim=$NLIM parthenon/mesh/numlevel=$NUMLEVEL
```

Switch collectors via `VTUNE_COLLECT=memory-access` (or `threading`,
`hpc-performance`, …) on the command line or in a copy of `cpu_vtune.env`.

Open the result directory with `vtune-gui` or summarize with
`vtune -report summary -r <result-dir>`.

---

## Section 3 — Running with `top`/`htop`/`/usr/bin/time -v` (CPU + GPU)

These are always-on monitors — no separate tool config required.

- `RECORD_PEAK_MEM_CPU=1` (default) wraps the run in `/usr/bin/time -v`,
  producing `time.txt` with "Maximum resident set size".
- `MEM_SAMPLE_INTERVAL=1` triggers a background `/proc/meminfo` sampler
  that writes `cpu_mem_samples.txt` (one row per second).
- `RECORD_PEAK_MEM_GPU=1` (default on GPU) launches an `nvidia-smi
  --query-gpu=memory.used` sampler in the background, written to
  `gpu_mem_samples.csv`.

Force-disable per side with `RECORD_PEAK_MEM_CPU=0` /
`RECORD_PEAK_MEM_GPU=0` in your config or on the command line. Use
`htop`/`nvidia-smi` interactively in another shell to watch live.

---

## Section 4 — Running with `perf` (CPU)

```bash
PROFILER=perf ./run_CPU_template.sh configs/cpu_baseline.env
# customize counters with:
PERF_EVENTS="cycles,instructions,cache-misses,LLC-load-misses" \
    PROFILER=perf ./run_CPU_template.sh configs/cpu_baseline.env
```

Output lands in `results/<run-dir>/perf_stat.txt`.

---

## Section 5 — Running with Pin / MICA (CPU only)

Install Intel Pin once per cluster and copy `profiling_tools/pin/MICA` into
the Pin tree (see `profiling_tools/pin/README.md`):

```bash
export PIN_ROOT=/path/to/pin   # the dir where pin-3.x lives
cp -r profiling_tools/pin/MICA $PIN_ROOT
( cd $PIN_ROOT/MICA && make -j )

PIN_ROOT=$PIN_ROOT ./run_CPU_template.sh configs/cpu_mica.env
```

Two output files appear in the run directory:
- `itypes_full_int_pin.out` — opcode counts (`Total`, `LD/ST`, `VLD/VST`,
  `FP`, `VEC`, `CTRL`, `REG`, `SCALAR`, `OTHER`)
- `itypes_other_group_categories.txt` — breakdown of `OTHER`

This is what feeds Experiment 10 (CPU instruction opcode distribution).
MICA adds 5–10× overhead, so the config defaults `NLIM=50` instead of 250.

---

## Section 6 — Running with NVIDIA Nsight Systems (GPU)

```bash
module load gcc/10.3.0 openmpi/4.1.6-cuda nsight-systems
./run_GPU_template.sh configs/gpu_nsys.env
```

Outputs in `results/<run-dir>/`:
- `nsys_prof.nsys-rep` — open in `nsys-ui` for the timeline
- `nsys_prof.sqlite`   — the SQLite trace
- `nsys_prof.qdstrm` (older nsys versions only)

The `profiling_tools/nsys/process.py` helper turns the SQLite into watermark
/ usage / leakage TSVs:

```bash
python profiling_tools/nsys/process.py \
    -i results/<run-dir>/nsys_prof \
    -o results/<run-dir>/nsys_watermark.txt \
    -a watermark
```

---

## Section 7 — Running with NVIDIA Nsight Compute (GPU)

```bash
module load gcc/10.3.0 openmpi/4.1.6-cuda nsight-compute
./run_GPU_template.sh configs/gpu_ncu.env
```

NCU is *very* expensive — the config defaults `NLIM=1` (one cycle). Outputs:
- `ncu_prof.ncu-rep` — open in `ncu-ui`
- `ncu_prof.csv`     — flat CSV of every kernel × metric (post-processed by
  the runner)

The metric set defaults to the one from `profiling_tools/ncu/profile.sh`:
SM throughput utilization, SM occupancy, warp utilization, DRAM bytes,
arithmetic intensity, control divergence. This is what produces TABLE III.

---

## Section 8 — kokkos-tools simple-kernel-timer + memory tool (CPU + GPU)

Build kokkos-tools once:

```bash
mkdir -p kokkos-tools/build && cd kokkos-tools/build
cmake -DCMAKE_INSTALL_PREFIX=$(pwd)/../install ..
make -j install
```

Then point `KOKKOS_TOOLS_LIB` at the `.so` you want:

```bash
# CPU + simple-kernel-timer
./run_CPU_template.sh configs/cpu_kokkos_kernel_timer.env

# GPU + simple-kernel-timer (4 ranks via MPS on 2 H100)
./run_GPU_template.sh configs/gpu_kokkos_kernel_timer.env

# CPU + memory-events (alloc/free timeline)
./run_CPU_template.sh configs/cpu_kokkos_memory.env

# GPU + memory-events
./run_GPU_template.sh configs/gpu_kokkos_memory.env
```

Inspect the kernel timer with `kokkos-tools/install/bin/kp_reader run.dat`.

---

# Reproducing the figures and tables

Each section below maps one experiment / figure / table from the paper to
one entry-point. The Python drivers iterate over the same `(NX, NXB,
NUMLEVEL)` grid the paper uses; their CSV output (`results/expN_*.csv`) is
what the figure scripts in the paper consume.

## Section 9 — Figure 2 / TABLE R-A (Mesh Size Scaling)

**Experiment 1**, fixed `MeshBlockSize=16, AMR=3`, sweep
`MeshSize ∈ {64, 96}` (this artifact's subset; full paper sweep also covers
128, 160, 192, 256). Resources: `1 H100 baseline`, `2 H100 baseline`,
`2 H100 with 2 ranks/GPU via MPS = 4 ranks`, `16-core SPR CPU baseline`.

```bash
python3 experiments/exp1_mesh_size_scaling.py
# CSV: results/exp1_mesh_size_scaling.csv
```

To run the full paper sweep, edit `MESH_SIZES` in the script
(`[64, 96, 128, 160, 192, 256]`).

## Section 10 — Figure 3 / TABLE R-B (MeshBlockSize Scaling)

**Experiment 2**, fixed `Mesh=128, AMR=3`, sweep
`MeshBlockSize ∈ {64, 32, 16, 8, 4}`. Re-run the sweep by overriding the
inputs of `exp1_mesh_size_scaling.py`'s spec builder:

```bash
# Quick path: sweep NXB by hand using the same configs
for NXB in 64 32 16 8 4; do
    for cfg in gpu_1h100.env gpu_2h100.env gpu_2h100_4ranks_mps.env; do
        NX=128 NXB=$NXB NUMLEVEL=3 NLIM=250 \
            ./run_GPU_template.sh configs/$cfg
    done
    NX=128 NXB=$NXB NUMLEVEL=3 NLIM=250 \
        ./run_CPU_template.sh configs/cpu_baseline.env
done
```

(Or copy `experiments/exp1_mesh_size_scaling.py` to
`experiments/exp2_blocksize_scaling.py`, swap the swept variable.)

## Section 11 — Figure 4 / TABLE R-C (AMR Level Scaling)

**Experiment 3**, fixed `Mesh=128, MeshBlockSize=16`, sweep
`AMR Levels ∈ {1, 2, 3, 4}`:

```bash
for LVL in 1 2 3 4; do
    for cfg in gpu_1h100.env gpu_2h100.env gpu_2h100_4ranks_mps.env; do
        NX=128 NXB=16 NUMLEVEL=$LVL NLIM=250 \
            ./run_GPU_template.sh configs/$cfg
    done
    NX=128 NXB=16 NUMLEVEL=$LVL NLIM=250 \
        ./run_CPU_template.sh configs/cpu_baseline.env
done
```

## Section 12 — Figure 5 (GPU Rank Scaling)

**Experiment 4**: sweep total MPI ranks per GPU. Generate fresh
`gpu_*_Rranks_mps.env` configs by copying `gpu_2h100_4ranks_mps.env` and
adjusting `RANKS` / `MPIRUN_EXTRA`. Then loop:

```bash
for RANKS in 1 2 4 8 12 16; do
    NX=128 NXB=16 NUMLEVEL=3 NLIM=250 \
        ./run_GPU_template.sh configs/gpu_2h100_${RANKS}ranks_mps.env
done
```

## Section 13 — Figure 6 (Function Runtime Breakdown)

**Experiment 5**, `Mesh=128, MeshBlockSize=8, AMR=3`. Use the kokkos-tools
simple-kernel-timer to get per-function timings:

```bash
NX=128 NXB=8 NUMLEVEL=3 NLIM=250 \
    ./run_GPU_template.sh configs/gpu_kokkos_kernel_timer.env
NX=128 NXB=8 NUMLEVEL=3 NLIM=250 \
    ./run_CPU_template.sh configs/cpu_kokkos_kernel_timer.env

kokkos-tools/install/bin/kp_reader results/<run-dir>/*.dat
```

## Section 14 — Figure 7 (Kernel vs Non-Kokkos Time)

**Experiment 6**, same `(128, 8, 3)` config. The kokkos-tools kernel-timer
report (Section 13) gives "Total Kokkos time" vs the wall time recorded in
`run.log`; their difference is the non-Kokkos portion.

## Section 15 — Figure 8 (CPU Strong Scaling)

**Experiment 7**, sweep CPU ranks 4 → 96 with `(128, 8, 3)`:

```bash
for RANKS in 4 8 16 32 48 56 64 72 96; do
    NX=128 NXB=8 NUMLEVEL=3 NLIM=250 RANKS=$RANKS \
        ./run_CPU_template.sh configs/cpu_baseline.env
done
```

`RANKS` set on the command line overrides the value in
`cpu_baseline.env` (POSIX rule: later assignments win).

## Section 16 — Figure 9 (Function Kernel Portion)

**Experiment 8**, same `(128, 8, 3)` config. Combine the kokkos-tools
kernel timer (Section 13) with manual function-level timings inside
Parthenon (or vTune `hotspots`); see RESULTS.txt RESULT 10 for the per-
function "Total vs Kernel" decomposition this produces.

## Section 17 — Figure 10 (Memory Breakdown)

**Experiment 9**, `(128, 8, 3)` with the kokkos-tools memory tool (Kokkos
side) plus `nvidia-smi` / `/usr/bin/time -v` samples (rest):

```bash
NX=128 NXB=8 NUMLEVEL=3 NLIM=250 \
    ./run_GPU_template.sh configs/gpu_kokkos_memory.env
NX=128 NXB=8 NUMLEVEL=3 NLIM=250 \
    ./run_CPU_template.sh configs/cpu_kokkos_memory.env
```

The `gpu_mem_samples.csv` (full process memory) and the kokkos-tools
memory-events output together give Kokkos / MPI / Other split.

## Section 18 — TABLE III (GPU Microarchitecture Analysis)

**Experiment**: `Mesh=128, AMR=3`, MeshBlockSize ∈ {32, 16}, on 1 H100,
profiled with NVIDIA Nsight Compute (top-10 kernels per cycle):

```bash
for NXB in 32 16; do
    NX=128 NXB=$NXB NUMLEVEL=3 NLIM=1 \
        ./run_GPU_template.sh configs/gpu_ncu.env
done
```

Then process the CSV (`results/<run-dir>/ncu_prof.csv`) into the
SM throughput / SM occupancy / warp utilization / bandwidth utilization /
arithmetic-intensity columns of TABLE III. The metric→column mapping is
documented in `profiling_tools/ncu/README.md`.

---

## Profiler sweep at a single point — `experiments/exp_profiling.py`

To re-run `(Mesh=128, MeshBlockSize=16, AMR=3)` under every supported tool:

```bash
python3 experiments/exp_profiling.py            # all 8 tools
python3 experiments/exp_profiling.py --only CPU16_vtune --only GPU2x4r_nsys
python3 experiments/exp_profiling.py --skip CPU16_mica  # MICA is slow
```

Outputs land per-tool in `results/<run-dir>/`; aggregated FOM and peak-mem
numbers are appended to `results/exp_profiling.csv`.

---

## Re-running on different hardware

| Change                   | Where                                                  |
|--------------------------|--------------------------------------------------------|
| Switch CPU vendor (SPR → EPYC / Grace) | edit `MODULES`, `CPU_BIND` in the CPU configs |
| Drop Intel-only profilers | omit `cpu_vtune.env` / `cpu_mica.env`                 |
| Switch NVIDIA arch (H100 → A100 / GH200) | edit `Kokkos_ARCH_HOPPER90` in `run_GPU_template.sh` |
| Different rank-per-GPU count | copy `gpu_2h100_4ranks_mps.env`, change `RANKS` and `MPIRUN_EXTRA` |
| Different cluster scheduler | only `salloc`/`srun` lines in Section 1.1 are LH-specific |

## Validation

`parthenon/benchmarks/burgers/burgers_diff.py` compares two `burgers.hst`
history files for fixed-tolerance equality. After any code change, run the
plain configs and diff the new history file against a fiducial run:

```bash
python parthenon/benchmarks/burgers/burgers_diff.py burgers.hst burgers.hst.fiducial
```

`burgers.hst` is *appended* to on every run — back it up or use
`parthenon/job/problem_id=foo` to write to a fresh path.

---

## Recording every change

Per `SCRATCH.md` and `PLAN.txt`, **every modification any agent makes in
this directory must be recorded in [RECORD.md](RECORD.md)**. New files,
edited files, and deleted files all belong there.
