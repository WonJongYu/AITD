# Table/Figure and report generation

`generate_report.py` creates all six tables and five figures from the SQL and
modeling outputs. It does not refit any model.

## Required order

1. Run `run_all_replication_postgresql.sql` on the DB computer.
2. Transfer the approved SQL CSV outputs to the Python computer.
3. Run `preprocessing&model.ipynb` from top to bottom.
4. In the same run directory, execute the report generator.

```bash
python /approved/path/replication/report/generate_report.py \
  --input-dir /approved/path/replication_python_run_YYYYMMDD
```

The default output directory is `INPUT_DIR/report_outputs`.

The generator has been smoke-tested with the non-clinical synthetic input
builder in `tests/create_synthetic_run.py`. Synthetic outputs are for software
validation only and must never be reported as study results.

## Required inputs

SQL runner outputs:

- `dataset.csv`
- `cohort_flow_summary.csv`
- `replication_qa_summary.csv`

Notebook outputs:

- `report_features_before_imputation.csv`
- `recursive_accuracy_history_adaboost.csv`
- `recursive_accuracy_history_xgboost.csv`
- `rfecv_feature_selection_all_models.csv`
- `recursive_selected_feature_intersection.csv`
- `development_5fold_cv_performance.csv`
- `final_holdout_performance.csv`
- `thresholds_selected_from_development_oof.csv`
- `heldout_predictions_xgboost_bsmote.csv`
- `shap_importance.csv`
- `shap_values_heldout.csv`
- `shap_feature_values_heldout.csv`

## Outputs

```text
report_outputs/
├── tables/
│   ├── table1_patient_characteristics.csv
│   ├── table2_missing_rates.csv
│   ├── table3_selected_features.csv
│   ├── table3_selected_features_long.csv
│   ├── table4_development_5fold_performance.csv
│   ├── table5_final_holdout_performance.csv
│   ├── table6_threshold_performance.csv
│   └── figure5_km_logrank_summary.csv
├── figures/
│   ├── figure1_cohort_flow.png/.pdf
│   ├── figure2_recursive_feature_elimination.png/.pdf
│   ├── figure3_model_performance.png/.pdf
│   ├── figure4_shap_summary.png/.pdf
│   └── figure5_threshold_km.png/.pdf
├── external_validation_report.md
├── external_validation_report.html
├── external_validation_report.pdf
└── report_generation_manifest.json
```

Table 1 and Table 2 use `report_features_before_imputation.csv`, which is saved
before MICE, scaling, binary/remark missing-value filling, and slope filling.
The generated report labels the final feature set as the AdaBoost-XGBoost
intersection and labels threshold D as `Top 15%`, not `Default`.

Patient-level inputs, held-out predictions, SHAP matrices, and survival metadata
must remain in the approved closed network. Review aggregate outputs under the
hospital's minimum-cell-size and disclosure rules before external transfer.
