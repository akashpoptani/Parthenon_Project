# `configs/` — knobs for the Parthenon-VIBE reproduction artifact

Each `*.env` file in this directory is a plain shell file (sourced with
`source`) that fully describes one run. The two top-level runners,
`../run_CPU_template.sh` and `../run_GPU_template.sh`, source `common.env`
first and then the file you pass on the command line.

## Required (every config)

| Variable     | Meaning                                                       |
|--------------|---------------------------------------------------------------|
| `NX`         | Mesh size — `parthenon/mesh/nx{1,2,3}`                        |
| `NXB`        | Mesh-block size — `parthenon/meshblock/nx{1,2,3}`             |
| `NLIM`       | Cycle limit — `parthenon/time/nlim`                           |
| `NUMLEVEL`   | AMR levels — `parthenon/mesh/numlevel`                        |
| `RANKS`      | Total MPI ranks                                               |
| `TAG`        | Short label folded into the run directory name                |

## Required for GPU configs

| Variable     | Meaning                                                       |
|--------------|---------------------------------------------------------------|
| `NUM_GPUS`   | Number of GPUs visible to the job                             |

## Resource / scheduling knobs (optional)

| Variable             | Default                                   | Notes                                       |
|----------------------|-------------------------------------------|---------------------------------------------|
| `OUTPUT_DIR`         | `<repo>/results`                          | parent dir for run artifacts                |
| `MEMORY`             | unused by the script — informational      | record what you asked Slurm for             |
| `WALLTIME`           | unused by the script — informational      | record what you asked Slurm for             |
| `MODULES`            | none                                      | `module load` args, e.g. `nvhpc-openmpi4`   |
| `MPIRUN_EXTRA`       | none                                      | extra mpirun flags (binding, mapping)       |
| `CPU_BIND`           | none (CPU only)                           | folded into mpirun                          |
| `CUDA_VISIBLE_DEVICES`| unset (GPU only)                         | e.g. `0,1`                                  |
| `USE_MPS`            | `auto` (GPU only)                         | `1` to force MPS, `0` to forbid             |

## Profiler / tool knobs

| Variable               | Values                                          | Use with     |
|------------------------|-------------------------------------------------|--------------|
| `PROFILER`             | `none` (default) / `vtune` / `perf` / `mica` / `kokkos_kt` / `kokkos_mem` (CPU); `none` / `nsys` / `ncu` / `kokkos_kt` / `kokkos_mem` (GPU) | both         |
| `VTUNE_COLLECT`        | `hotspots` / `memory-access` / `threading` / …  | CPU vTune    |
| `PERF_EVENTS`          | comma-separated `perf` event list               | CPU perf     |
| `PIN_ROOT`             | absolute path to extracted Intel Pin root       | MICA         |
| `MICA_CONF`            | path to `mica.conf` (default: `profiling_tools/pin/mica.conf`) | MICA |
| `KOKKOS_TOOLS_LIB`     | absolute path to a `libkp_*.so`                 | kokkos_kt / kokkos_mem |
| `NSYS_TRACE`           | trace categories (default `cuda,nvtx,mpi`)      | nsys         |
| `NSYS_METRIC_DEVICE`   | GPU index (default `0`)                         | nsys         |
| `NCU_METRICS`          | metrics list (sensible default if unset)        | ncu          |
| `NCU_ROI_PROFILE`      | `0` / `1` (1 → `--profile-from-start off`)      | ncu          |

## Memory tracking

| Variable                | Values | What it does                                             |
|-------------------------|--------|----------------------------------------------------------|
| `RECORD_PEAK_MEM_CPU`   | `0/1` (default `1`) | wraps the run in `/usr/bin/time -v` and samples `MemAvailable` from `/proc/meminfo` once per second |
| `MEM_SAMPLE_INTERVAL`   | seconds (default `1`) | sampling period for the CPU sampler                  |
| `RECORD_PEAK_MEM_GPU`   | `0/1` (default `1`) | runs `nvidia-smi --query-gpu=memory.used` in the background |
| `GPU_MEM_SAMPLE_MS`     | ms (default `100`)  | sampling period for the GPU sampler                  |

Both knobs are independent — set `RECORD_PEAK_MEM_CPU=1` and
`RECORD_PEAK_MEM_GPU=0` (or vice versa) when you only care about one side.

## Existing configs in this directory

| File                                  | Purpose                                                    |
|---------------------------------------|------------------------------------------------------------|
| `common.env`                          | shared defaults (no overrides expected)                    |
| `cpu_baseline.env`                    | 16-core SPR plain run                                      |
| `cpu_vtune.env`                       | 16-core SPR + Intel vTune `hotspots`                       |
| `cpu_mica.env`                        | 16-core SPR + Intel Pin / MICA opcode mix                  |
| `cpu_kokkos_kernel_timer.env`         | 16-core SPR + kokkos-tools simple-kernel-timer             |
| `cpu_kokkos_memory.env`               | 16-core SPR + kokkos-tools memory-events / hwm             |
| `gpu_1h100.env`                       | 1 H100, 1 rank, plain run                                  |
| `gpu_2h100.env`                       | 2 H100, 2 ranks, plain run                                 |
| `gpu_2h100_4ranks_mps.env`            | 2 H100 with 2 ranks-per-GPU via MPS (4 ranks total)        |
| `gpu_nsys.env`                        | the 4-rank-2-H100 config + Nsight Systems                  |
| `gpu_ncu.env`                         | the 4-rank-2-H100 config + Nsight Compute                  |
| `gpu_kokkos_kernel_timer.env`         | 4-rank-2-H100 + kokkos-tools simple-kernel-timer           |
| `gpu_kokkos_memory.env`               | 4-rank-2-H100 + kokkos-tools memory tool                   |

## Adapting to other hardware

- **Intel SPR → AMD EPYC / ARM Grace**: change `MODULES`, `CPU_BIND`, and
  drop `vtune`/`mica` (Intel-only). `perf` and the kokkos-tools libs are
  portable.
- **NVIDIA H100 → other NVIDIA GPUs**: change `Kokkos_ARCH_*` in the
  template's CMake call (`run_GPU_template.sh`) to the right keyword from
  the Kokkos wiki.
- **Different rank counts**: copy any `gpu_*.env`, change `NUM_GPUS`,
  `RANKS`, and `MPIRUN_EXTRA` (the `--map-by ppr:RANKS:node:pe=1` part).
