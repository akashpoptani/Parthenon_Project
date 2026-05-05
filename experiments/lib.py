"""Shared helpers for the experiment driver scripts under experiments/.

Every driver loads a config from configs/ and dispatches to either
run_CPU_template.sh or run_GPU_template.sh, possibly with NX / NXB / NUMLEVEL
overrides supplied via environment variables (which the configs honor with
${VAR:-default} idioms).

The drivers are intentionally I/O-light: they shell out to the run scripts,
parse FOM and peak memory from the artifacts each run produces, and append
one row per run to a CSV.
"""

from __future__ import annotations

import csv
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Mapping

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIGS_DIR = REPO_ROOT / "configs"
RESULTS_DIR = REPO_ROOT / "results"
RUN_CPU = REPO_ROOT / "run_CPU_template.sh"
RUN_GPU = REPO_ROOT / "run_GPU_template.sh"

# Parthenon prints its FOM near the end of stdout. The regex matches both the
# "zone-cycles/wallsecond = 1.234e+07" form and the older "FOM: 1.23e+07" form.
_FOM_RE = re.compile(
    r"(?:zone[-_ ]cycles\s*/\s*wallsecond|FOM)\s*[:=]?\s*([\d.eE+-]+)",
    re.IGNORECASE,
)


@dataclass
class RunSpec:
    """One row in an experiment sweep."""

    name: str                   # human-readable label, e.g. "1H100_baseline"
    runner: str                 # "cpu" or "gpu"
    config: str                 # path to *.env relative to configs/
    overrides: dict = field(default_factory=dict)  # env-var overrides
    extra_args: list = field(default_factory=list) # forwarded to the runner


@dataclass
class RunResult:
    spec_name: str
    config: str
    nx: int | None
    nxb: int | None
    numlevel: int | None
    ranks: int | None
    fom: float | None
    peak_cpu_kb: int | None
    peak_gpu_used_mib: int | None
    run_dir: Path | None
    rc: int


def _runner_path(spec: RunSpec) -> Path:
    if spec.runner == "cpu":
        return RUN_CPU
    if spec.runner == "gpu":
        return RUN_GPU
    raise ValueError(f"unknown runner: {spec.runner!r}")


def _config_path(spec: RunSpec) -> Path:
    p = CONFIGS_DIR / spec.config
    if not p.exists():
        raise FileNotFoundError(f"config not found: {p}")
    return p


def _spawn(spec: RunSpec, dry_run: bool) -> tuple[int, Path | None]:
    """Invoke the runner script. Returns (rc, run_dir)."""
    env = os.environ.copy()
    env.update({k: str(v) for k, v in spec.overrides.items()})
    cmd = [str(_runner_path(spec)), str(_config_path(spec)), *spec.extra_args]
    print(f"\n[experiment] {spec.name}")
    print("  +", " ".join(cmd))
    if spec.overrides:
        print("  overrides:", " ".join(f"{k}={v}" for k, v in spec.overrides.items()))
    if dry_run:
        return 0, None

    proc = subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    last_run_dir: Path | None = None
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        # The runner prints "[done] outputs in: <dir>" near the end.
        m = re.search(r"\[done\] outputs in:\s*(.*\S)", line)
        if m:
            last_run_dir = Path(m.group(1).strip())
    rc = proc.wait()
    return rc, last_run_dir


def _parse_fom(run_dir: Path) -> float | None:
    log = run_dir / "run.log"
    if not log.exists():
        return None
    try:
        text = log.read_text(errors="replace")
    except OSError:
        return None
    matches = _FOM_RE.findall(text)
    if not matches:
        return None
    try:
        return float(matches[-1])
    except ValueError:
        return None


def _parse_peak_cpu_kb(run_dir: Path) -> int | None:
    # /usr/bin/time -v: "Maximum resident set size (kbytes): N"
    f = run_dir / "time.txt"
    if not f.exists():
        return None
    for line in f.read_text(errors="replace").splitlines():
        if "Maximum resident set size" in line:
            try:
                return int(line.split(":")[-1].strip())
            except ValueError:
                return None
    return None


def _parse_peak_gpu_mib(run_dir: Path) -> int | None:
    # gpu_mem_samples.csv columns: timestamp, index, memory.used, memory.free,
    # memory.total, utilization.gpu (units stripped via --format=csv,nounits).
    f = run_dir / "gpu_mem_samples.csv"
    if not f.exists():
        return None
    peak: int | None = None
    try:
        with f.open() as fh:
            reader = csv.reader(fh)
            for row in reader:
                if not row or row[0].lstrip().startswith(("timestamp", "#")):
                    continue
                try:
                    used = int(row[2].strip())
                except (IndexError, ValueError):
                    continue
                if peak is None or used > peak:
                    peak = used
    except OSError:
        return None
    return peak


def execute(specs: Iterable[RunSpec], csv_out: Path, dry_run: bool = False) -> list[RunResult]:
    results: list[RunResult] = []
    csv_out.parent.mkdir(parents=True, exist_ok=True)
    new = not csv_out.exists()
    with csv_out.open("a", newline="") as fh:
        writer = csv.writer(fh)
        if new:
            writer.writerow([
                "spec", "config", "nx", "nxb", "numlevel", "ranks",
                "fom_zone_cycles_per_sec", "peak_cpu_kb", "peak_gpu_used_mib",
                "run_dir", "rc",
            ])
        for spec in specs:
            rc, run_dir = _spawn(spec, dry_run)
            fom = _parse_fom(run_dir) if run_dir else None
            cpu_peak = _parse_peak_cpu_kb(run_dir) if run_dir else None
            gpu_peak = _parse_peak_gpu_mib(run_dir) if run_dir else None
            row = RunResult(
                spec_name=spec.name,
                config=spec.config,
                nx=int(spec.overrides.get("NX")) if "NX" in spec.overrides else None,
                nxb=int(spec.overrides.get("NXB")) if "NXB" in spec.overrides else None,
                numlevel=int(spec.overrides.get("NUMLEVEL")) if "NUMLEVEL" in spec.overrides else None,
                ranks=None,  # the runner is the source of truth; left blank here.
                fom=fom,
                peak_cpu_kb=cpu_peak,
                peak_gpu_used_mib=gpu_peak,
                run_dir=run_dir,
                rc=rc,
            )
            writer.writerow([
                row.spec_name, row.config,
                row.nx, row.nxb, row.numlevel, row.ranks,
                row.fom, row.peak_cpu_kb, row.peak_gpu_used_mib,
                str(row.run_dir) if row.run_dir else "",
                row.rc,
            ])
            fh.flush()
            results.append(row)
    return results
