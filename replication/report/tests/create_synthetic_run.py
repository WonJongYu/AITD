#!/usr/bin/env python3
"""Create non-clinical synthetic CSVs for smoke-testing generate_report.py."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd


def save(frame: pd.DataFrame, path: Path) -> None:
    frame.to_csv(path, index=False, encoding="utf-8-sig")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(42)

    n = 160
    person_id = np.arange(100001, 100001 + n)
    outcome = np.zeros(n, dtype=int)
    outcome[rng.choice(n, size=32, replace=False)] = 1
    features = pd.DataFrame({
        "person_id": person_id,
        "aitd_flag": outcome,
        "male_flag": rng.binomial(1, 0.62, n),
        "age_at_index": np.clip(rng.normal(66, 11, n), 20, 95),
        "height_cm": rng.normal(165, 9, n),
        "weight_kg": rng.normal(66, 12, n),
        "bmi": rng.normal(24.5, 3.2, n),
        "charlson_index": rng.poisson(1.5, n),
        "current_smoker_flag": rng.binomial(1, 0.13, n).astype(float),
        "current_drinker_flag": rng.binomial(1, 0.16, n).astype(float),
        "cumulative_dose_g": rng.lognormal(3.4, 0.7, n),
        "duration_span_days": rng.gamma(2.0, 100, n),
        "sum_days": rng.gamma(2.2, 80, n),
        "pdd_g_per_day": rng.normal(0.20, 0.04, n),
        "aver_dose_g_per_kg": rng.lognormal(-0.4, 0.6, n),
        "tsh_value": rng.lognormal(0.8 + outcome * 0.25, 0.5, n),
        "ft4_value": rng.normal(1.3 - outcome * 0.05, 0.18, n),
        "rbc_value": rng.normal(4.2, 0.6, n),
        "hgb_value": rng.normal(12.8, 1.7, n),
        "hct_value": rng.normal(39, 5, n),
        "mcv_value": rng.normal(91, 6, n),
        "mch_value": rng.normal(30.5, 2.4, n),
        "mchc_value": rng.normal(33.5, 1.4, n),
        "tg_value": rng.lognormal(4.7, 0.45, n),
        "ast_value": rng.lognormal(3.2, 0.35, n),
        "alt_value": rng.lognormal(3.1, 0.45, n),
        "hdl_value": rng.normal(47, 12, n),
        "ldl_value": rng.normal(88, 26, n),
        "scr_value": rng.lognormal(0.0, 0.35, n),
        "alkp_value": rng.lognormal(4.3, 0.3, n),
        "cholesterol_value": rng.normal(165, 35, n),
        "ast_slope": rng.normal(0, 4, n),
        "alt_slope": rng.normal(0, 5, n),
        "scr_slope": rng.normal(0, 0.12, n),
        "cholesterol_slope": rng.normal(0, 8, n),
    })
    for col, p in {
        "rx_tkis_flag": 0.02, "rx_allopurinol_flag": 0.03,
        "rx_antipsychotic_flag": 0.04, "rx_nsaid_flag": 0.26,
        "rx_antidms_flag": 0.18, "rx_metformin_flag": 0.11,
        "rx_propafenone_flag": 0.06, "dx_bradycardia_flag": 0.05,
        "dx_goiter_flag": 0.03, "dx_anemia_flag": 0.18,
        "dx_hypertension_flag": 0.66, "dx_diabetes_flag": 0.34,
        "dx_dm_nephropathy_flag": 0.08, "dx_dm_complications_flag": 0.09,
        "dx_gouts_flag": 0.04, "dx_chronic_rf_flag": 0.45,
        "dx_renal_dysfunction_flag": 0.62, "dx_ra_flag": 0.03,
    }.items():
        features[col] = rng.binomial(1, p, n)
    for col, rate in {
        "height_cm": 0.35, "weight_kg": 0.35, "bmi": 0.34,
        "current_smoker_flag": 0.20, "current_drinker_flag": 0.21,
        "tsh_value": 0.15, "ft4_value": 0.17, "ldl_value": 0.20,
        "mcv_value": 0.08, "mch_value": 0.08, "mchc_value": 0.08,
    }.items():
        features.loc[rng.random(n) < rate, col] = np.nan
    save(features, out / "report_features_before_imputation.csv")

    flow_counts = [210, 190, 181, 176, 171, 169, 166, 160]
    stages = [
        "patients with any amiodarone record",
        "first amiodarone in study period with 365d prior observation",
        "after abnormal TSH exclusion", "after thyroid medication exclusion",
        "after thyroid disease exclusion", "after pregnancy exclusion",
        "after age criterion", "after thyroidectomy exclusion / final cohort",
    ]
    save(pd.DataFrame({"stage_order": range(1, 9), "stage": stages, "n": flow_counts}), out / "cohort_flow_summary.csv")
    save(pd.DataFrame({
        "item_order": range(1, 10),
        "item": ["final_cohort_rows", "aitd_positive", "aitd_negative", "early_censored_negative", "index_day_aitd", "feature_dataset_rows", "patients_with_numeric_mcv", "patients_with_numeric_mch", "patients_with_numeric_mchc"],
        "value": [160, 32, 128, 12, 0, 160, 145, 145, 145],
    }), out / "replication_qa_summary.csv")

    candidate_features = ["age_at_index", "male_flag", "bmi", "charlson_index", "duration_span_days", "tsh_value", "ft4_value", "mcv_value", "mch_value", "mchc_value", "scr_value", "cholesterol_value"]
    for model, optimum in [("adaboost", 6), ("xgboost", 8)]:
        rows = []
        for count in range(len(candidate_features), 0, -1):
            score = 0.82 + 0.025 * np.exp(-((count - optimum) ** 2) / 12) + rng.normal(0, 0.001)
            rows.append({"n_features": count, "mean_cv_accuracy": score, "std_cv_accuracy": 0.012 + count / 3000, "removed_feature": candidate_features[count - 1] if count > 1 else "", "features": "|".join(candidate_features[:count])})
        save(pd.DataFrame(rows), out / f"recursive_accuracy_history_{model}.csv")

    selected = {
        "AdaBoost": {"age_at_index", "bmi", "duration_span_days", "tsh_value", "scr_value", "cholesterol_value"},
        "XGBoost": {"age_at_index", "bmi", "charlson_index", "duration_span_days", "tsh_value", "ft4_value", "scr_value", "cholesterol_value"},
    }
    manifest_rows = []
    for model in ["AdaBoost", "XGBoost"]:
        for rank, feature in enumerate(candidate_features, start=1):
            manifest_rows.append({"selector_model": model, "scoring": "accuracy", "best_cv_score": 0.845 if model == "AdaBoost" else 0.852, "feature": feature, "selected": feature in selected[model], "ranking": 1 if feature in selected[model] else rank + 1})
    save(pd.DataFrame(manifest_rows), out / "rfecv_feature_selection_all_models.csv")
    intersection = [f for f in candidate_features if f in selected["AdaBoost"] & selected["XGBoost"]]
    save(pd.DataFrame({"feature": intersection}), out / "recursive_selected_feature_intersection.csv")

    cv_rows = []
    holdout_rows = []
    for mi, model in enumerate(["XGBoost", "AdaBoost", "KNN", "Logistic Regression"]):
        for si, sampler in enumerate(["none", "b-smote", "enn", "b-smote-enn"]):
            base = 0.90 - mi * 0.035 - si * 0.006
            for metric, offset in [("ACCURACY", 0.02), ("PRECISION", -0.11), ("RECALL", -0.27 + si * 0.025), ("F1", -0.18), ("ROC_AUC", 0.0)]:
                folds = np.clip(base + offset + rng.normal(0, 0.012, 5), 0.05, 0.99)
                row = {"Model": model, "Sampler": sampler, "METRIC": metric}
                row.update({f"FOLD {i + 1}": folds[i] for i in range(5)})
                row.update({"MEAN": folds.mean(), "STD": folds.std()})
                cv_rows.append(row)
            holdout_rows.append({
                "Model": model, "Sampler": sampler,
                "F1": np.clip(base - 0.16 + rng.normal(0, 0.01), 0, 1),
                "Recall": np.clip(base - 0.24 + si * 0.03 + rng.normal(0, 0.01), 0, 1),
                "Precision": np.clip(base - 0.10 - si * 0.025 + rng.normal(0, 0.01), 0, 1),
                "G-mean": np.clip(base - 0.10 + rng.normal(0, 0.01), 0, 1),
                "Accuracy": np.clip(base + 0.025 + rng.normal(0, 0.006), 0, 1),
                "AUROC": np.clip(base + rng.normal(0, 0.008), 0, 1),
                "AUPRC": np.clip(base - 0.13 + rng.normal(0, 0.008), 0, 1),
            })
    save(pd.DataFrame(cv_rows), out / "development_5fold_cv_performance.csv")
    save(pd.DataFrame(holdout_rows), out / "final_holdout_performance.csv")

    n_test = 40
    test_ids = person_id[:n_test]
    y_test = outcome[:n_test]
    probability = np.clip(rng.beta(1.2 + y_test * 3.5, 5.5, n_test), 0.001, 0.999)
    followup = rng.integers(60, 731, n_test)
    save(pd.DataFrame({"person_id": test_ids, "y_true": y_test, "y_probability": probability, "followup_time_days": followup}), out / "heldout_predictions_xgboost_bsmote.csv")
    threshold_names = ["A (Top 1%)", "B (Top 5%)", "C (Optimal F1)", "D (Top 15%)", "E (Top 25%)"]
    threshold_values = [0.88, 0.70, 0.48, 0.32, 0.20]
    save(pd.DataFrame({"name": threshold_names, "threshold": threshold_values}), out / "thresholds_selected_from_development_oof.csv")

    shap_features = intersection
    shap_values = rng.normal(0, 0.3, (n_test, len(shap_features)))
    shap_values[:, shap_features.index("tsh_value")] += (probability - probability.mean()) * 2.5
    feature_values = features.set_index("person_id").loc[test_ids, shap_features].fillna(0).reset_index()
    shap_df = pd.DataFrame(shap_values, columns=shap_features)
    shap_df.insert(0, "person_id", test_ids)
    importance = pd.DataFrame({"feature": shap_features, "mean_abs_shap": np.abs(shap_values).mean(axis=0)}).sort_values("mean_abs_shap", ascending=False)
    save(shap_df, out / "shap_values_heldout.csv")
    save(feature_values, out / "shap_feature_values_heldout.csv")
    save(importance, out / "shap_importance.csv")
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
