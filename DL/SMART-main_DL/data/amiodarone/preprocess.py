#!/usr/bin/env python3
"""Convert SQL wide CSV exports into leakage-safe SMART datasets.

All processing is local. No network access or external service is used.
"""

from __future__ import annotations

import argparse
import json
import pickle
import re
from pathlib import Path

import numpy as np
import pandas as pd


TIME_POINTS = [
    "base", "m1", "m2", "m3", "m4_6",
    "m7_9", "m10_12", "m13_15", "m16_18", "m19_21",
]
FOLLOWUP_POINTS = TIME_POINTS[1:]
EXCLUDED_OUTCOME_WINDOW = "m22_24"

STATIC_FEATURES = [
    "age", "sex", "height", "weight", "bmi", "charlson_tot_grp",
    "alcohol", "smoking", "cumulative_dose_g", "aver_dose_kg",
    "duration", "pdd", "sum_days",
]

OBSERVATION_FLAGS = {
    point: f"{point}_complete_flag" for point in FOLLOWUP_POINTS
}
OUTCOME_OBSERVATION_FLAG = f"{EXCLUDED_OUTCOME_WINDOW}_complete_flag"


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Prepare Task 1/2 amiodarone cohorts for SMART."
    )
    parser.add_argument("--raw-dir", type=Path, default=root / "raw")
    parser.add_argument("--output-dir", type=Path, default=root / "processed")
    parser.add_argument("--seed", type=int, default=3407)
    parser.add_argument("--train-ratio", type=float, default=0.70)
    parser.add_argument("--val-ratio", type=float, default=0.15)
    parser.add_argument("--test-ratio", type=float, default=0.15)
    return parser.parse_args()


def read_csv(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(f"Required export not found: {path}")
    return pd.read_csv(path, dtype={"person_id": "string"}, low_memory=False)


def require_columns(frame: pd.DataFrame, columns: list[str], source: str) -> None:
    missing = [column for column in columns if column not in frame.columns]
    if missing:
        raise ValueError(f"{source} is missing columns: {missing}")


def assert_unique_person(frame: pd.DataFrame, source: str) -> None:
    if frame["person_id"].isna().any():
        raise ValueError(f"{source} contains NULL person_id")
    duplicate_count = int(frame["person_id"].duplicated().sum())
    if duplicate_count:
        raise ValueError(f"{source} contains {duplicate_count} duplicated person_id rows")


def validate_binary_label(frame: pd.DataFrame, source: str) -> None:
    require_columns(frame, ["person_id", "label"], source)
    numeric = pd.to_numeric(frame["label"], errors="coerce")
    if numeric.isna().any() or not set(numeric.astype(int).unique()).issubset({0, 1}):
        raise ValueError(f"{source}.label must contain only 0 and 1")
    frame["label"] = numeric.astype(np.int64)


def split_dynamic_columns(columns: list[str]) -> tuple[list[str], dict[str, dict[str, str]]]:
    """Return base feature names and their time-point column mapping."""
    mapping: dict[str, dict[str, str]] = {}
    suffixes = sorted(TIME_POINTS + [EXCLUDED_OUTCOME_WINDOW], key=len, reverse=True)
    pattern = re.compile(r"^(.*)_(" + "|".join(map(re.escape, suffixes)) + r")$")

    for column in columns:
        match = pattern.match(column)
        if not match:
            continue
        feature, time_point = match.groups()
        mapping.setdefault(feature, {})[time_point] = column

    dynamic_features = sorted(
        feature
        for feature, time_map in mapping.items()
        if all(point in time_map for point in TIME_POINTS)
    )
    incomplete = {
        feature: sorted(set(TIME_POINTS) - set(time_map))
        for feature, time_map in mapping.items()
        if any(point in time_map for point in TIME_POINTS)
        and not all(point in time_map for point in TIME_POINTS)
    }
    if incomplete:
        preview = dict(list(incomplete.items())[:10])
        raise ValueError(f"Incomplete dynamic feature families: {preview}")
    if not dynamic_features:
        raise ValueError("No complete dynamic feature family was found")
    return dynamic_features, mapping


def validate_feature_columns(
    frame: pd.DataFrame,
    dynamic_features: list[str],
    mapping: dict[str, dict[str, str]],
    task: str,
) -> None:
    allowed = {"person_id", "outcome", "subtype_outcome"}
    allowed.update(STATIC_FEATURES)
    allowed.update(OBSERVATION_FLAGS.values())
    allowed.add(OUTCOME_OBSERVATION_FLAG)
    for feature in dynamic_features:
        allowed.update(mapping[feature].values())
    unknown = sorted(set(frame.columns) - allowed)
    if unknown:
        raise ValueError(
            f"{task} contains unclassified columns. Review them before modeling: {unknown}"
        )


def stratum_for_patient(
    task1: pd.DataFrame,
    task2_labels: pd.DataFrame,
    audit: pd.DataFrame,
) -> pd.Series:
    subtype = task2_labels.set_index("person_id")["label"]
    mixed_ids: set[str] = set()
    if "aitd_class" in audit.columns:
        mixed_ids = set(
            audit.loc[pd.to_numeric(audit["aitd_class"], errors="coerce") == 3, "person_id"]
            .dropna()
            .astype(str)
        )

    strata = []
    for person_id, label in zip(task1["person_id"].astype(str), task1["label"]):
        if int(label) == 0:
            strata.append("negative")
        elif person_id in subtype.index:
            strata.append("hypothyroidism" if int(subtype.loc[person_id]) == 0 else "thyrotoxicosis")
        elif person_id in mixed_ids:
            strata.append("mixed")
        else:
            strata.append("positive_unclassified")
    return pd.Series(strata, index=task1.index, dtype="string")


def allocation_counts(n: int, train_ratio: float, val_ratio: float) -> tuple[int, int, int]:
    if n <= 0:
        return 0, 0, 0
    if n == 1:
        return 1, 0, 0
    if n == 2:
        return 1, 0, 1

    n_train = max(1, int(round(n * train_ratio)))
    n_val = max(1, int(round(n * val_ratio)))
    n_test = n - n_train - n_val
    if n_test < 1:
        n_test = 1
        if n_train >= n_val and n_train > 1:
            n_train -= 1
        elif n_val > 1:
            n_val -= 1
    while n_train + n_val + n_test > n:
        if n_train > 1:
            n_train -= 1
        elif n_val > 1:
            n_val -= 1
        else:
            n_test -= 1
    return n_train, n_val, n_test


def make_split_table(
    task1_labels: pd.DataFrame,
    strata: pd.Series,
    seed: int,
    train_ratio: float,
    val_ratio: float,
) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    table = task1_labels[["person_id", "label"]].copy()
    table["stratum"] = strata.values
    table["split"] = ""

    for _, indices in table.groupby("stratum", sort=True).groups.items():
        indices = np.asarray(list(indices))
        rng.shuffle(indices)
        n_train, n_val, _ = allocation_counts(len(indices), train_ratio, val_ratio)
        table.loc[indices[:n_train], "split"] = "train"
        table.loc[indices[n_train:n_train + n_val], "split"] = "val"
        table.loc[indices[n_train + n_val:], "split"] = "test"

    if (table["split"] == "").any():
        raise RuntimeError("Some patients were not assigned to a split")
    return table


def numeric_frame(frame: pd.DataFrame, columns: list[str]) -> np.ndarray:
    converted = frame[columns].apply(pd.to_numeric, errors="coerce")
    return converted.to_numpy(dtype=np.float64)


def build_raw_arrays(
    frame: pd.DataFrame,
    labels: pd.DataFrame,
    dynamic_features: list[str],
    mapping: dict[str, dict[str, str]],
) -> dict[str, np.ndarray | list[str]]:
    label_map = labels.set_index("person_id")["label"]
    missing_labels = sorted(set(frame["person_id"]) - set(label_map.index))
    if missing_labels:
        raise ValueError(f"Feature rows without labels: {missing_labels[:10]}")

    n_patients = len(frame)
    n_times = len(TIME_POINTS)
    n_dynamic = len(dynamic_features)
    x = np.full((n_patients, n_times, n_dynamic), np.nan, dtype=np.float64)
    for time_idx, time_point in enumerate(TIME_POINTS):
        columns = [mapping[feature][time_point] for feature in dynamic_features]
        x[:, time_idx, :] = numeric_frame(frame, columns)

    static = numeric_frame(frame, STATIC_FEATURES)
    labels_array = frame["person_id"].map(label_map).to_numpy(dtype=np.int64)

    # base is always the first usable step. Follow-up steps must be consecutive.
    lens = np.ones(n_patients, dtype=np.int64)
    for row_idx, row in frame.iterrows():
        length = 1
        for point in FOLLOWUP_POINTS:
            flag = pd.to_numeric(pd.Series([row[OBSERVATION_FLAGS[point]]]), errors="coerce").iloc[0]
            if pd.notna(flag) and int(flag) == 1:
                length += 1
            else:
                break
        lens[row_idx] = length
        if length < n_times:
            x[row_idx, length:, :] = np.nan

    return {
        "person_ids": frame["person_id"].astype(str).tolist(),
        "x": x,
        "static": static,
        "labels": labels_array,
        "lens": lens,
    }


def fit_normalizer(task1_arrays: dict, train_indices: np.ndarray) -> dict[str, np.ndarray]:
    train_x = task1_arrays["x"][train_indices]
    train_static = task1_arrays["static"][train_indices]

    with np.errstate(invalid="ignore"):
        dynamic_mean = np.nanmean(train_x, axis=(0, 1))
        dynamic_std = np.nanstd(train_x, axis=(0, 1))
        static_mean = np.nanmean(train_static, axis=0)
        static_std = np.nanstd(train_static, axis=0)

    dynamic_mean = np.nan_to_num(dynamic_mean, nan=0.0)
    static_mean = np.nan_to_num(static_mean, nan=0.0)
    dynamic_std = np.where(np.isfinite(dynamic_std) & (dynamic_std > 0), dynamic_std, 1.0)
    static_std = np.where(np.isfinite(static_std) & (static_std > 0), static_std, 1.0)
    return {
        "dynamic_mean": dynamic_mean,
        "dynamic_std": dynamic_std,
        "static_mean": static_mean,
        "static_std": static_std,
    }


def normalize_arrays(arrays: dict, normalizer: dict[str, np.ndarray]) -> dict:
    x_raw = arrays["x"]
    static_raw = arrays["static"]
    mask = np.isfinite(x_raw).astype(np.float32)
    static_mask = np.isfinite(static_raw).astype(np.float32)

    x = (x_raw - normalizer["dynamic_mean"][None, None, :]) / normalizer["dynamic_std"][None, None, :]
    static = (static_raw - normalizer["static_mean"][None, :]) / normalizer["static_std"][None, :]
    x = np.where(mask == 1, x, 0.0).astype(np.float32)
    static = np.where(static_mask == 1, static, 0.0).astype(np.float32)
    return {
        "person_ids": arrays["person_ids"],
        "x": x,
        "mask": mask,
        "lens": arrays["lens"].astype(np.int64),
        "static": static,
        "static_mask": static_mask,
        "labels": arrays["labels"].astype(np.int64),
    }


def subset_arrays(arrays: dict, indices: np.ndarray) -> dict:
    return {
        "person_ids": [arrays["person_ids"][idx] for idx in indices],
        "x": arrays["x"][indices],
        "mask": arrays["mask"][indices],
        "lens": arrays["lens"][indices],
        "static": arrays["static"][indices],
        "static_mask": arrays["static_mask"][indices],
        "labels": arrays["labels"][indices],
    }


def package_task(arrays: dict, split_lookup: dict[str, str]) -> dict:
    split_indices = {
        split: np.asarray(
            [idx for idx, person_id in enumerate(arrays["person_ids"])
             if split_lookup[person_id] == split],
            dtype=np.int64,
        )
        for split in ("train", "val", "test")
    }
    return {split: subset_arrays(arrays, indices) for split, indices in split_indices.items()}


def class_counts(labels: np.ndarray) -> dict[str, int]:
    return {str(label): int((labels == label).sum()) for label in (0, 1)}


def main() -> None:
    args = parse_args()
    ratio_sum = args.train_ratio + args.val_ratio + args.test_ratio
    if not np.isclose(ratio_sum, 1.0):
        raise ValueError("train/val/test ratios must sum to 1")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    task1_features = read_csv(args.raw_dir / "feature_model_task1.csv")
    task2_features = read_csv(args.raw_dir / "feature_model_task2.csv")
    task1_labels = read_csv(args.raw_dir / "smart_task1_labels.csv")
    task2_labels = read_csv(args.raw_dir / "smart_task2_labels.csv")
    audit = read_csv(args.raw_dir / "labeling_audit.csv")

    for name, frame in (
        ("feature_model_task1.csv", task1_features),
        ("feature_model_task2.csv", task2_features),
        ("smart_task1_labels.csv", task1_labels),
        ("smart_task2_labels.csv", task2_labels),
        ("labeling_audit.csv", audit),
    ):
        require_columns(frame, ["person_id"], name)
        assert_unique_person(frame, name)
    validate_binary_label(task1_labels, "smart_task1_labels.csv")
    validate_binary_label(task2_labels, "smart_task2_labels.csv")

    task1_features = task1_features.sort_values("person_id").reset_index(drop=True)
    task2_features = task2_features.sort_values("person_id").reset_index(drop=True)
    task1_labels = task1_labels.sort_values("person_id").reset_index(drop=True)
    task2_labels = task2_labels.sort_values("person_id").reset_index(drop=True)

    if set(task1_features["person_id"]) != set(task1_labels["person_id"]):
        raise ValueError("Task 1 feature and label patient sets differ")
    if set(task2_features["person_id"]) != set(task2_labels["person_id"]):
        raise ValueError("Task 2 feature and label patient sets differ")
    if not set(task2_labels["person_id"]).issubset(set(task1_labels["person_id"])):
        raise ValueError("Task 2 patients must be a subset of Task 1")

    required_feature_columns = ["person_id", "outcome", *STATIC_FEATURES, *OBSERVATION_FLAGS.values()]
    require_columns(task1_features, required_feature_columns, "feature_model_task1.csv")
    require_columns(task2_features, required_feature_columns + ["subtype_outcome"], "feature_model_task2.csv")

    dynamic_features, mapping = split_dynamic_columns(task1_features.columns.tolist())
    validate_feature_columns(task1_features, dynamic_features, mapping, "Task 1")
    validate_feature_columns(task2_features, dynamic_features, mapping, "Task 2")

    exported_task1 = pd.to_numeric(task1_features["outcome"], errors="coerce")
    merged_task1_label = task1_features["person_id"].map(task1_labels.set_index("person_id")["label"])
    if not exported_task1.equals(merged_task1_label.astype(exported_task1.dtype)):
        raise ValueError("Task 1 outcome column disagrees with smart_task1_labels.csv")
    exported_task2 = pd.to_numeric(task2_features["subtype_outcome"], errors="coerce")
    merged_task2_label = task2_features["person_id"].map(task2_labels.set_index("person_id")["label"])
    if not exported_task2.equals(merged_task2_label.astype(exported_task2.dtype)):
        raise ValueError("Task 2 subtype_outcome disagrees with smart_task2_labels.csv")

    task1_for_split = task1_labels.copy()
    strata = stratum_for_patient(task1_for_split, task2_labels, audit)
    split_table = make_split_table(
        task1_for_split, strata, args.seed, args.train_ratio, args.val_ratio
    )
    split_lookup = dict(zip(split_table["person_id"].astype(str), split_table["split"]))

    task1_raw = build_raw_arrays(task1_features, task1_labels, dynamic_features, mapping)
    task2_raw = build_raw_arrays(task2_features, task2_labels, dynamic_features, mapping)
    task1_train_indices = np.asarray(
        [idx for idx, person_id in enumerate(task1_raw["person_ids"])
         if split_lookup[person_id] == "train"],
        dtype=np.int64,
    )
    if len(task1_train_indices) == 0:
        raise ValueError("Task 1 training split is empty")

    normalizer = fit_normalizer(task1_raw, task1_train_indices)
    task1 = package_task(normalize_arrays(task1_raw, normalizer), split_lookup)
    task2 = package_task(normalize_arrays(task2_raw, normalizer), split_lookup)

    metadata = {
        "seed": args.seed,
        "time_points": TIME_POINTS,
        "excluded_outcome_window": EXCLUDED_OUTCOME_WINDOW,
        "dynamic_features": dynamic_features,
        "static_features": STATIC_FEATURES,
        "input_dim": len(dynamic_features),
        "static_dim": len(STATIC_FEATURES),
        "max_len": len(TIME_POINTS),
        "task1_label": {"0": "AITD_negative", "1": "AITD_positive"},
        "task2_label": {"0": "hypothyroidism", "1": "thyrotoxicosis"},
        "normalization_source": "Task 1 training patients only",
        "splits": {},
    }
    for task_name, task_data in (("task1", task1), ("task2", task2)):
        metadata["splits"][task_name] = {
            split: {
                "n": int(len(data["labels"])),
                "class_counts": class_counts(data["labels"]),
            }
            for split, data in task_data.items()
        }

    for task_name, task_data in (("task1", task1), ("task2", task2)):
        with (args.output_dir / f"{task_name}.pkl").open("wb") as handle:
            pickle.dump({"splits": task_data, "metadata": metadata}, handle, protocol=4)

    split_table.to_csv(args.output_dir / "patient_splits.csv", index=False)
    np.savez(args.output_dir / "normalization.npz", **normalizer)
    with (args.output_dir / "metadata.json").open("w", encoding="utf-8") as handle:
        json.dump(metadata, handle, ensure_ascii=False, indent=2)

    print(json.dumps(metadata, ensure_ascii=False, indent=2))
    print(f"Processed datasets written to: {args.output_dir}")


if __name__ == "__main__":
    main()
