#!/usr/bin/env python3
"""Profiler sweep for the (Mesh=128, MeshBlockSize=16, AMR=3) point.

Runs the same Parthenon-VIBE configuration twice -- once on 16-core SPR
(CPU) and once on 2 H100 GPUs with 4 MPI ranks via MPS (GPU) -- under every
profiler the artifact supports:

    CPU side
        - Intel vTune (hotspots)                    configs/cpu_vtune.env
        - Intel Pin / MICA opcode mix               configs/cpu_mica.env
        - kokkos-tools simple-kernel-timer          configs/cpu_kokkos_kernel_timer.env
        - kokkos-tools memory tool                  configs/cpu_kokkos_memory.env

    GPU side
        - NVIDIA Nsight Systems                     configs/gpu_nsys.env
        - NVIDIA Nsight Compute                     configs/gpu_ncu.env
        - kokkos-tools simple-kernel-timer (GPU)    configs/gpu_kokkos_kernel_timer.env
        - kokkos-tools memory tool (GPU)            configs/gpu_kokkos_memory.env

This does NOT execute anything in the artifact CI -- it is the driver you
run by hand on Lighthouse with `python experiments/exp_profiling.py`.
Use --only / --skip to pick a subset, and --dry-run to preview.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import RunSpec, RESULTS_DIR, execute  # noqa: E402

NX = 128
NXB = 16
NUMLEVEL = 3

# (label, runner, config-file).  Each config sets a sensible NLIM for the
# tool's overhead profile (e.g. NCU runs only one cycle).
TOOLS: list[tuple[str, str, str]] = [
    # CPU side
    ("CPU16_vtune",         "cpu", "cpu_vtune.env"),
    ("CPU16_mica",          "cpu", "cpu_mica.env"),
    ("CPU16_kokkos_kt",     "cpu", "cpu_kokkos_kernel_timer.env"),
    ("CPU16_kokkos_mem",    "cpu", "cpu_kokkos_memory.env"),
    # GPU side -- 2 H100 / 4 ranks / MPS
    ("GPU2x4r_nsys",        "gpu", "gpu_nsys.env"),
    ("GPU2x4r_ncu",         "gpu", "gpu_ncu.env"),
    ("GPU2x4r_kokkos_kt",   "gpu", "gpu_kokkos_kernel_timer.env"),
    ("GPU2x4r_kokkos_mem",  "gpu", "gpu_kokkos_memory.env"),
]


def build_specs(only: set[str] | None, skip: set[str]) -> list[RunSpec]:
    specs: list[RunSpec] = []
    for label, runner, cfg in TOOLS:
        if only and label not in only:
            continue
        if label in skip:
            continue
        specs.append(RunSpec(
            name=f"{label}_nx{NX}_nxb{NXB}_lvl{NUMLEVEL}",
            runner=runner,
            config=cfg,
            overrides={
                "NX": NX,
                "NXB": NXB,
                "NUMLEVEL": NUMLEVEL,
                # NLIM is config-specific (NCU=1, MICA=50, …) so we don't
                # override it here.
            },
        ))
    return specs


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--only", action="append", default=[],
                   help=f"Run only these labels (repeatable). Choices: "
                        f"{', '.join(label for label, *_ in TOOLS)}")
    p.add_argument("--skip", action="append", default=[],
                   help="Skip these labels (repeatable).")
    p.add_argument("--csv", default=str(RESULTS_DIR / "exp_profiling.csv"),
                   help="CSV path to append per-run results to.")
    args = p.parse_args()

    only = set(args.only) if args.only else None
    skip = set(args.skip)
    specs = build_specs(only, skip)
    if not specs:
        print("[profiling] no tools selected, exiting")
        return 0

    print(f"[profiling] {len(specs)} runs queued")
    for s in specs:
        print(f"  - {s.name:42s}  config={s.config}")

    results = execute(specs, Path(args.csv), dry_run=args.dry_run)

    print("\n[profiling] summary")
    print(f"{'spec':46s} {'rc':>3s}  artifact dir")
    for r in results:
        artifact = str(r.run_dir) if r.run_dir else "(skipped)"
        print(f"{r.spec_name:46s} {r.rc:>3d}  {artifact}")

    return 0 if all(r.rc == 0 for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
