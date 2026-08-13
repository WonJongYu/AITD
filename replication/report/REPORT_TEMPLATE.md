# External Validation of an Explainable Machine Learning Model for Amiodarone-Induced Thyroid Dysfunction

**Validation cohort:** Gil Medical Center, Korea  
**Generated:** {{GENERATED_AT}}  
**Analysis:** Independent replication using the current leakage-safe cohort, labeling, feature extraction, and modeling pipeline

## 1. Patient cohort

{{COHORT_NARRATIVE}}

![Figure 1. Flowchart of the participant selection process.](figures/figure1_cohort_flow.png)

**Figure 1.** Flowchart of the participant selection process for the Gil Medical Center external validation cohort. Counts are generated from `cohort_flow_summary.csv`; exclusion counts are sequential and therefore mutually exclusive by construction.

## 2. Data collection and preprocessing

- Demographics were assessed at the amiodarone index date.
- Historical medication and disease features follow the SQL-defined look-back and dynamic collection rules.
- Laboratory measurements were collected through the last complete observation window preceding the AITD event window or loss to follow-up.
- The `m22_24` interval is outcome-only; the last possible feature interval is `m19_21`.
- Missing-value imputation and RobustScaler fitting were performed within each training fold.
- The hold-out test set was not used for feature selection, hyperparameter tuning, or threshold selection.

## 3. Baseline characteristics and missingness

**Table 1. Patient characteristics before imputation.** Continuous variables are median (IQR); binary variables are n (%). Percentages use the full group size as denominator.

{{TABLE1}}

**Table 2. Missing rate of candidate model features before imputation.**

{{TABLE2}}

## 4. Model construction and evaluation

AdaBoost and XGBoost recursive feature elimination started with every feature remaining after preprocessing. At every step, feature importance was recalculated under stratified 5-fold validation and exactly one least-important feature was removed. The best feature set for each model was selected by mean validation accuracy. Their intersection was used for downstream modeling.

![Figure 2. Recursive feature elimination performance.](figures/figure2_recursive_feature_elimination.png)

**Figure 2.** Changes in stratified 5-fold accuracy as one feature at a time was removed for AdaBoost and XGBoost.

**Table 3. Features selected by AdaBoost and XGBoost and their final intersection.**

{{TABLE3}}

Four classifiers - K-nearest neighbors, logistic regression, XGBoost, and AdaBoost - were assessed with no resampling, Borderline-SMOTE, ENN, and Borderline-SMOTE plus ENN. Hyperparameters were selected within the development set using stratified 5-fold RandomizedSearchCV and macro-F1.

**Table 4. Development-set 5-fold validation performance for the 16 model-resampling combinations.**

{{TABLE4}}

**Table 5. Final hold-out test performance after completion of feature selection and hyperparameter tuning.**

{{TABLE5}}

![Figure 3. Hold-out model performance by resampling strategy.](figures/figure3_model_performance.png)

**Figure 3.** Hold-out AUPRC, F1, G-mean, and recall by model and resampling strategy.

## 5. Explainability and risk thresholds

![Figure 4. SHAP importance and distribution.](figures/figure4_shap_summary.png)

**Figure 4.** SHAP global importance and held-out SHAP value distributions for the tuned XGBoost plus Borderline-SMOTE model using the final intersection feature set.

Thresholds were selected exclusively from development-set out-of-fold predictions and then frozen. Their performance and cumulative AITD incidence were evaluated once in the hold-out test set.

![Figure 5. Frozen threshold and cumulative-incidence analysis.](figures/figure5_threshold_km.png)

**Figure 5.** Held-out precision-recall curve and cumulative-incidence curves for risk groups defined by frozen development-set thresholds.

**Table 6. Predictive performance across frozen probability thresholds in the hold-out test set.**

{{TABLE6}}

## 6. Reproducibility notes

{{REPRODUCIBILITY_NOTES}}

Patient-level input, split manifests, predictions, SHAP matrices, and survival metadata must remain inside the approved closed-network analysis environment. Only disclosure-reviewed aggregate tables and figures may be transferred externally.
