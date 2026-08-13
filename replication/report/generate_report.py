#!/usr/bin/env python3
"""Generate Table 1-6, Figure 1-5, and a report from replication outputs.

The script does not fit models. Run preprocessing&model.ipynb first, then run:

    python generate_report.py --input-dir /path/to/replication_python_run_YYYYMMDD

All patient-level inputs remain in input-dir. Aggregate tables, figures, Markdown,
HTML, and PDF are written below input-dir/report_outputs by default.
"""

from __future__ import annotations

import argparse
import html
import json
import math
import re
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from textwrap import fill
from typing import Iterable, Sequence

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns
from lifelines import KaplanMeierFitter
from lifelines.statistics import logrank_test
from matplotlib.colors import Normalize
from matplotlib.patches import FancyBboxPatch
from sklearn.metrics import (
    average_precision_score,
    confusion_matrix,
    f1_score,
    precision_recall_curve,
    precision_score,
    recall_score,
)


TARGET = "aitd_flag"
MODEL_ORDER = ["XGBoost", "AdaBoost", "KNN", "Logistic Regression"]
SAMPLER_ORDER = ["none", "b-smote", "enn", "b-smote-enn"]
SAMPLER_LABELS = {
    "none": "Raw",
    "b-smote": "B-SMOTE",
    "enn": "ENN",
    "b-smote-enn": "B-SMOTE + ENN",
}
THRESHOLD_ORDER = [
    "A (Top 1%)",
    "B (Top 5%)",
    "C (Optimal F1)",
    "D (Top 15%)",
    "E (Top 25%)",
]


@dataclass(frozen=True)
class FeatureSpec:
    section: str
    column: str
    label: str
    kind: str  # continuous or binary


FEATURE_SPECS = [
    FeatureSpec("Patient demographics", "male_flag", "Male", "binary"),
    FeatureSpec("Patient demographics", "age_at_index", "Age (years)", "continuous"),
    FeatureSpec("Patient demographics", "height_cm", "Height (cm)", "continuous"),
    FeatureSpec("Patient demographics", "weight_kg", "Weight (kg)", "continuous"),
    FeatureSpec("Patient demographics", "bmi", "BMI (kg/m^2)", "continuous"),
    FeatureSpec("Patient demographics", "charlson_index", "Charlson comorbidity index", "continuous"),
    FeatureSpec("Patient demographics", "current_smoker_flag", "Current smoker", "binary"),
    FeatureSpec("Patient demographics", "current_drinker_flag", "Current drinker", "binary"),
    FeatureSpec("Use of amiodarone", "cumulative_dose_g", "Cumulative dose (g)", "continuous"),
    FeatureSpec("Use of amiodarone", "duration_span_days", "Exposure span (days)", "continuous"),
    FeatureSpec("Use of amiodarone", "sum_days", "Summed prescription days", "continuous"),
    FeatureSpec("Use of amiodarone", "pdd_g_per_day", "Prescription daily dose (g/day)", "continuous"),
    FeatureSpec("Use of amiodarone", "aver_dose_g_per_kg", "Cumulative dose per kg body weight (g/kg)", "continuous"),
    FeatureSpec("Laboratory data", "tsh_value", "Thyroid-stimulating hormone (mU/L)", "continuous"),
    FeatureSpec("Laboratory data", "ft4_value", "Free thyroxine (ng/dL)", "continuous"),
    FeatureSpec("Laboratory data", "rbc_value", "Red blood cells", "continuous"),
    FeatureSpec("Laboratory data", "hgb_value", "Hemoglobin", "continuous"),
    FeatureSpec("Laboratory data", "hct_value", "Hematocrit (%)", "continuous"),
    FeatureSpec("Laboratory data", "mcv_value", "Mean corpuscular volume (fL)", "continuous"),
    FeatureSpec("Laboratory data", "mch_value", "Mean corpuscular hemoglobin (pg)", "continuous"),
    FeatureSpec("Laboratory data", "mchc_value", "Mean corpuscular hemoglobin concentration", "continuous"),
    FeatureSpec("Laboratory data", "tg_value", "Triglycerides (mg/dL)", "continuous"),
    FeatureSpec("Laboratory data", "ast_value", "AST", "continuous"),
    FeatureSpec("Laboratory data", "alt_value", "ALT", "continuous"),
    FeatureSpec("Laboratory data", "hdl_value", "HDL cholesterol (mg/dL)", "continuous"),
    FeatureSpec("Laboratory data", "ldl_value", "LDL cholesterol (mg/dL)", "continuous"),
    FeatureSpec("Laboratory data", "scr_value", "Serum creatinine", "continuous"),
    FeatureSpec("Laboratory data", "alkp_value", "Alkaline phosphatase", "continuous"),
    FeatureSpec("Laboratory data", "cholesterol_value", "Total cholesterol", "continuous"),
    FeatureSpec("Concurrent medication", "rx_tkis_flag", "Tyrosine kinase inhibitors", "binary"),
    FeatureSpec("Concurrent medication", "rx_allopurinol_flag", "Allopurinol", "binary"),
    FeatureSpec("Concurrent medication", "rx_antipsychotic_flag", "Antipsychotics", "binary"),
    FeatureSpec("Concurrent medication", "rx_nsaid_flag", "Nonsteroidal anti-inflammatory drugs", "binary"),
    FeatureSpec("Concurrent medication", "rx_antidms_flag", "Diabetes medications", "binary"),
    FeatureSpec("Concurrent medication", "rx_metformin_flag", "Metformin", "binary"),
    FeatureSpec("Concurrent medication", "rx_propafenone_flag", "Propafenone", "binary"),
    FeatureSpec("Concurrent diseases", "dx_bradycardia_flag", "Bradycardia", "binary"),
    FeatureSpec("Concurrent diseases", "dx_goiter_flag", "Goiter", "binary"),
    FeatureSpec("Concurrent diseases", "dx_anemia_flag", "Anemia", "binary"),
    FeatureSpec("Concurrent diseases", "dx_hypertension_flag", "Hypertension", "binary"),
    FeatureSpec("Concurrent diseases", "dx_diabetes_flag", "Diabetes", "binary"),
    FeatureSpec("Concurrent diseases", "dx_dm_nephropathy_flag", "Diabetic nephropathy", "binary"),
    FeatureSpec("Concurrent diseases", "dx_dm_complications_flag", "Diabetes complications", "binary"),
    FeatureSpec("Concurrent diseases", "dx_gouts_flag", "Gout", "binary"),
    FeatureSpec("Concurrent diseases", "dx_chronic_rf_flag", "Chronic renal failure", "binary"),
    FeatureSpec("Concurrent diseases", "dx_renal_dysfunction_flag", "Renal dysfunction", "binary"),
    FeatureSpec("Concurrent diseases", "dx_ra_flag", "Rheumatoid arthritis", "binary"),
]


def read_csv(path: Path, required_columns: Sequence[str] = ()) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(f"Required report input not found: {path}")
    frame = pd.read_csv(path)
    missing = sorted(set(required_columns) - set(frame.columns))
    if missing:
        raise ValueError(f"{path.name} is missing columns: {missing}")
    return frame


def write_csv(frame: pd.DataFrame, path: Path) -> None:
    frame.to_csv(path, index=False, encoding="utf-8-sig")


def round_numeric(frame: pd.DataFrame, digits: int = 4) -> pd.DataFrame:
    rounded = frame.copy()
    numeric_columns = rounded.select_dtypes(include=[np.number]).columns
    rounded.loc[:, numeric_columns] = rounded.loc[:, numeric_columns].round(digits)
    return rounded


def as_bool(series: pd.Series) -> pd.Series:
    if pd.api.types.is_bool_dtype(series):
        return series.fillna(False)
    return series.astype(str).str.strip().str.lower().isin({"true", "1", "yes"})


def numeric_summary(series: pd.Series) -> str:
    values = pd.to_numeric(series, errors="coerce").dropna()
    if values.empty:
        return "NA"
    q1, median, q3 = values.quantile([0.25, 0.5, 0.75])
    return f"{median:.2f} ({q1:.2f}-{q3:.2f}); n={len(values):,}"


def binary_summary(series: pd.Series, denominator: int) -> str:
    values = pd.to_numeric(series, errors="coerce")
    if values.notna().sum() == 0:
        return "NA"
    positive = int((values == 1).sum())
    percent = positive / denominator * 100 if denominator else math.nan
    return f"{positive:,} ({percent:.2f}%)"


def table1_characteristics(features: pd.DataFrame) -> tuple[pd.DataFrame, list[str]]:
    if TARGET not in features or "person_id" not in features:
        raise ValueError("report_features_before_imputation.csv needs person_id and aitd_flag")
    if features["person_id"].duplicated().any():
        raise ValueError("Duplicate person_id in report feature snapshot")
    outcome = pd.to_numeric(features[TARGET], errors="raise").astype(int)
    if not set(outcome.unique()).issubset({0, 1}):
        raise ValueError("aitd_flag must contain only 0 and 1")

    groups = [
        ("Total", features),
        ("AITD", features.loc[outcome == 1]),
        ("Non-AITD", features.loc[outcome == 0]),
    ]
    rows: list[dict[str, object]] = []
    omitted: list[str] = []
    for spec in FEATURE_SPECS:
        if spec.column not in features.columns:
            omitted.append(spec.column)
            continue
        row: dict[str, object] = {
            "Section": spec.section,
            "Variable": spec.column,
            "Characteristic": spec.label,
            "Statistic": "n (%)" if spec.kind == "binary" else "median (IQR)",
        }
        for label, group in groups:
            row[label] = (
                binary_summary(group[spec.column], len(group))
                if spec.kind == "binary"
                else numeric_summary(group[spec.column])
            )
        rows.append(row)
    return pd.DataFrame(rows), omitted


def table2_missingness(features: pd.DataFrame) -> pd.DataFrame:
    excluded = {"person_id", TARGET}
    rows = []
    for column in features.columns:
        if column in excluded:
            continue
        missing_n = int(features[column].isna().sum())
        rows.append({
            "Variable": column,
            "N_missing": missing_n,
            "Missing_rate_percent": round(missing_n / len(features) * 100, 4),
        })
    return pd.DataFrame(rows)


def table3_selection(input_dir: Path) -> tuple[pd.DataFrame, pd.DataFrame]:
    manifest = read_csv(
        input_dir / "rfecv_feature_selection_all_models.csv",
        ["selector_model", "scoring", "best_cv_score", "feature", "selected"],
    )
    manifest["selected"] = as_bool(manifest["selected"])
    rows = []
    for model in ["AdaBoost", "XGBoost"]:
        subset = manifest.loc[manifest["selector_model"] == model]
        if subset.empty:
            raise ValueError(f"RFECV manifest has no {model} rows")
        selected = subset.loc[subset["selected"], "feature"].astype(str).tolist()
        rows.append({
            "Model": model,
            "Selection_criterion": str(subset["scoring"].iloc[0]),
            "Best_5fold_score": float(subset["best_cv_score"].iloc[0]),
            "Count": len(selected),
            "Selected_feature_list": ", ".join(selected),
        })

    intersection = read_csv(
        input_dir / "recursive_selected_feature_intersection.csv", ["feature"]
    )["feature"].astype(str).tolist()
    if not intersection:
        raise ValueError("Final AdaBoost-XGBoost feature intersection is empty")
    rows.append({
        "Model": "Final intersection",
        "Selection_criterion": "AdaBoost ∩ XGBoost",
        "Best_5fold_score": np.nan,
        "Count": len(intersection),
        "Selected_feature_list": ", ".join(intersection),
    })
    return pd.DataFrame(rows), manifest


def threshold_metrics(predictions: pd.DataFrame, thresholds: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    predictions = predictions.copy()
    predictions["y_true"] = pd.to_numeric(predictions["y_true"], errors="raise").astype(int)
    predictions["y_probability"] = pd.to_numeric(predictions["y_probability"], errors="raise")
    if not set(predictions["y_true"].unique()).issubset({0, 1}):
        raise ValueError("held-out y_true must contain only 0 and 1")
    if predictions["y_probability"].isna().any():
        raise ValueError("held-out predictions contain missing probabilities")

    threshold_map = dict(zip(thresholds["name"].astype(str), thresholds["threshold"].astype(float)))
    missing_thresholds = [name for name in THRESHOLD_ORDER if name not in threshold_map]
    if missing_thresholds:
        raise ValueError(f"Missing frozen thresholds: {missing_thresholds}")

    metric_rows = []
    km_rows = []
    y_true = predictions["y_true"].to_numpy()
    y_prob = predictions["y_probability"].to_numpy()
    has_survival = "followup_time_days" in predictions.columns
    time = predictions["followup_time_days"].to_numpy(dtype=float) if has_survival else None

    for cutoff in THRESHOLD_ORDER:
        threshold = threshold_map[cutoff]
        y_pred = (y_prob >= threshold).astype(int)
        tn, fp, fn, tp = confusion_matrix(y_true, y_pred, labels=[0, 1]).ravel()
        specificity = tn / (tn + fp) if (tn + fp) else np.nan
        npv = tn / (tn + fn) if (tn + fn) else np.nan
        recall = recall_score(y_true, y_pred, zero_division=0)
        precision = precision_score(y_true, y_pred, zero_division=0)
        actual_percent = y_pred.mean() * 100
        metric_rows.append({
            "Cutoff": cutoff,
            "Holdout_high_risk_percent": actual_percent,
            "Threshold": threshold,
            "F1_score": f1_score(y_true, y_pred, zero_division=0),
            "Recall": recall,
            "Specificity": specificity,
            "Precision_PPV": precision,
            "NPV": npv,
            "N_high_risk": int(y_pred.sum()),
            "N_low_risk": int((1 - y_pred).sum()),
            "TP": int(tp), "FP": int(fp), "TN": int(tn), "FN": int(fn),
        })

        if has_survival:
            high = y_pred == 1
            low = ~high
            if high.any() and low.any():
                result = logrank_test(
                    time[high], time[low],
                    event_observed_A=y_true[high], event_observed_B=y_true[low],
                )
                p_value = float(result.p_value)
            else:
                p_value = np.nan
            km_rows.append({
                "Cutoff": cutoff,
                "Threshold": threshold,
                "N_high_risk": int(high.sum()),
                "N_low_risk": int(low.sum()),
                "Events_high_risk": int(y_true[high].sum()),
                "Events_low_risk": int(y_true[low].sum()),
                "Logrank_p_value": p_value,
            })
    return pd.DataFrame(metric_rows), pd.DataFrame(km_rows)


def save_figure(fig: plt.Figure, stem: Path) -> None:
    fig.savefig(stem.with_suffix(".png"), dpi=300, bbox_inches="tight", facecolor="white")
    fig.savefig(stem.with_suffix(".pdf"), bbox_inches="tight", facecolor="white")
    plt.close(fig)


def figure1_cohort(flow: pd.DataFrame, qa: pd.DataFrame, stem: Path) -> None:
    flow = flow.sort_values("stage_order").reset_index(drop=True)
    qa_map = dict(zip(qa["item"].astype(str), qa["value"].astype(int)))
    final_n = int(flow.iloc[-1]["n"])
    positive = int(qa_map.get("aitd_positive", 0))
    negative = final_n - positive
    n_stages = len(flow)
    fig, ax = plt.subplots(figsize=(11, max(8, n_stages * 1.15)))
    ax.set_xlim(0, 12)
    ax.set_ylim(-2.2, n_stages + 0.7)
    ax.axis("off")

    ys = list(reversed(range(n_stages)))
    previous = None
    for idx, (row, y) in enumerate(zip(flow.itertuples(index=False), ys)):
        box = FancyBboxPatch(
            (1.0, y - 0.28), 6.8, 0.56,
            boxstyle="round,pad=0.08,rounding_size=0.08",
            facecolor="#dceef8" if idx == n_stages - 1 else "#f2f5f7",
            edgecolor="#2474a6", linewidth=1.2,
        )
        ax.add_patch(box)
        ax.text(4.4, y, f"{fill(str(row.stage), 52)}\n(n={int(row.n):,})", ha="center", va="center", fontsize=9)
        if previous is not None:
            ax.annotate("", xy=(4.4, y + 0.31), xytext=(4.4, previous - 0.31),
                        arrowprops=dict(arrowstyle="->", color="#2474a6", lw=1.2))
            excluded = int(flow.iloc[idx - 1]["n"] - row.n)
            ax.text(8.35, (previous + y) / 2, f"Excluded at step: {excluded:,}",
                    va="center", fontsize=9, color="#9b2c2c")
        previous = y

    branch_y = -1.45
    final_y = ys[-1]
    ax.plot([4.4, 4.4], [final_y - 0.31, branch_y + 0.75], color="#2474a6", lw=1.2)
    ax.plot([2.5, 6.3], [branch_y + 0.75, branch_y + 0.75], color="#2474a6", lw=1.2)
    for x, label, count, color in [
        (2.5, "Non-AITD", negative, "#d9ead3"),
        (6.3, "AITD", positive, "#f4cccc"),
    ]:
        ax.plot([x, x], [branch_y + 0.75, branch_y + 0.3], color="#2474a6", lw=1.2)
        patch = FancyBboxPatch((x - 1.35, branch_y - 0.25), 2.7, 0.55,
                               boxstyle="round,pad=0.08", facecolor=color,
                               edgecolor="#2474a6", linewidth=1.2)
        ax.add_patch(patch)
        ax.text(x, branch_y + 0.02, f"{label}\n(n={count:,})", ha="center", va="center", fontsize=10)
    ax.set_title("Participant selection for the external validation cohort", fontsize=15, weight="bold", pad=12)
    save_figure(fig, stem)


def figure2_recursive(input_dir: Path, stem: Path) -> None:
    fig, axes = plt.subplots(1, 2, figsize=(13, 5.2), sharey=False)
    for ax, model, filename in zip(
        axes,
        ["AdaBoost", "XGBoost"],
        ["recursive_accuracy_history_adaboost.csv", "recursive_accuracy_history_xgboost.csv"],
    ):
        history = read_csv(input_dir / filename, ["n_features", "mean_cv_accuracy", "std_cv_accuracy"])
        history = history.sort_values("n_features")
        best_score = history["mean_cv_accuracy"].max()
        best = history.loc[np.isclose(history["mean_cv_accuracy"], best_score)].sort_values("n_features").iloc[0]
        x = history["n_features"].to_numpy(dtype=float)
        mean = history["mean_cv_accuracy"].to_numpy(dtype=float)
        std = history["std_cv_accuracy"].to_numpy(dtype=float)
        ax.plot(x, mean, marker="o", markersize=3, color="#1379b8")
        ax.fill_between(x, mean - std, mean + std, color="#1379b8", alpha=0.18)
        ax.axvline(best["n_features"], color="#222222", linestyle="--", lw=1)
        ax.scatter([best["n_features"]], [best["mean_cv_accuracy"]], color="#c0392b", zorder=5)
        ax.text(
            0.98, 0.05,
            f"Best n={int(best['n_features'])}\nAccuracy={best['mean_cv_accuracy']:.4f}",
            transform=ax.transAxes, ha="right", va="bottom",
            bbox=dict(boxstyle="round", facecolor="white", edgecolor="#777777"), fontsize=9,
        )
        ax.set_title(model)
        ax.set_xlabel("Number of remaining features")
        ax.set_ylabel("Mean 5-fold validation accuracy")
        ax.grid(alpha=0.25)
    fig.suptitle("Recursive one-feature-at-a-time elimination", fontsize=15, weight="bold")
    fig.tight_layout()
    save_figure(fig, stem)


def figure3_performance(holdout: pd.DataFrame, stem: Path) -> None:
    metrics = ["AUPRC", "F1", "G-mean", "Recall"]
    missing = sorted(set(["Model", "Sampler", *metrics]) - set(holdout.columns))
    if missing:
        raise ValueError(f"final_holdout_performance.csv missing: {missing}")
    plot_data = holdout.copy()
    plot_data["Sampler_label"] = plot_data["Sampler"].map(SAMPLER_LABELS).fillna(plot_data["Sampler"])
    fig, axes = plt.subplots(2, 2, figsize=(14, 9), sharey=True)
    colors = ["#e8a8a5", "#afc982", "#75c9cf", "#c5a2e5"]
    for ax, metric in zip(axes.flat, metrics):
        sns.barplot(
            data=plot_data, x="Model", y=metric, hue="Sampler_label",
            order=MODEL_ORDER,
            hue_order=[SAMPLER_LABELS[s] for s in SAMPLER_ORDER],
            palette=colors, edgecolor="white", ax=ax,
        )
        ax.set_ylim(0, 1.05)
        ax.set_title(metric, weight="bold")
        ax.set_xlabel("")
        ax.tick_params(axis="x", rotation=15)
        for container in ax.containers:
            ax.bar_label(container, fmt="%.3f", fontsize=6, padding=1)
        if ax is not axes.flat[0]:
            legend = ax.get_legend()
            if legend:
                legend.remove()
    axes.flat[0].legend(title="Strategy", fontsize=8, title_fontsize=9)
    fig.suptitle("Hold-out performance by resampling strategy", fontsize=16, weight="bold")
    fig.tight_layout()
    save_figure(fig, stem)


def figure4_shap(input_dir: Path, stem: Path, max_display: int = 20) -> None:
    importance = read_csv(input_dir / "shap_importance.csv", ["feature", "mean_abs_shap"])
    shap_frame = read_csv(input_dir / "shap_values_heldout.csv", ["person_id"])
    value_frame = read_csv(input_dir / "shap_feature_values_heldout.csv", ["person_id"])
    if not shap_frame["person_id"].equals(value_frame["person_id"]):
        raise ValueError("SHAP values and feature values are not aligned by person_id")
    features = [f for f in importance.sort_values("mean_abs_shap", ascending=False)["feature"]
                if f in shap_frame.columns and f in value_frame.columns][:max_display]
    if not features:
        raise ValueError("No aligned SHAP features found")
    imp_map = importance.set_index("feature")["mean_abs_shap"]

    fig, (ax_bar, ax_dot) = plt.subplots(1, 2, figsize=(14, max(7, len(features) * 0.38)), gridspec_kw={"width_ratios": [1, 1.35]})
    display = list(reversed(features))
    y_positions = np.arange(len(display))
    ax_bar.barh(y_positions, [imp_map[f] for f in display], color="#1696e8")
    ax_bar.set_yticks(y_positions, labels=display)
    ax_bar.set_xlabel("mean(|SHAP value|)")
    ax_bar.set_title("Global importance", weight="bold")
    ax_bar.grid(axis="x", alpha=0.2)

    rng = np.random.default_rng(42)
    scatter_ref = None
    for y, feature in enumerate(display):
        shap_values = pd.to_numeric(shap_frame[feature], errors="coerce").to_numpy(dtype=float)
        feature_values = pd.to_numeric(value_frame[feature], errors="coerce").to_numpy(dtype=float)
        valid = np.isfinite(shap_values) & np.isfinite(feature_values)
        if not valid.any():
            continue
        sv = shap_values[valid]
        fv = feature_values[valid]
        low, high = np.nanpercentile(fv, [5, 95])
        if not np.isfinite(low) or not np.isfinite(high) or high <= low:
            color_values = np.full(len(fv), 0.5)
        else:
            color_values = np.clip((fv - low) / (high - low), 0, 1)
        jitter = rng.normal(0, 0.09, size=len(sv))
        scatter_ref = ax_dot.scatter(sv, y + jitter, c=color_values, cmap="coolwarm", norm=Normalize(0, 1), s=13, alpha=0.75, linewidth=0)
    ax_dot.axvline(0, color="#666666", lw=0.8)
    ax_dot.set_yticks(y_positions, labels=display)
    ax_dot.set_xlabel("SHAP value (impact on model output)")
    ax_dot.set_title("Held-out SHAP distribution", weight="bold")
    ax_dot.grid(axis="x", alpha=0.2)
    if scatter_ref is not None:
        colorbar = fig.colorbar(scatter_ref, ax=ax_dot, fraction=0.035, pad=0.03)
        colorbar.set_ticks([0, 1], labels=["Low", "High"])
        colorbar.set_label("Feature value")
    fig.suptitle("XGBoost + Borderline-SMOTE explainability", fontsize=15, weight="bold")
    fig.tight_layout()
    save_figure(fig, stem)


def figure5_threshold_km(predictions: pd.DataFrame, thresholds: pd.DataFrame, stem: Path) -> None:
    required = ["person_id", "y_true", "y_probability", "followup_time_days"]
    missing = sorted(set(required) - set(predictions.columns))
    if missing:
        raise ValueError(f"heldout_predictions_xgboost_bsmote.csv missing: {missing}")
    threshold_map = dict(zip(thresholds["name"].astype(str), thresholds["threshold"].astype(float)))
    y = predictions["y_true"].astype(int).to_numpy()
    prob = predictions["y_probability"].astype(float).to_numpy()
    time = predictions["followup_time_days"].astype(float).to_numpy()
    precision, recall, _ = precision_recall_curve(y, prob)
    ap = average_precision_score(y, prob)

    fig = plt.figure(figsize=(16, 10))
    grid = fig.add_gridspec(3, 4, width_ratios=[1.1, 1.1, 1, 1], hspace=0.52, wspace=0.42)
    ax_pr = fig.add_subplot(grid[:, :2])
    ax_pr.plot(recall, precision, color="#173f8a", lw=2, label=f"Held-out PR curve (AP={ap:.4f})")
    ax_pr.fill_between(recall, precision, color="#5879bd", alpha=0.18)
    palette = ["#173f8a", "#2d9cdb", "#f2c94c", "#eb5757", "#9b51e0"]
    for name, color in zip(THRESHOLD_ORDER, palette):
        threshold = threshold_map[name]
        pred = prob >= threshold
        p = precision_score(y, pred, zero_division=0)
        r = recall_score(y, pred, zero_division=0)
        ax_pr.scatter(r, p, s=80, color=color, edgecolor="black", linewidth=0.5,
                      label=f"{name}: t={threshold:.3f}")
    ax_pr.set_xlabel("Recall (sensitivity)")
    ax_pr.set_ylabel("Precision (PPV)")
    ax_pr.set_xlim(0, 1.02)
    ax_pr.set_ylim(0, 1.05)
    ax_pr.grid(alpha=0.25)
    ax_pr.legend(loc="lower left", fontsize=8)
    ax_pr.set_title("Frozen development-OOF thresholds", weight="bold")

    km_positions = [(0, 2), (0, 3), (1, 2), (1, 3), (2, slice(2, 4))]
    for name, position in zip(THRESHOLD_ORDER, km_positions):
        row, col = position
        ax = fig.add_subplot(grid[row, col])
        threshold = threshold_map[name]
        high = prob >= threshold
        low = ~high
        if high.any() and low.any():
            kmf = KaplanMeierFitter()
            kmf.fit(time[low], y[low], label=f"Low risk (n={low.sum()})")
            kmf.plot_cumulative_density(ax=ax, color="#2e8b57", ci_show=False, lw=1.8)
            kmf.fit(time[high], y[high], label=f"High risk (n={high.sum()})")
            kmf.plot_cumulative_density(ax=ax, color="#d64545", ci_show=False, lw=1.8)
            lr = logrank_test(time[high], time[low], event_observed_A=y[high], event_observed_B=y[low])
            p_text = f"p={lr.p_value:.2e}"
        else:
            p_text = "one risk group empty"
        ax.set_title(f"{name}\n{p_text}", fontsize=9, weight="bold")
        ax.set_xlabel("Days", fontsize=8)
        ax.set_ylabel("Cumulative AITD incidence", fontsize=8)
        ax.tick_params(labelsize=7)
        ax.grid(alpha=0.2)
        handles, labels = ax.get_legend_handles_labels()
        if handles:
            ax.legend(handles, labels, fontsize=6, loc="upper left")
    fig.suptitle("Threshold performance and cumulative-incidence analysis", fontsize=16, weight="bold")
    save_figure(fig, stem)


def markdown_table(frame: pd.DataFrame, columns: Sequence[str] | None = None, max_rows: int | None = None) -> str:
    view = frame.loc[:, list(columns)] if columns else frame.copy()
    if max_rows is not None:
        view = view.head(max_rows)
    view = view.fillna("")
    headers = [str(c).replace("|", "\\|") for c in view.columns]
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for row in view.itertuples(index=False, name=None):
        values = [str(value).replace("|", "\\|").replace("\n", " ") for value in row]
        lines.append("| " + " | ".join(values) + " |")
    return "\n".join(lines)


def cohort_narrative(flow: pd.DataFrame, qa: pd.DataFrame) -> str:
    qa_map = dict(zip(qa["item"].astype(str), qa["value"].astype(int)))
    initial = int(flow.sort_values("stage_order").iloc[0]["n"])
    final = int(flow.sort_values("stage_order").iloc[-1]["n"])
    positive = int(qa_map.get("aitd_positive", 0))
    negative = final - positive
    return (
        f"A total of {initial:,} patients had an amiodarone record. After applying the "
        f"prespecified eligibility and exclusion criteria, {final:,} patients remained: "
        f"{positive:,} with AITD and {negative:,} without AITD."
    )


def render_markdown(template_path: Path, output_path: Path, replacements: dict[str, str]) -> None:
    template = template_path.read_text(encoding="utf-8")
    for key, value in replacements.items():
        template = template.replace("{{" + key + "}}", value)
    unresolved = sorted(set(re.findall(r"\{\{([A-Z0-9_]+)\}\}", template)))
    if unresolved:
        raise ValueError(f"Unresolved report template tokens: {unresolved}")
    output_path.write_text(template, encoding="utf-8")


def render_html(output_path: Path, title: str, sections: Sequence[tuple[str, str]], figures_dir: Path) -> None:
    css = """
    @page { size: A4 landscape; margin: 16mm; }
    body { font-family: Arial, sans-serif; color: #222; max-width: 1200px; margin: auto; line-height: 1.4; }
    h1 { color: #173f5f; border-bottom: 3px solid #2d9cdb; padding-bottom: 10px; }
    h2 { color: #173f5f; margin-top: 34px; page-break-after: avoid; }
    h3, p { page-break-after: avoid; }
    table { border-collapse: collapse; width: 100%; font-size: 9px; margin: 10px 0 28px; }
    th { background: #dceef8; }
    th, td { border: 1px solid #999; padding: 4px 6px; vertical-align: top; }
    tr { page-break-inside: avoid; }
    img { max-width: 100%; max-height: 175mm; display: block; margin: 12px auto 6px; }
    .caption { font-size: 10px; margin-bottom: 24px; }
    .note { background: #f6f8fa; border-left: 4px solid #2d9cdb; padding: 10px; }
    """
    body = [f"<h1>{html.escape(title)}</h1>"]
    for heading, content in sections:
        body.append(f"<h2>{html.escape(heading)}</h2>{content}")
    document = f"<!doctype html><html><head><meta charset='utf-8'><title>{html.escape(title)}</title><style>{css}</style></head><body>{''.join(body)}</body></html>"
    output_path.write_text(document, encoding="utf-8")


def html_table(frame: pd.DataFrame, columns: Sequence[str] | None = None) -> str:
    view = frame.loc[:, list(columns)] if columns else frame
    return view.fillna("").to_html(index=False, border=0, escape=True)


def build_pdf(
    output_path: Path,
    tables: dict[str, pd.DataFrame],
    figures: dict[str, Path],
    narrative: str,
    generated_at: str,
) -> None:
    try:
        from reportlab.lib import colors
        from reportlab.lib.enums import TA_CENTER
        from reportlab.lib.pagesizes import A4, landscape
        from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
        from reportlab.lib.units import cm
        from reportlab.platypus import (
            Image, KeepTogether, LongTable, PageBreak, Paragraph,
            SimpleDocTemplate, Spacer, TableStyle,
        )
        from reportlab.lib.utils import ImageReader
    except ImportError as exc:
        raise RuntimeError("reportlab is required to create the PDF report") from exc

    page_size = landscape(A4)
    doc = SimpleDocTemplate(
        str(output_path), pagesize=page_size,
        leftMargin=1.2 * cm, rightMargin=1.2 * cm,
        topMargin=1.3 * cm, bottomMargin=1.4 * cm,
        title="Gil Medical Center AITD External Validation Report",
        author="Gil Medical Center external validation team",
    )
    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle(name="ReportTitle", parent=styles["Title"], fontSize=20, leading=24, textColor=colors.HexColor("#173f5f"), alignment=TA_CENTER, spaceAfter=18))
    styles.add(ParagraphStyle(name="Caption", parent=styles["BodyText"], fontSize=8.5, leading=11, spaceAfter=10))
    styles.add(ParagraphStyle(name="Small", parent=styles["BodyText"], fontSize=7, leading=9))

    def footer(canvas, document):
        canvas.saveState()
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(colors.HexColor("#666666"))
        canvas.drawString(1.2 * cm, 0.65 * cm, "Gil Medical Center AITD external validation")
        canvas.drawRightString(page_size[0] - 1.2 * cm, 0.65 * cm, f"Page {document.page}")
        canvas.restoreState()

    def paragraph(value: object, style="Small"):
        return Paragraph(html.escape("" if pd.isna(value) else str(value)), styles[style])

    def add_table(story: list, caption: str, frame: pd.DataFrame, widths: Sequence[float] | None = None, font_size: float = 6.2):
        story.append(Paragraph(caption, styles["Heading3"]))
        data = [[paragraph(col) for col in frame.columns]]
        data.extend([[paragraph(value) for value in row] for row in frame.fillna("").itertuples(index=False, name=None)])
        table = LongTable(data, repeatRows=1, colWidths=widths, hAlign="LEFT")
        table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#dceef8")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#173f5f")),
            ("GRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#8a8a8a")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("FONTSIZE", (0, 0), (-1, -1), font_size),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f7f9fa")]),
            ("LEFTPADDING", (0, 0), (-1, -1), 3),
            ("RIGHTPADDING", (0, 0), (-1, -1), 3),
            ("TOPPADDING", (0, 0), (-1, -1), 3),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ]))
        story.extend([table, Spacer(1, 10)])

    def add_figure(story: list, caption: str, image_path: Path):
        reader = ImageReader(str(image_path))
        width, height = reader.getSize()
        max_width, max_height = 25.2 * cm, 15.8 * cm
        scale = min(max_width / width, max_height / height)
        story.extend([Image(str(image_path), width=width * scale, height=height * scale), Paragraph(caption, styles["Caption"]), Spacer(1, 6)])

    story = [
        Paragraph("External Validation of an Explainable Machine Learning Model for Amiodarone-Induced Thyroid Dysfunction", styles["ReportTitle"]),
        Paragraph("Validation cohort: Gil Medical Center, Korea", styles["Heading2"]),
        Paragraph(f"Generated: {generated_at}", styles["BodyText"]),
        Paragraph(narrative, styles["BodyText"]),
        Spacer(1, 8),
        Paragraph("Leakage-safe analysis design", styles["Heading2"]),
        Paragraph(
            "Laboratory data were restricted to the last complete observation window before the AITD event interval or loss to follow-up. "
            "The m22_24 interval was outcome-only. Missing-value imputation and scaling were fitted within training folds. "
            "AdaBoost and XGBoost recursive elimination removed one least-important feature per step under stratified 5-fold accuracy, "
            "and their selected-feature intersection was used downstream. Hyperparameters and probability thresholds were selected "
            "from development data only; the hold-out test set was evaluated after all selection was complete.",
            styles["BodyText"],
        ),
        Spacer(1, 12),
    ]
    add_figure(story, "Figure 1. Participant selection flowchart. Sequential exclusion counts are mutually exclusive by construction.", figures["Figure 1"])
    story.append(PageBreak())
    story.append(Paragraph("Baseline characteristics and missingness", styles["Heading1"]))
    table1_view = tables["Table 1"].loc[:, ["Section", "Characteristic", "Statistic", "Total", "AITD", "Non-AITD"]]
    add_table(
        story, "Table 1. Patient characteristics before imputation.", table1_view,
        widths=[3.5 * cm, 6.2 * cm, 2.3 * cm, 4.3 * cm, 4.3 * cm, 4.3 * cm], font_size=5.8,
    )
    story.append(PageBreak())
    add_table(
        story, "Table 2. Missing rate of candidate features before imputation.", tables["Table 2"],
        widths=[12.5 * cm, 5.0 * cm, 6.0 * cm], font_size=6.4,
    )
    story.append(PageBreak())
    story.append(Paragraph("Model construction and evaluation", styles["Heading1"]))
    add_figure(story, "Figure 2. Recursive one-feature-at-a-time elimination using stratified 5-fold accuracy.", figures["Figure 2"])
    add_table(
        story, "Table 3. AdaBoost and XGBoost selected features and their final intersection.", tables["Table 3"],
        widths=[3.0 * cm, 3.7 * cm, 2.7 * cm, 1.5 * cm, 13.5 * cm], font_size=6.0,
    )
    story.append(PageBreak())
    add_table(
        story, "Table 4. Development-set 5-fold validation performance.", tables["Table 4"],
        widths=[2.7 * cm, 2.4 * cm, 2.3 * cm, *([2.2 * cm] * 7)], font_size=5.6,
    )
    story.append(PageBreak())
    add_table(
        story, "Table 5. Final hold-out test performance.", tables["Table 5"],
        widths=[3.0 * cm, 2.5 * cm, *([2.4 * cm] * 7)], font_size=6.2,
    )
    add_figure(story, "Figure 3. Hold-out model performance by resampling strategy.", figures["Figure 3"])
    story.append(PageBreak())
    story.append(Paragraph("Explainability and risk thresholds", styles["Heading1"]))
    add_figure(story, "Figure 4. Held-out SHAP global importance and distributions for XGBoost plus Borderline-SMOTE.", figures["Figure 4"])
    story.append(PageBreak())
    add_figure(story, "Figure 5. Held-out precision-recall and cumulative-incidence curves using frozen development-OOF thresholds.", figures["Figure 5"])
    add_table(
        story, "Table 6. Hold-out performance across frozen thresholds.", tables["Table 6"],
        widths=[3.2 * cm, 3.1 * cm, *([1.55 * cm] * (len(tables["Table 6"].columns) - 2))], font_size=5.5,
    )
    story.append(Paragraph("Patient-level data, predictions, SHAP matrices, and survival metadata must remain inside the approved closed network.", styles["BodyText"]))
    doc.build(story, onFirstPage=footer, onLaterPages=footer)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, default=Path.cwd(), help="Directory containing SQL and notebook CSV outputs")
    parser.add_argument("--output-dir", type=Path, default=None, help="Default: INPUT_DIR/report_outputs")
    parser.add_argument("--template", type=Path, default=Path(__file__).with_name("REPORT_TEMPLATE.md"))
    args = parser.parse_args()
    input_dir = args.input_dir.resolve()
    output_dir = (args.output_dir or input_dir / "report_outputs").resolve()
    tables_dir = output_dir / "tables"
    figures_dir = output_dir / "figures"
    tables_dir.mkdir(parents=True, exist_ok=True)
    figures_dir.mkdir(parents=True, exist_ok=True)

    sns.set_theme(style="whitegrid", context="notebook")
    flow = read_csv(input_dir / "cohort_flow_summary.csv", ["stage_order", "stage", "n"])
    qa = read_csv(input_dir / "replication_qa_summary.csv", ["item", "value"])
    features = read_csv(input_dir / "report_features_before_imputation.csv", ["person_id", TARGET])
    table1, omitted = table1_characteristics(features)
    table2 = round_numeric(table2_missingness(features), 2)
    table3, selection_manifest = table3_selection(input_dir)
    table3 = round_numeric(table3, 4)
    table4 = round_numeric(read_csv(input_dir / "development_5fold_cv_performance.csv", ["Model", "Sampler", "METRIC", "MEAN", "STD"]), 4)
    table5 = round_numeric(read_csv(input_dir / "final_holdout_performance.csv", ["Model", "Sampler", "Accuracy", "AUROC", "AUPRC"]), 4)
    thresholds = read_csv(input_dir / "thresholds_selected_from_development_oof.csv", ["name", "threshold"])
    predictions = read_csv(input_dir / "heldout_predictions_xgboost_bsmote.csv", ["person_id", "y_true", "y_probability", "followup_time_days"])
    table6, km_summary = threshold_metrics(predictions, thresholds)
    table6 = round_numeric(table6, 4)
    km_summary = round_numeric(km_summary, 6)

    tables = {
        "Table 1": table1,
        "Table 2": table2,
        "Table 3": table3,
        "Table 4": table4,
        "Table 5": table5,
        "Table 6": table6,
    }
    filenames = {
        "Table 1": "table1_patient_characteristics.csv",
        "Table 2": "table2_missing_rates.csv",
        "Table 3": "table3_selected_features.csv",
        "Table 4": "table4_development_5fold_performance.csv",
        "Table 5": "table5_final_holdout_performance.csv",
        "Table 6": "table6_threshold_performance.csv",
    }
    for name, frame in tables.items():
        write_csv(frame, tables_dir / filenames[name])
    write_csv(selection_manifest, tables_dir / "table3_selected_features_long.csv")
    write_csv(km_summary, tables_dir / "figure5_km_logrank_summary.csv")

    figure1_cohort(flow, qa, figures_dir / "figure1_cohort_flow")
    figure2_recursive(input_dir, figures_dir / "figure2_recursive_feature_elimination")
    figure3_performance(table5, figures_dir / "figure3_model_performance")
    figure4_shap(input_dir, figures_dir / "figure4_shap_summary")
    figure5_threshold_km(predictions, thresholds, figures_dir / "figure5_threshold_km")

    narrative = cohort_narrative(flow, qa)
    generated_at = datetime.now().astimezone().isoformat(timespec="seconds")
    notes = (
        f"Generated from {input_dir}. Table 1 and Table 2 use observed values before MICE, "
        "scaling, binary/remark filling, and slope filling. RFECV uses accuracy; downstream "
        "RandomizedSearchCV uses development-set macro-F1. Thresholds are frozen from "
        "development out-of-fold predictions."
    )
    replacements = {
        "GENERATED_AT": generated_at,
        "COHORT_NARRATIVE": narrative,
        "TABLE1": markdown_table(table1, ["Section", "Characteristic", "Statistic", "Total", "AITD", "Non-AITD"]),
        "TABLE2": markdown_table(table2),
        "TABLE3": markdown_table(table3),
        "TABLE4": markdown_table(table4),
        "TABLE5": markdown_table(table5),
        "TABLE6": markdown_table(table6),
        "REPRODUCIBILITY_NOTES": notes,
    }
    report_md = output_dir / "external_validation_report.md"
    render_markdown(args.template.resolve(), report_md, replacements)

    figure_tags = {
        number: f"<img src='figures/{path.name}' alt='{number}'><p class='caption'>{caption}</p>"
        for number, path, caption in [
            ("Figure 1", figures_dir / "figure1_cohort_flow.png", "Figure 1. Participant selection flowchart."),
            ("Figure 2", figures_dir / "figure2_recursive_feature_elimination.png", "Figure 2. Recursive elimination accuracy."),
            ("Figure 3", figures_dir / "figure3_model_performance.png", "Figure 3. Hold-out performance by strategy."),
            ("Figure 4", figures_dir / "figure4_shap_summary.png", "Figure 4. SHAP global explanation."),
            ("Figure 5", figures_dir / "figure5_threshold_km.png", "Figure 5. Frozen thresholds and cumulative incidence."),
        ]
    }
    html_sections = [
        ("1. Patient cohort", f"<p>{html.escape(narrative)}</p>{figure_tags['Figure 1']}"),
        ("2. Baseline characteristics and missingness", "<h3>Table 1. Patient characteristics before imputation</h3>" + html_table(table1) + "<h3>Table 2. Missing rates before imputation</h3>" + html_table(table2)),
        ("3. Model construction and evaluation", figure_tags["Figure 2"] + "<h3>Table 3. Selected features and final intersection</h3>" + html_table(table3) + "<h3>Table 4. Development 5-fold performance</h3>" + html_table(table4) + "<h3>Table 5. Final hold-out performance</h3>" + html_table(table5) + figure_tags["Figure 3"]),
        ("4. Explainability and thresholds", figure_tags["Figure 4"] + figure_tags["Figure 5"] + "<h3>Table 6. Frozen threshold performance</h3>" + html_table(table6)),
        ("5. Reproducibility and disclosure", f"<p class='note'>{html.escape(notes)} Patient-level files must remain in the approved closed network.</p>"),
    ]
    render_html(output_dir / "external_validation_report.html", "Gil Medical Center AITD External Validation", html_sections, figures_dir)

    figure_paths = {
        "Figure 1": figures_dir / "figure1_cohort_flow.png",
        "Figure 2": figures_dir / "figure2_recursive_feature_elimination.png",
        "Figure 3": figures_dir / "figure3_model_performance.png",
        "Figure 4": figures_dir / "figure4_shap_summary.png",
        "Figure 5": figures_dir / "figure5_threshold_km.png",
    }
    build_pdf(output_dir / "external_validation_report.pdf", tables, figure_paths, narrative, generated_at)

    manifest = {
        "generated_at": generated_at,
        "input_dir": str(input_dir),
        "output_dir": str(output_dir),
        "n_patients": int(len(features)),
        "n_aitd": int(pd.to_numeric(features[TARGET]).sum()),
        "table1_omitted_columns_not_in_dataset": omitted,
        "patient_level_inputs_must_not_be_exported": [
            "dataset.csv", "report_features_before_imputation.csv",
            "data_split_manifest.csv", "heldout_predictions_xgboost_bsmote.csv",
            "shap_values_heldout.csv", "shap_feature_values_heldout.csv",
            "survival_metadata.csv",
        ],
    }
    (output_dir / "report_generation_manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    shutil.copy2(args.template.resolve(), output_dir / "REPORT_TEMPLATE_USED.md")
    print(f"Report outputs created in: {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
