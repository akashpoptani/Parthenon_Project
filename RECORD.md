# RECORD.md — Change Log of Agent Modifications

This file records every change the agent makes inside `Parthenon_Project/`.
Newest entries on top.

---

## 2026-05-05 — Initial reproducibility artifact bring-up

### Goal

Build a modular, hardware-portable workflow so that anyone with this repo
can re-run the experiments listed in `RESULTS.txt` / `EXPERIMENTS.txt` and
verify the figures/tables in `Parthenon_Characterised.pdf`.

### New / modified files

- `.gitignore` — created. Ignores `git-credentials`, build dirs, run outputs,
  profiler artifacts, Python caches, and editor metadata so they never end up
  in the repo by accident.

- `run_CPU_template.sh` — populated. Hardware-agnostic CPU runner (Intel SPR,
  AMD EPYC, ARM Grace etc.). Builds Parthenon if needed, sources a config
  file from `configs/`, and dispatches to either the plain run or one of
  the profilers (vTune / perf / MICA / kokkos-tools kernel-timer / kokkos-tools
  memory). Peak-memory recording uses `/usr/bin/time -v` plus an optional
  background `top -b` sampler.

- `run_GPU_template.sh` — populated. Multi-GPU + multi-rank runner with
  optional MPS bring-up, Nsight Systems, Nsight Compute, kokkos-tools
  kernel-timer, kokkos-tools memory-events / hwm. Peak-memory recording
  uses `nvidia-smi --query-gpu=memory.used` sampled in the background.

- `configs/` — new directory.
  - `configs/README.md` — documents every config knob.
  - `configs/common.env` — defaults shared by every run (paths, modules,
    timeout, output dir).
  - `configs/cpu_baseline.env` — example: 16-core SPR, plain run.
  - `configs/cpu_vtune.env` — example: 16-core SPR with Intel vTune hotspots.
  - `configs/cpu_mica.env` — example: 16-core SPR with MICA opcode analysis.
  - `configs/cpu_kokkos_kernel_timer.env` — kokkos-tools simple-kernel-timer.
  - `configs/cpu_kokkos_memory.env` — kokkos-tools memory-events / hwm.
  - `configs/gpu_1h100.env` — 1 H100, 1 rank baseline.
  - `configs/gpu_2h100.env` — 2 H100s, 2 ranks baseline.
  - `configs/gpu_2h100_4ranks_mps.env` — 2 H100s, 4 ranks via MPS.
  - `configs/gpu_nsys.env` — Nsight Systems profile.
  - `configs/gpu_ncu.env` — Nsight Compute profile.
  - `configs/gpu_kokkos_kernel_timer.env` — kokkos-tools kernel timer (GPU).
  - `configs/gpu_kokkos_memory.env` — kokkos-tools memory tool (GPU).

- `experiments/` — new directory holding driver scripts.
  - `experiments/lib.py` — shared helpers (config-file loader, mpirun command
    builder, FOM extractor from Parthenon stdout, results CSV writer).
  - `experiments/exp1_mesh_size_scaling.py` — implements Experiment 1 / Result 2
    sweep (Mesh Size = 64, 96; MeshBlockSize = 16; AMR Levels = 3) across
    1 H100, 2 H100, 2 H100 with 4 ranks via MPS, and 16-core SPR CPU.
  - `experiments/exp_profiling.py` — runs the
    `(Mesh=128, MeshBlockSize=16, AMR=3)` configuration on the 4-rank-2-H100
    GPU build and the 16-core SPR build under every supported profiler:
    vTune (CPU), Nsight Systems (GPU), Nsight Compute (GPU), MICA (CPU),
    kokkos-tools kernel-timer (CPU+GPU), kokkos-tools memory (CPU+GPU).

- `README.md` — populated. Single source of truth for: (1) building Parthenon
  on Lighthouse, (2) running the benchmark plain / under each tool, and
  (3) reproducing every figure / table in
  `Parthenon_Characterised.pdf`. Sections 8–17 each map one experiment script
  to one figure or table.

- `RECORD.md` — this file. Will keep growing as the agent makes more changes.

### Initial git commit

- Created `.gitignore` first so `git-credentials` is never tracked.
- Committed with author `mbits-research-group <mbits-research-group@umich.edu>`.
- Initial commit message: "Initial reproducibility workflow scaffolding".
