#!/usr/bin/env python3
"""Experiment 1 -- Mesh Size Scaling (subset).

Maps to RESULTS.txt RESULT 2 / EXPERIMENTS.txt EXPERIMENT 1.

Fixed parameters
    MeshBlockSize = 16
    AMR Levels    = 3

Swept parameter
    Mesh Size in {64, 96}

Resources used
    1 H100 GPU baseline                         (configs/gpu_1h100.env)
    2 H100 GPUs baseline                        (configs/gpu_2h100.env)
    2 H100 GPUs, 2 ranks per GPU = 4 ranks/MPS  (configs/gpu_2h100_4ranks_mps.env)
    16-core SPR CPU baseline                    (configs/cpu_baseline.env)

Usage
    python experiments/exp1_mesh_size_scaling.py [--dry-run] [--csv path]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import RunSpec, RESULTS_DIR, execute  # noqa: E402

MESH_SIZES = [64, 96]
NXB = 16
NUMLEVEL = 3
NLIM = 250


def build_specs() -> list[RunSpec]:
    bases = [
        ("1H100_baseline",    "gpu", "gpu_1h100.env"),
        ("2H100_baseline",    "gpu", "gpu_2h100.env"),
        ("2H100_4ranks_mps",  "gpu", "gpu_2h100_4ranks_mps.env"),
        ("CPU16_baseline",    "cpu", "cpu_baseline.env"),
    ]
    specs: list[RunSpec] = []
    for nx in MESH_SIZES:
        for label, runner, cfg in bases:
            specs.append(RunSpec(
                name=f"{label}_nx{nx}_nxb{NXB}_lvl{NUMLEVEL}",
                runner=runner,
                config=cfg,
                overrides={
                    "NX": nx,
                    "NXB": NXB,
                    "NUMLEVEL": NUMLEVEL,
                    "NLIM": NLIM,
                },
            ))
    return specs


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dry-run", action="store_true",
                   help="Print what would run without executing.")
    p.add_argument("--csv", default=str(RESULTS_DIR / "exp1_mesh_size_scaling.csv"),
                   help="CSV path to append per-run results to.")
    args = p.parse_args()

    specs = build_specs()
    print(f"[exp1] {len(specs)} runs queued")
    for s in specs:
        print(f"  - {s.name:38s}  config={s.config}")

    results = execute(specs, Path(args.csv), dry_run=args.dry_run)

    print("\n[exp1] summary")
    print(f"{'spec':40s} {'FOM':>14s}  {'cpu_kb':>10s}  {'gpu_mib':>9s}  rc")
    for r in results:
        fom = f"{r.fom:.3e}" if r.fom is not None else "n/a"
        cpu = str(r.peak_cpu_kb) if r.peak_cpu_kb is not None else "-"
        gpu = str(r.peak_gpu_used_mib) if r.peak_gpu_used_mib is not None else "-"
        print(f"{r.spec_name:40s} {fom:>14s}  {cpu:>10s}  {gpu:>9s}  {r.rc}")

    return 0 if all(r.rc == 0 for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
