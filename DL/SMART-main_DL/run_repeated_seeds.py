#!/usr/bin/env python3
"""Run leakage-safe repeated stratified holdout experiments.

Each seed independently rebuilds patient splits and normalization, pretrains the
SMART encoder, and fine-tunes Task 1 and Task 2. Patient-level files remain in
the closed-network workspace; only aggregate metrics omit patient identifiers.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import subprocess
import sys
from pathlib import Path

import numpy as np


DEFAULT_SEEDS = [3407, 2024, 2025, 2026, 2027]
SUMMARY_METRICS = [
    "auroc",
    "average_precision",
    "f1_score",
    "sensitivity",
    "specificity",
    "precision",
    "accuracy",
]


def parse_args():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Repeated stratified holdout for amiodarone SMART Task 1 and Task 2."
    )
    parser.add_argument("--seeds", type=int, nargs="+", default=DEFAULT_SEEDS)
    parser.add_argument("--raw-dir", type=Path, default=root / "data/amiodarone/raw")
    parser.add_argument(
        "--processed-root", type=Path,
        default=root / "data/amiodarone/processed/repeated",
    )
    parser.add_argument(
        "--save-root", type=Path,
        default=root / "export/amiodarone/repeated",
    )
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda"])
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--pretrain-epochs", type=int, default=25)
    parser.add_argument("--finetune-epochs", type=int, default=50)
    parser.add_argument("--d-model", type=int, default=32)
    parser.add_argument(
        "--threshold-method",
        default="target-sensitivity",
        choices=["target-sensitivity", "f1", "youden"],
    )
    parser.add_argument("--target-sensitivity", type=float, default=0.90)
    return parser.parse_args()


def run(command: list[str], root: Path) -> None:
    print("\n> " + " ".join(command), flush=True)
    subprocess.run(command, cwd=root, check=True)


def finite_or_none(value):
    if value is None:
        return None
    value = float(value)
    return value if math.isfinite(value) else None


def collect_row(seed: int, task: str, metrics_path: Path) -> dict:
    with metrics_path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    test = payload["test"]
    selection = payload["threshold_selection"]
    n_positive = int(test["n_positive"])
    return {
        "seed": seed,
        "task": task,
        "best_epoch": int(payload["best_epoch"]),
        "threshold_method": selection["method"],
        "decision_threshold": finite_or_none(test["threshold"]),
        "n_test_negative": int(test["n_negative"]),
        "n_test_positive": n_positive,
        "low_event_warning": n_positive < 20,
        **{metric: finite_or_none(test.get(metric)) for metric in SUMMARY_METRICS},
    }


def summarize(rows: list[dict]) -> dict:
    summary = {
        "design": "repeated_stratified_holdout",
        "n_repeats": len({row["seed"] for row in rows}),
        "seeds": sorted({row["seed"] for row in rows}),
        "tasks": {},
    }
    for task in ("task1", "task2"):
        task_rows = [row for row in rows if row["task"] == task]
        task_summary = {
            "n_repeats": len(task_rows),
            "n_repeats_with_fewer_than_20_test_positives": sum(
                bool(row["low_event_warning"]) for row in task_rows
            ),
            "metrics": {},
        }
        for metric in SUMMARY_METRICS:
            values = np.asarray(
                [row[metric] for row in task_rows if row[metric] is not None],
                dtype=float,
            )
            task_summary["metrics"][metric] = {
                "n_valid": int(len(values)),
                "mean": float(values.mean()) if len(values) else None,
                "std": float(values.std(ddof=1)) if len(values) > 1 else None,
                "min": float(values.min()) if len(values) else None,
                "max": float(values.max()) if len(values) else None,
            }
        summary["tasks"][task] = task_summary
    return summary


def main():
    args = parse_args()
    root = Path(__file__).resolve().parent
    if len(set(args.seeds)) != len(args.seeds):
        raise ValueError("--seeds must not contain duplicates")
    if len(args.seeds) < 2:
        raise ValueError("Repeated evaluation requires at least two seeds")

    rows = []
    for seed in args.seeds:
        processed_dir = args.processed_root / f"seed_{seed}"
        seed_save_root = args.save_root / f"seed_{seed}"
        pretrain_dir = seed_save_root / "pretrain"
        checkpoint = pretrain_dir / "checkpoint-mse.pth"

        run(
            [
                sys.executable,
                "data/amiodarone/preprocess.py",
                "--raw-dir", str(args.raw_dir),
                "--output-dir", str(processed_dir),
                "--seed", str(seed),
            ],
            root,
        )
        run(
            [
                sys.executable,
                "pretrain_amiodarone.py",
                "--data-dir", str(processed_dir),
                "--save-dir", str(pretrain_dir),
                "--device", args.device,
                "--seed", str(seed),
                "--batch-size", str(args.batch_size),
                "--epochs", str(args.pretrain_epochs),
                "--d-model", str(args.d_model),
            ],
            root,
        )
        for task in ("task1", "task2"):
            run(
                [
                    sys.executable,
                    "train_amiodarone.py",
                    "--task", task,
                    "--data-dir", str(processed_dir),
                    "--save-root", str(seed_save_root),
                    "--pretrain-checkpoint", str(checkpoint),
                    "--device", args.device,
                    "--seed", str(seed),
                    "--batch-size", str(args.batch_size),
                    "--epochs", str(args.finetune_epochs),
                    "--d-model", str(args.d_model),
                    "--require-pretrained",
                    "--class-weights",
                    "--threshold-method", args.threshold_method,
                    "--target-sensitivity", str(args.target_sensitivity),
                ],
                root,
            )
            rows.append(collect_row(seed, task, seed_save_root / task / "metrics.json"))

    args.save_root.mkdir(parents=True, exist_ok=True)
    csv_path = args.save_root / "aggregate_metrics.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    summary = summarize(rows)
    summary["threshold_method"] = args.threshold_method
    summary["target_sensitivity"] = args.target_sensitivity
    summary["note"] = (
        "Mean and sample standard deviation across repeated stratified holdouts; "
        "this is not k-fold cross-validation."
    )
    json_path = args.save_root / "aggregate_summary.json"
    with json_path.open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"Repeated evaluation complete: {csv_path}")


if __name__ == "__main__":
    main()

