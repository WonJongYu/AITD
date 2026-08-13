# Lu et al. (2023) AITD prediction study — Gil Medical Center reproduction handoff

> **Purpose of this file**  
> This is a self-contained project handoff for a new GPT/chat or collaborator who needs to immediately understand the Lu et al. (2023) paper, its Multimedia Appendices 1–10, and the unresolved implementation questions discussed during reproduction planning. It is intended to support **cohort extraction, SQL design, feature engineering, and ML modeling** on Korean Gil Medical Center data.
>
> **Important instruction to the next GPT:** Distinguish **(A) facts explicitly stated in the paper/appendices**, **(B) reasonable inferences**, and **(C) unresolved questions that must be confirmed with the original authors**. Do not silently resolve the ambiguities listed below.

---

## 1. Project context

- Original paper: **Lu YT, Chao HJ, Chiang YC, Chen HY. “Explainable Machine Learning Techniques To Predict Amiodarone-Induced Thyroid Dysfunction Risk: Multicenter, Retrospective Study With External Validation.” Journal of Medical Internet Research. 2023;25:e43734. DOI: 10.2196/43734.**
- The original author team has approached our laboratory to reproduce/transport the study using **Korean Gil Medical Center data**.
- Current work includes:
  - cohort extraction / SQL,
  - longitudinal feature construction,
  - model-input table construction,
  - preprocessing,
  - resampling,
  - feature selection,
  - hyperparameter tuning,
  - model evaluation / external validation.
- The most important unresolved issue is **what exactly constituted one ML observation (one patient vs one patient-timepoint snapshot)** in the original implementation.

### Uploaded source files used for this handoff

1. Main paper PDF: `Lu et al. - 2023 - Explainable Machine Learning Techniques To Predict Amiodarone-Induced Thyroid Dysfunction Risk Mult.pdf`
2. Multimedia Appendix 1: preexisting thyroid conditions / exclusion definitions
3. Multimedia Appendix 2: eligible data collection period and time-series collection diagram
4. Multimedia Appendix 3: feature codebook and missingness
5. Multimedia Appendix 4: grid-search spaces and final hyperparameters
6. Multimedia Appendix 5: pseudocode for grid search, RFECV, and 5-fold CV
7. Multimedia Appendix 6: metric formulas and confusion matrix
8. Multimedia Appendix 7: STROBE patient-selection flowchart
9. Multimedia Appendix 8: RFECV feature selection
10. Multimedia Appendix 9: training-set 5-fold CV performance of 16 models
11. Multimedia Appendix 10: AUPRC significance / bootstrap comparisons

---

# 2. High-level study design

## 2.1 Research question

Predict **amiodarone-induced thyroid dysfunction (AITD)** among adult oral amiodarone users using explainable ML with longitudinal/dynamic EHR features and class-imbalance handling.

## 2.2 Hospitals and development/test split

**Explicitly stated:**

- Development/training set: patients from **Taipei Medical University Hospital (TMUH)** + **Wan Fang Hospital (WFH)**.
- External test set: patients from **Shuang Ho Hospital (SHH)**.
- Training set: **N = 4,075**, AITD = **583 (14.3%)**.
- External test set: **N = 2,422**, AITD = **275 (~11.4%)**.
- Total = **6,497 patients**.

The hospital-level split means the external test cohort is made of different patients from a different hospital, so ordinary train/test patient overlap is not expected.

## 2.3 Date inconsistency in the paper — DO NOT silently resolve

There is an internal reporting discrepancy:

- Abstract Methods: amiodarone users from **January 2013–December 2017**.
- Main-text Patient Cohort: first oral amiodarone prescription from **January 2005–December 2017**.

**Action:** confirm the actual index-date range with the original authors before finalizing the Gil cohort definition.

---

# 3. Cohort definition

## 3.1 Index date

**Explicitly stated:** index day = **date of the first oral amiodarone prescription**.

## 3.2 Inclusion

- Age **>18 years**.
- First oral amiodarone prescription within the study period.

## 3.3 Follow-up

- Patients were followed for **up to 2 years after index date**.
- Data collection stops when:
  - AITD occurs, or
  - loss to follow-up occurs,
  - otherwise at end of the 2-year study follow-up.

Appendix 2 states that if an event or loss-to-follow-up occurs, feature collection stops at the **previous eligible observation window**.

Example from Appendix 2:

- Patient A: AITD at month 11 → data followed/collected through the **month-9 window**.
- Patient B: no event → followed to end of study.
- Patient C: loss to follow-up at month 14 → data collection stops at **month 12**.

## 3.4 Exclusion: preexisting thyroid-related condition within 1 year before index

The main paper excludes pregnancy and preexisting thyroid disorder / surgery / subclinical thyroid laboratory abnormality within 1 year before index. Appendix 1 provides operational definitions.

### Subclinical thyroid labs

Exclude if pre-index:

- TSH > 10 mU/L, OR
- TSH < 0.1 mU/L.

### Preexisting thyroid disease ICD definitions

- Thyroid carcinoma
  - ICD-9: `193`, `226`
  - ICD-10: `D34`, `E31.22`
- Goiter
  - ICD-9: `240`, `241`
  - ICD-10: `E01`, `E04`
- Thyrotoxicosis
  - ICD-9: `242`
  - ICD-10: `E05.0`, `E05.1`, `E05.2`, `E05.3`, `E05.4`, `E05.8`, `E05.9`
- Thyroiditis
  - ICD-9: `245`
  - ICD-10: `E06`
- Congenital hypothyroidism
  - ICD-9: `243`
  - ICD-10: `E03.0`, `E03.1`
- Hypothyroidism
  - ICD-9: `244`
  - ICD-10: `E02`, `E01.8`, `E03`, `E89.0`
- Other thyroid disorder
  - ICD-9: `246`
  - ICD-10: `E07`
- Thyroidectomy
  - ICD-9 procedure: `06.2`, `06.3`, `06.4`, `06.5`, `06.6`, `06.98`

### Thyroid-related medication exclusion

- Levothyroxine: ATC `H03AA02`
- Propylthiouracil: `H03BA02`
- Carbimazole: `H03BB01`
- Methimazole: `H03BB02`

### Korean implementation note

Gil data may use KCD/local diagnosis codes and local drug identifiers rather than native ICD/ATC. Build a **mapping layer** rather than hard-coding source-system codes into modeling logic.

---

# 4. AITD outcome definition

**Explicitly stated:** target is binary `0 = non-AITD`, `1 = AITD`.

AITD includes hyperthyroid and hypothyroid manifestations and may be identified by laboratory criteria, diagnosis/procedure codes, or thyroid-specific therapy.

## 4.1 Hyperthyroid / thyrotoxicosis laboratory criterion

- TSH < 0.1 mU/L **and**
- free T4 above the normal range.

## 4.2 Hypothyroid laboratory criterion

Either:

- TSH > 10 mU/L regardless of fT4, OR
- TSH 4–10 mU/L with fT4 lower than the normal range.

## 4.3 Other event evidence

The main paper also identifies AITD using:

- ICD-9: `242`, `243`, `244`
- ICD-10: `E02`, `E03`, `E05`, `E06`
- initiation/receipt of thyroid pharmacotherapy:
  - levothyroxine,
  - propylthiouracil,
  - carbimazole,
  - methimazole,
- thyroidectomy procedure.

The earliest AITD onset is used as the event date.

## 4.4 Important unresolved SQL details for outcome construction

The paper does **not** clearly specify:

1. How close in time TSH and fT4 must be for a paired lab criterion (same date? same visit? same observation window?).
2. Whether the local laboratory-specific reference range or a universal fixed reference range was used for “above/below normal” fT4.
3. How diagnosis-code event dates were prioritized relative to laboratory event dates.
4. Whether a single thyroid-medication order is enough, or whether dispensing/administration/duration criteria are required.
5. Exact operational definition of “loss to follow-up.”

These should be confirmed with the original team before freezing SQL.

---

# 5. Longitudinal data collection / prediction windows

## 5.1 Dynamic collection time points

**Explicitly stated:** dynamic data are collected at:

`baseline, 1, 2, 3, 6, 9, 12, 15, 18, 21 months` after amiodarone initiation.

## 5.2 Stationary vs dynamic features

### Stationary

Collected once at index date:

- sex,
- age,
- BMI.

### Dynamic

Collected repeatedly to reflect changing clinical status:

- laboratory tests,
- comorbidities,
- comedications,
- amiodarone dose-related variables,
- engineered time-series laboratory-change variables.

**Therefore, yes: comorbidities and concomitant medications are conceptually dynamic variables in the original study, not merely baseline variables.**

## 5.3 Observation period vs prediction period

Appendix 2 explicitly distinguishes:

- **observation periods**: used for dynamic feature collection,
- **prediction periods**: used to capture the prediction target.

If event/loss occurs, collection is stopped at the preceding observation window.

## 5.4 Critical unresolved issue: what is one ML row?

This is the central implementation ambiguity.

### What is certain

- Dynamic values were repeatedly collected at multiple time points.
- The model is described as a “time-series” / dynamic prediction model.
- Appendix 2 uses repeated observation/prediction windows.
- The final XGBoost/AdaBoost models operate on an ordinary flat feature vector, not an RNN/sequence tensor.
- The final external prediction distribution is reported for exactly **2,422 subjects**, equal to the number of external test patients.

### What is NOT explicitly stated

The paper does not clearly say whether the final modeling table was:

**Option A — one row per patient**

```text
patient_id | latest/aggregated dynamic features before event/censoring | outcome
```

or

**Option B — multiple rows per patient (landmark/snapshot rows)**

```text
patient_id | landmark_month | dynamic features at that window | future outcome
```

### Current inference from our discussion — UNCONFIRMED

The evidence is arguably more consistent with **one final prediction/feature row per patient**, using dynamic information summarized/updated up to the final eligible observation window, because:

- external predictions are described for 2,422 subjects rather than a much larger number of patient-timepoint observations;
- selected features are flat “latest/current/cumulative/slope” style features rather than separate timepoint columns;
- Appendix 2 labels patients and stops feature collection at a final eligible window.

However, this is **not proven by the paper**.

### Mandatory question to original authors

> For model development, what was the unit of observation in X? Did each patient contribute only one row using the latest eligible observation window before AITD/censoring, or did each patient contribute multiple rows corresponding to repeated prediction time points?

If multiple rows per patient were used, ask:

> Was 5-fold StratifiedKFold performed at patient level so that all time points from a given patient stayed within the same fold?

### Safe implementation strategy now

Do **not** prematurely flatten to the final ML matrix. First build a canonical longitudinal table:

```text
patient_id
index_date
landmark_month
obs_start
obs_end
prediction_start
prediction_end
event_date
censor_date
... dynamic features ...
```

Then create a separate configurable transformation:

```python
make_model_matrix(mode="one_row_per_patient")
make_model_matrix(mode="one_row_per_landmark")
```

This avoids rewriting cohort SQL when the authors clarify the observation unit.

---

# 6. Candidate feature codebook

Appendix 3 contains the codebook. Exact capitalization/naming is inconsistent across appendices; retain a canonical internal mapping.

## 6.1 Demographics / baseline

- `Age`
- `Sex` (`0=Female`, `1=Male`)
- `Height`
- `Weight`
- `BMI`
- `charlson_TOT_GRP` = updated Charlson Comorbidity Index of last diagnosis
- `Alcohol` (`0/1`)
- `Smoking` (`0/1`)

## 6.2 Amiodarone exposure features

- `Cumulative_dose_g` — cumulative effective amiodarone dose, g
- `Aver_dose_kg` — g/kg; formula not sufficiently described
- `Duration` — amiodarone treatment duration, days
- `PDD` — prescribed daily dose, g/day; described as average daily amount actually prescribed
- `Sum days` / `Therapeutic days (TD)` — therapeutic days

**Naming issue:** Appendix 8 calls this feature `Therapeutic days`, while Appendix 3 uses `Sum days`.

## 6.3 Concomitant medication variables

- `rx_TKIs` — tyrosine kinase inhibitors; **ATC code missing in Appendix 3**
- `rx_allopurinol` — `M04AA01`
- `rx_antipsychotic` — `N05A`
- `rx_NSAID` — `M01A`, excluding glucosamine `M01AX05`
- `rx_antiDMs` — antidiabetics including classes coded as `A10BB, A10BD, A10BF, A10BG, A10BH, A10BJ, A10BK, A10BX` (Appendix contains a duplicate A10BK)
- `rx_metformin` — Appendix 3 gives `A10BD07`
- `rx_arrhythmia_type1b` — propafenone `C01BC03`

**Important:** the exact time-window logic for these binary medication flags is not specified (active at window? any prescription within window? ever before prediction point?). Confirm with authors.

## 6.4 Comorbidity variables

- `dx_bradycardia`
  - ICD-9 `427.81`
  - ICD-10 `I49.5`, `R00.1`
- `dx_goiter`
  - ICD-9 `240`, `241`
  - ICD-10 `E01`, `E04`
- `dx_anemia` / `dx_anemias`
  - ICD-9 `280–285`
  - ICD-10 `D50, D51, D52, D53, D55, D57, D58, D59, D60, D61, D63, D64`
- `dx_hypertension`
  - ICD-9 `401–405`
  - ICD-10 listed as `I10, I11, I.12, I13, I14, I15, N26.2` in Appendix 3; **`I.12` is likely a formatting/typing issue and should not be silently corrected without confirming mapping**
- `dx_diabetes`
  - ICD-9 `250`
  - ICD-10 `E08–E14` as listed
- `dx_DMnephropathys`
  - ICD-9 `250.4`
  - ICD-10 `E10.2, E11.2, E13.2`
- `dx_DM_coms` — diabetes with complications
  - ICD-9 `250.4, 250.5, 250.6, 250.7`
  - corresponding E08/E09/E10/E11/E13 complication families listed in Appendix 3
- `dx_gouts`
  - ICD-9 `274`
  - ICD-10 `M10`
- `dx_chronic_RFs` — chronic renal failure
  - ICD-9 `585, 403, 404, V45.1, 996.7`
  - ICD-10 `N18, T82.4, Z49.2, Z99.2`
- `dx_renal_dyss` / renal dysfunction — very broad ICD-9/10 list in Appendix 3
- `dx_RAs`
  - ICD-9 `714.0, 714.1, 714.2, 714.3`
  - ICD-10 `M05, M06`

For exact renal dysfunction SQL, re-open Appendix 3 because the ICD list is long.

## 6.5 Laboratory numeric variables

- `lab_TSH` — μIU/mL
- `lab_FT4` — ng/dL
- `lab_rbc` — 10^6/uL
- `lab_hgb` — g/L
- `lab_hct` — %
- `lab_mcv` — fL
- `lab_mch` — pg
- `lab_mchc` — g/dL
- `lab_tg` — mg/dL
- `lab_AST` — U/L
- `lab_ALT` — U/L
- `lab_HDL` — mg/dL
- `lab_LDL` — mg/dL
- `lab_SCr` — mg/dL
- `lab_ALK_P` — U/L
- `lab_Cholesterol` — mg/dL

### High missingness to expect

In the original data:

- TSH missing: ~57.5% training / 59.2% test
- fT4 missing: ~65.0% training / 71.8% test
- ALP missing: ~84.3% / 89.0%
- HDL missing: ~56.7% / 47.0%
- LDL missing: ~47.8% / 29.3%

Therefore missing-data handling is a major part of the original pipeline.

## 6.6 Lab “remark” variables

For multiple labs, Appendix 3 defines categorical “latest result status” flags:

- `TSH_REMARK`
- `FT4_REMARK`
- `T3_REMARK`
- `SCr_REMARK`
- `RBC_REMARK`
- `HGB_REMARK`
- `HCT_REMARK`
- `TG_REMARK`
- `AST_REMARK`
- `ALT_REMARK`
- `Cholesterol_REMARK`
- `HDL_REMARK`
- `LDL_REMARK`
- `ALK_P_REMARK`

Coding:

- `1` = high (`H`, `D`, `R` in source flags)
- `-1` = low (`L`)
- `0` = normal

## 6.7 Time-series slope features

- `AST_slope`
- `ALT_slope`
- `SCr_slope`
- `Cholesterol_slope`

Appendix definition is conceptually:

```text
annualized slope = change in lab value / interval days × 365
```

The exact pair of measurements used (first-to-latest? previous-to-current? window-to-window?) is not fully specified and should be clarified.

---

# 7. Final selected 19 features

Appendix 8:

- AdaBoost RFECV selected **19 features**, accuracy 0.895.
- XGBoost RFECV selected **46 features**, accuracy 0.914.
- The 19 AdaBoost features were all shared with the XGBoost-selected set.
- Main paper says the **19-feature set** was chosen for subsequent model development for simplicity + accuracy.

### Final 19 features

1. `Cumulative_dose_g`
2. `Duration`
3. `PDD`
4. `AGE`
5. `Therapeutic days` / `Sum days`
6. `BMI`
7. `charlson_TOT_GRP`
8. `lab_TSH`
9. `lab_FT4`
10. `lab_ALT`
11. `lab_hct`
12. `lab_mch`
13. `lab_HDL`
14. `lab_LDL`
15. `lab_ALK_P`
16. `lab_Cholesterol`
17. `lab_AST`
18. `SCr_slope`
19. `ALT_slope`

### Additional 27 features selected only by XGBoost RFECV

- `SEX_TYPE`
- `Aver_dose_kg`
- `rx_NSAIDs`
- `rx_allopurinols`
- `rx_antiDMs`
- `rx_metformins`
- `rx_arrhythmia_type1bs`
- `dx_bradycardias`
- `dx_anemias`
- `dx_hypertensions`
- `dx_diabetess`
- `dx_DMnephropathys`
- `dx_DM_coms`
- `dx_renal_dysfunction`
- `T3_REMARK`
- `SCr_REMARK`
- `Cholesterol_REMARK`
- `HDL_REMARK`
- `ALK_P_REMARK`
- `lab_rbc`
- `lab_hgb`
- `lab_mcv`
- `lab_mchc`
- `lab_SCr`
- `lab_tg`
- `AST_slope`
- `Cholesterol_slope`

Appendix naming contains pluralization inconsistencies. Normalize names in a feature dictionary.

---

# 8. Preprocessing and missing-data handling

**Explicitly stated pipeline elements:**

1. **RobustScaler** used to normalize numeric data and reduce influence of extremes / range differences.
2. Variables with **>90% missingness** were removed from ML programs.
3. Missing data imputation:
   - first **LOCF (last observation carried forward)**,
   - remaining missing values → **MICE (Multivariate Imputation by Chained Equations)** using scikit-learn,
   - changing-rate/slope variables with missing values → **0**.

## Important unresolved preprocessing details

The paper does not clearly report:

- whether RobustScaler was fit separately within each CV training fold,
- whether MICE was fit separately within each CV training fold,
- exact MICE estimator/options/random state/iterations,
- whether preprocessing was performed before or after train-fold splitting,
- whether resampling occurred after imputation/scaling and only within training folds.

For **methodologically strict code**, prevent leakage by fitting imputation/scaling/resampling only on each training fold. For **exact historical reproduction**, request original code/settings.

---

# 9. Feature leakage concern around TSH/fT4

TSH and fT4 are both:

- major predictive features, and
- part of the AITD outcome definition.

The paper states that because TSH/fT4 are definite diagnostic criteria, the **last data values before the prediction point were masked to avoid data leakage in the test set**.

This wording is not sufficiently operational for SQL.

### Must clarify

- Which TSH/fT4 record is masked?
- Is the entire prediction-window lab data excluded, while the preceding observation-window value remains available?
- When event is defined by TSH/fT4, how are lab pairs separated from predictor values?

Do not use the event-defining thyroid tests as predictors for the same prediction instance.

---

# 10. ML algorithms and resampling

Four classifiers:

1. XGBoost
2. AdaBoost
3. K-nearest neighbors (KNN)
4. Logistic regression (LR)

Four sampling conditions:

1. Raw (no resampling)
2. Borderline-SMOTE (`B-SMT`) oversampling
3. Edited Nearest Neighbors (`ENN`) undersampling
4. Hybrid Borderline-SMOTE + ENN (`B-SMT-ENN`, “Hyb”)

Total = **16 models**.

### Important missing reproducibility parameters

Paper/appendices do not provide the full implementation parameters for:

- BorderlineSMOTE (`kind`, sampling_strategy, k_neighbors, m_neighbors, random_state, etc.)
- ENN (`n_neighbors`, kind_sel, sampling_strategy, etc.)
- exact order of oversampling/undersampling inside the hybrid pipeline.

Request these from the original team or source code.

---

# 11. Hyperparameter tuning and CV

## 11.1 What the main paper says

- Exhaustive grid search.
- 5-fold CV inside each grid option.
- Optimal hyperparameters selected according to highest **F1 score** in the main-text Methods.

## 11.2 Appendix 5 inconsistency

Appendix 5 pseudocode says after GridSearchCV:

> “Calculate the best average precision with the best combination of hyperparameters.”

while the main paper says the grid search optimized **F1 score**.

**Do not silently choose one if exact replication matters. Ask authors which scoring argument was actually used in `GridSearchCV`.**

## 11.3 Fold generator

Appendix 5 explicitly uses:

```python
StratifiedKFold(Split the data into 5 groups)
```

for:

- grid search,
- RFECV,
- final 5-fold cross-validation.

There is **no GroupKFold / patient-grouping logic documented**.

### Interpretation depends on observation unit

- If one patient = one row → ordinary StratifiedKFold is natural.
- If one patient contributes multiple snapshots → ordinary row-level StratifiedKFold may leak information from the same patient across train/validation folds.

This is why the “one ML row” question must be clarified before reproducing the internal CV exactly.

---

# 12. Grid-search spaces (Appendix 4)

## XGBoost

```python
max_depth = [3, 5, 8, 10, 12, 15, 18]
min_child_weight = [0.10, 0.20, 0.30, 0.40]
gamma = [0, 0.1, 0.2, 0.4, 0.5, 0.6, 0.7]
subsample = [0.6, 0.7, 0.8, 0.9]
colsample_bytree = [0.6, 0.7, 0.8, 0.9]
n_estimators = [50, 100, 200, 500, 1000, 1500]
learning_rate = [0.001, 0.01, 0.1, 0.2, 0.3]
```

Main paper reports **94,080 XGBoost grid combinations**.

## AdaBoost

```python
n_estimators = [10, 50, 250, 1000, 1500, 2000, 2500, 3000]
learning_rate = [0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0]
algorithm = ['SAMME', 'SAMME.R']
```

## KNN

```python
n_neighbors = range(1, 31)
weights = ['uniform', 'distance']
metric = ['euclidean', 'manhattan']
```

## Logistic Regression

```python
C = np.logspace(-3, 3, 7)
solver = ['lbfgs', 'liblinear', 'sag', 'saga', 'newton-cg']
penalty = ['l1', 'l2', 'elasticnet', 'none']
```

Some solver/penalty combinations are invalid in scikit-learn and would normally fail/return NaN unless handled; exact package version/error_score behavior is not reported.

---

# 13. Final best hyperparameters (Appendix 4)

## XGBoost

| Model | gamma | max_depth | min_child_weight | colsample_bytree | subsample | n_estimators | learning_rate |
|---|---:|---:|---:|---:|---:|---:|---:|
| XGB-Raw | 0.1 | 8 | 0.4 | 0.7 | 0.8 | 100 | 0.2 |
| **XGB-B-SMT** | **0.1** | **10** | **0.2** | **0.7** | **0.9** | **1000** | **0.01** |
| XGB-ENN | 0 | 15 | 0.2 | 0.7 | 0.7 | 500 | 0.01 |
| XGB-Hyb | 0.6 | 5 | 0.1 | 0.6 | 0.8 | 1500 | 0.1 |

## AdaBoost

| Model | algorithm | learning_rate | n_estimators |
|---|---|---:|---:|
| Ada-Raw | SAMME.R | 0.1 | 250 |
| Ada-B-SMT | SAMME | 0.3 | 1500 |
| Ada-ENN | SAMME | 0.6 | 1000 |
| Ada-Hyb | SAMME | 0.9 | 250 |

## KNN

| Model | metric | n_neighbors | weights |
|---|---|---:|---|
| KNN-Raw | manhattan | 30 | distance |
| KNN-B-SMT | manhattan | 30 | distance |
| KNN-ENN | manhattan | 30 | distance |
| KNN-Hyb | manhattan | 29 | distance |

## Logistic Regression (`max_iter=1000` where stated)

| Model | C | penalty | solver |
|---|---:|---|---|
| LR-Raw | 1 | l2 | liblinear |
| LR-B-SMT | 0.001 | none | lbfgs |
| LR-ENN | 10 | l2 | liblinear |
| LR-Hyb | 0.1 | l1 | liblinear |

---

# 14. Internal 5-fold CV performance (Appendix 9)

For the key XGBoost models, average training-set CV metrics:

| Model | Accuracy | Precision | Recall | F1 |
|---|---:|---:|---:|---:|
| XGB-Raw | 0.907 | 0.762 | 0.509 | 0.614 |
| **XGB-B-SMT** | **0.898** | **0.640** | **0.664** | **0.651** |
| XGB-ENN | 0.903 | 0.677 | 0.611 | 0.641 |
| XGB-Hyb | 0.897 | 0.652 | 0.612 | 0.631 |

Appendix 9 provides all fold-level values for all 16 models.

---

# 15. External test-set performance

The paper emphasizes AUPRC, F1, G-mean, and recall because the outcome is imbalanced. Recall is prioritized over precision to reduce missed AITD cases.

From Table 2, **XGB-B-SMT** external-test performance at the default classification setup was:

- AUPRC = **0.751**
- Recall = **0.756**
- F1 = **0.688**
- G-mean = **0.845**
- Accuracy = **0.923**
- Precision = **0.632**
- AUROC = **0.934**

### XGBoost AUPRC values

- XGB-Raw = 0.742
- XGB-B-SMT = **0.751**
- XGB-ENN = 0.741
- XGB-Hyb = 0.730

Appendix 10 reports bootstrap 95% CIs and says XGB-B-SMT AUPRC was significantly different from the other XGBoost sampling variants.

Appendix 10 methodology:

- 1,000 bootstrap iterations for differences in AUPRC areas.
- Difference considered significant when 95% CI does not include 0.

---

# 16. SHAP findings

Important high-impact features reported in the paper include:

- higher TSH → higher predicted AITD risk,
- lower fT4 → higher risk,
- shorter treatment duration → higher risk,
- lower ALP → higher risk,
- higher HDL → higher risk,
- lower LDL → higher risk,
- longer therapeutic days,
- higher cumulative dose,
- older age,
- lower BMI.

### Methodological caution: `Duration`

Because event patients stop data collection before their event while event-free patients can contribute longer follow-up, a short `Duration` may partly encode **how early the outcome/censoring happened**, depending on how the final observation row was constructed.

This is an **inference/concern**, not a fact asserted by the authors. It should be investigated during reproduction, especially if one row per patient uses the last eligible window.

---

# 17. Decision threshold analysis — very important

The paper moved the classification threshold on the PR curve and examined Kaplan-Meier curves.

Reported thresholds:

- 0.995 → approximately top 1% high-risk
- 0.953 → top 5%
- **0.627 → “optimal” threshold by maximal F1**
- 0.5 → default / around top 15%
- 0.142 → top 25%

At threshold **0.627**:

- F1 ≈ **0.699**
- recall ≈ **0.713**
- precision ≈ **0.685**
- accuracy ≈ **0.93**
- 286/2,422 classified high-risk
- 196/275 AITD patients were above 0.627 in Figure 5 (71.3%)
- 2,057/2,147 non-AITD patients were below 0.627 (95.8%)

### Internal numerical inconsistency in the paper

The abstract/results text in some places says that the 0.627 cutoff classified 286 patients as high-risk and that **275 were true positives**. This conflicts with Figure 5 and the reported threshold metrics:

- Figure 5 explicitly states **196/275 AITD patients** were above 0.627.
- 196 / 286 = 0.685, exactly matching the reported precision of 0.685.
- Recall 196 / 275 = 0.713, exactly matching the reported recall of 0.713.

Therefore, **196 true positives is internally consistent with the threshold-specific metrics**, while “275 true positives” appears to be a reporting error. Do not reproduce 275 as the confusion-matrix TP count without author clarification.

## Critical unresolved issue: where was threshold 0.627 selected?

The paper clearly says the threshold was selected using the PR curve / maximal F1, and results are shown on the external test cohort. However, it does not state unambiguously whether the PR curve used to choose 0.627 came from:

- training-set / CV predictions, or
- external test-set predictions.

Our discussion concluded that the paper **appears consistent with test-set-based threshold analysis**, but this must not be stated as certain without author confirmation.

### Mandatory author question

> Was the optimal decision threshold of 0.627 determined using training-set cross-validation/out-of-fold predictions, or using the external test-set predictions?

### Methodological rule for Gil validation

If Gil data are used as a **strict external validation set**, then:

- do not optimize hyperparameters on Gil outcomes,
- do not select features based on Gil outcomes,
- do not optimize a decision threshold on Gil outcomes for the primary validation result.

A threshold may be re-estimated in a **secondary recalibration/model-updating analysis**, but it should be clearly labeled as such.

---

# 18. Hyperparameters vs test set

**Paper-supported interpretation:** hyperparameters were tuned using the training set with 5-fold CV, not the external test set.

Pipeline described:

```text
training data
  -> grid search
  -> internal 5-fold CV
  -> best hyperparameters
  -> RFECV / selected features
  -> construct models
  -> evaluate on external test set
```

However, the paper then compares 16 model variants on the external test set and identifies XGB-B-SMT as the best-performing model. Thus the external set is not perfectly analogous to a single untouched “one-shot” test if model-family/sampling choice is ultimately justified from test performance.

---

# 19. Strict external validation vs replication/redevelopment at Gil

A future GPT must first determine which scientific objective the team is pursuing.

## Mode A — strict external validation of the Taiwan-developed model

Ideal requirements:

- original trained model artifact or coefficients/tree model,
- original 19-feature definitions,
- original preprocessing objects/parameters (imputer/scaler),
- original threshold if threshold-dependent metrics are primary,
- no Gil outcome-driven tuning before primary evaluation.

Gil data are used only to compute predictions and evaluate discrimination/calibration/classification metrics.

If the original trained artifact is unavailable and the model is re-fit on Gil data, this is **not a pure external validation of the original fitted model**.

## Mode B — methodological replication / redevelopment on Gil data

If building a Korean model using the same methodology:

```text
Gil cohort
  -> pre-specified development/held-out split
  -> feature engineering
  -> training-fold preprocessing
  -> training-fold resampling
  -> RFECV / grid-search within development data
  -> threshold selection from training/CV OOF probabilities
  -> freeze pipeline
  -> final held-out Gil test evaluation
```

## Mode C — transport/update after external validation

After a primary untouched external validation, one may separately perform:

- probability recalibration,
- threshold recalibration,
- model refitting,
- feature/model updating.

Report this separately from external-validation performance.

---

# 20. Recommended data architecture for SQL / Python

Because the observation-unit question is unresolved, preserve all longitudinal information in a canonical extraction layer.

## 20.1 Suggested intermediate tables

### A. `cohort_index`

```text
patient_id
index_date
age_at_index
sex
study_entry_flag
```

### B. `preindex_exclusions`

```text
patient_id
pregnancy_flag
pre_thyroid_lab_flag
pre_thyroid_dx_flag
pre_thyroid_med_flag
pre_thyroidectomy_flag
exclude_flag
exclude_reason
```

Lookback: 365 days before index unless authors clarify otherwise.

### C. `outcome_candidates`

One row per potential event evidence:

```text
patient_id
candidate_event_date
candidate_event_type
source_code
TSH
FT4
reference_range
```

Then:

```text
event_date = MIN(candidate_event_date)
```

after index, subject to proper event rules.

### D. `followup`

```text
patient_id
index_date
event_date
loss_to_followup_date
administrative_end_date
followup_end_date
outcome
```

### E. `landmarks`

Create rows at:

```text
0, 1, 2, 3, 6, 9, 12, 15, 18, 21 months
```

with explicit observation/prediction-window boundaries.

```text
patient_id
landmark_month
obs_start
obs_end
pred_start
pred_end
eligible_landmark_flag
```

### F. `feature_long`

```text
patient_id
landmark_month
Age
Sex
BMI
Cumulative_dose_g
Duration
PDD
Therapeutic_days
charlson_TOT_GRP
lab_TSH
lab_FT4
...
SCr_slope
ALT_slope
rx_*
dx_*
```

### G. `model_matrix`

Generate only after observation-unit clarification.

---

# 21. Generic SQL decomposition

Use modular CTEs/views instead of one monolithic query.

```sql
WITH first_amiodarone AS (
    -- first oral amiodarone prescription per patient
),
eligible_age AS (
    -- age > 18
),
preindex_thyroid_lab AS (
    -- TSH >10 or <0.1 within prior 365d
),
preindex_thyroid_dx AS (
    -- Appendix 1 diagnosis-code exclusions
),
preindex_thyroid_med AS (
    -- levothyroxine/PTU/carbimazole/methimazole
),
preindex_thyroid_surgery AS (
    -- thyroidectomy
),
base_cohort AS (
    -- exclusions applied
),
postindex_event_candidates AS (
    -- lab + diagnosis + medication + surgery AITD candidates
),
first_event AS (
    SELECT patient_id, MIN(event_date) AS event_date
    FROM postindex_event_candidates
    GROUP BY patient_id
),
followup AS (
    -- event, LTFU, or 2y administrative censoring
),
landmarks AS (
    -- baseline, 1,2,3,6,9,12,15,18,21 months
),
lab_features AS (
    -- window-specific lab extraction
),
rx_features AS (
    -- dynamic comedication flags
),
dx_features AS (
    -- dynamic comorbidity flags
),
amiodarone_exposure AS (
    -- cumulative dose, duration, PDD, therapeutic days
),
feature_long AS (
    -- join by patient + landmark
)
SELECT * FROM feature_long;
```

**Do not finalize aggregation rules (`latest`, `mean`, `ever`, `active`) unless the paper or authors support them.**

---

# 22. Questions that must be sent to / confirmed with the original authors

These are high priority because they change SQL/model outputs.

## Observation / labeling

1. **What was the unit of observation in the model matrix: one row per patient or multiple rows per patient-timepoint?**
2. If multiple rows per patient, how exactly was the target assigned at each landmark?
3. If multiple rows, was CV grouped by patient or ordinary row-level StratifiedKFold?
4. For one-row-per-patient implementation, which observation window supplied the final lab/comorbidity/medication values?

## Dynamic features

5. For repeated labs within a window, was the value `latest`, `closest to landmark`, mean, median, etc.?
6. For comorbidities, is a flag based on:
   - diagnosis ever before landmark,
   - diagnosis within current window,
   - active/latest diagnosis?
7. For comedications, is a flag based on:
   - any prescription in window,
   - prescription overlapping landmark date,
   - cumulative/ever-use before landmark?
8. Exact formulas for `Aver_dose_kg`, `PDD`, `Therapeutic days`, and cumulative effective dose.
9. Exact slope calculation: which two lab observations are used?

## Outcome

10. Exact TSH/fT4 pairing rule for laboratory-defined AITD.
11. Definition of normal fT4 range.
12. Exact “loss to follow-up” operational definition.
13. Confirm actual study index-date period: 2005–2017 or 2013–2017.

## Modeling

14. Was `GridSearchCV(scoring=...)` F1 or average precision? Main text and Appendix 5 conflict.
15. Exact StratifiedKFold parameters: shuffle? random_state?
16. Exact RFECV scoring, step, min_features_to_select.
17. Exact RobustScaler settings and whether it was fit fold-wise.
18. Exact MICE / IterativeImputer settings and whether it was fit fold-wise.
19. Exact BorderlineSMOTE parameters and package/version.
20. Exact ENN parameters and package/version.
21. In the hybrid method, exact ordering and sampling ratios.
22. Package versions for scikit-learn, xgboost, imbalanced-learn.
23. Was the 0.627 threshold selected on training/CV predictions or external test predictions?
24. Is original source code and/or trained model artifact available?

---

# 23. Reproduction guardrails for the next GPT

When writing SQL/model code from this handoff:

1. **Never invent hospital table/column names.** Ask for Gil DB schema/data dictionary first.
2. **Never silently map local codes to ICD/ATC.** Build explicit mapping tables.
3. Keep a stable `patient_id` and preserve timestamps throughout extraction.
4. Build a long patient-landmark table before collapsing to ML rows.
5. Ensure outcome-defining labs are not simultaneously used as predictors for the same prediction instance.
6. If using repeated patient rows, split/group by patient to avoid same-patient leakage unless intentionally reproducing verified original behavior.
7. Fit imputation/scaling/resampling only from development/training data for rigorous validation.
8. Apply SMOTE/ENN **inside training folds**, not before CV, unless exact original code proves otherwise.
9. For strict external validation, do not tune the model/threshold on Gil outcomes.
10. Separate:
    - original-specification reproduction,
    - strict external validation,
    - recalibration/model updating.
11. Preserve all unresolved implementation choices in a configuration object and document them.

Suggested configuration idea:

```yaml
observation_unit: UNKNOWN  # patient | landmark
index_period: UNKNOWN      # 2005-2017 | 2013-2017
lab_within_window: UNKNOWN # latest | closest | mean
comorbidity_logic: UNKNOWN
comedication_logic: UNKNOWN
cv_grouped_by_patient: UNKNOWN
grid_scoring: UNKNOWN      # f1 | average_precision
threshold_source: UNKNOWN  # train_oof | external_test
```

---

# 24. Recommended modeling code organization

```text
src/
  cohort/
    index_cohort.sql
    exclusions.sql
    outcome.sql
    landmarks.sql
  features/
    amiodarone_exposure.sql
    labs.sql
    diagnoses.sql
    medications.sql
    slopes.py
    build_feature_long.py
  modeling/
    make_model_matrix.py
    preprocess.py
    resampling.py
    feature_selection.py
    tune.py
    train.py
    evaluate.py
    threshold.py
  config/
    codes.yaml
    features.yaml
    study_definition.yaml
```

Keep cohort logic independent of the final observation-unit assumption.

---

# 25. Immediate next steps for this Gil reproduction

1. Obtain/confirm the **Gil schema and source tables**:
   - patient demographics,
   - prescriptions/dispensing,
   - diagnoses,
   - labs + reference ranges,
   - procedures,
   - encounters / last-contact information.
2. Build code mappings for:
   - oral amiodarone,
   - thyroid drugs,
   - relevant diagnoses,
   - thyroidectomy,
   - selected comedications/comorbidities.
3. Implement **cohort/index/exclusions/event candidates** first.
4. Implement the **canonical patient × landmark longitudinal table**.
5. Send the observation-unit / threshold / feature-aggregation questions to original authors.
6. Only then freeze `model_matrix` logic.
7. Reproduce the 19-feature XGB-B-SMT model first because it is the final best-performing model:

```python
XGBClassifier(
    gamma=0.1,
    max_depth=10,
    min_child_weight=0.2,
    colsample_bytree=0.7,
    subsample=0.9,
    n_estimators=1000,
    learning_rate=0.01,
    # other unspecified defaults/version-dependent settings must be verified
)
```

8. Preserve an exact-reproduction branch and a methodologically strict branch if the historical implementation contains leakage-prone or under-specified steps.

---

# 26. Bottom-line mental model

The study is best thought of as:

```text
First oral amiodarone
        |
        v
2-year longitudinal follow-up
        |
        +--> repeated dynamic clinical collection
        |    at 0,1,2,3,6,9,12,15,18,21 months
        |
        +--> stop at prior observation window if AITD/LTFU
        |
        v
flat engineered clinical features
(latest/current + cumulative exposure + slopes)
        |
        v
19-feature ML model
        |
        +--> XGBoost / AdaBoost / KNN / LR
        +--> Raw / B-SMT / ENN / Hybrid
        |
        v
Best reported: XGB + Borderline-SMOTE
AUPRC 0.751, AUROC 0.934
        |
        v
SHAP explanation + threshold-moving/KM analysis
```

But the exact mapping from the repeated time windows to the flat ML rows remains the single most important unresolved implementation detail.

---

# 27. Source-vs-inference legend

### Explicitly source-supported

- cohort sizes and hospital split,
- repeated collection time points,
- dynamic comorbidity/comedication/lab collection,
- outcome definitions,
- missing-data handling steps,
- RFECV feature counts and selected 19 features,
- grid spaces and final hyperparameters,
- use of StratifiedKFold in Appendix 5 pseudocode,
- reported performance,
- threshold values and threshold-moving analysis.

### Inference / methodological interpretation from our discussion

- one-row-per-patient may be more likely than repeated landmark rows, but is unconfirmed;
- `Duration` may partially encode proximity to event depending on model-matrix construction;
- external-test threshold tuning would compromise a strict untouched external validation;
- preprocessing/resampling should be fold-local for rigorous modern implementation.

### Unresolved / must ask authors

- observation unit,
- within-window feature aggregation,
- patient grouping in CV if repeated rows,
- exact TSH/fT4 event pairing and leakage masking,
- exact resampler/imputer/scaler settings,
- F1 vs average-precision grid-search scoring,
- source of threshold 0.627,
- exact index-date period.

---

**End of handoff.**