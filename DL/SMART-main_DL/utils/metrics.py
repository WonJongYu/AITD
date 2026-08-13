import logging

import numpy as np
from sklearn import metrics


def _binary_arrays(y_true, predictions):
    y_true = np.asarray(y_true).astype(int).reshape(-1)
    predictions = np.asarray(predictions)
    if predictions.ndim == 1:
        positive_probability = predictions.astype(float)
    elif predictions.ndim == 2 and predictions.shape[1] == 2:
        positive_probability = predictions[:, 1].astype(float)
    else:
        raise ValueError("predictions must be positive-class probabilities or an N x 2 array")
    if len(y_true) != len(positive_probability):
        raise ValueError("y_true and predictions must have the same number of rows")
    if not np.isfinite(positive_probability).all():
        raise ValueError("predictions contain NaN or infinite values")
    if ((positive_probability < 0) | (positive_probability > 1)).any():
        raise ValueError("predicted probabilities must be between 0 and 1")
    return y_true, positive_probability


def _safe_div(numerator, denominator):
    return float(numerator / denominator) if denominator else 0.0


def print_metrics_binary(y_true, predictions, threshold=0.5, verbose=True):
    """Calculate binary metrics at an explicitly supplied decision threshold.

    AUROC and Average Precision are threshold-free. If a split contains only one
    class, both are returned as NaN because discrimination cannot be assessed.
    """
    y_true, positive_probability = _binary_arrays(y_true, predictions)
    if not 0.0 <= threshold <= 1.0:
        raise ValueError("threshold must be between 0 and 1")

    predicted_label = (positive_probability >= threshold).astype(int)
    cf = metrics.confusion_matrix(y_true, predicted_label, labels=[0, 1]).astype(np.float32)
    if verbose:
        logging.info(cf.astype(int))

    acc = _safe_div(cf[0, 0] + cf[1, 1], np.sum(cf))
    prec1 = _safe_div(cf[1, 1], cf[1, 1] + cf[0, 1])
    rec0 = _safe_div(cf[0, 0], cf[0, 0] + cf[0, 1])
    rec1 = _safe_div(cf[1, 1], cf[1, 1] + cf[1, 0])
    f1_score = _safe_div(2 * prec1 * rec1, prec1 + rec1)

    has_both_classes = len(np.unique(y_true)) == 2
    if has_both_classes:
        auroc = float(metrics.roc_auc_score(y_true, positive_probability))
        # average_precision_score uses the standard step-wise PR integration.
        average_precision = float(metrics.average_precision_score(y_true, positive_probability))
        precisions, recalls, _ = metrics.precision_recall_curve(y_true, positive_probability)
        minpse = float(np.max(np.minimum(precisions, recalls)))
    else:
        auroc = np.nan
        average_precision = np.nan
        minpse = np.nan

    if verbose:
        logging.info("AUROC = %.4f", auroc)
        logging.info("Average Precision = %.4f", average_precision)
        logging.info("threshold = %.6f; F1 = %.4f", threshold, f1_score)

    return {
        "threshold": float(threshold),
        "accuracy": acc,
        "auroc": auroc,
        # Keep auprc for output compatibility, but its definition is now AP.
        "auprc": average_precision,
        "average_precision": average_precision,
        "minpse": minpse,
        "f1_score": f1_score,
        "sensitivity": rec1,
        "specificity": rec0,
        "precision": prec1,
        "n_negative": int((y_true == 0).sum()),
        "n_positive": int((y_true == 1).sum()),
        "confusion_matrix": cf.astype(int).tolist(),
    }


def select_binary_threshold(
    y_true,
    predictions,
    method="target-sensitivity",
    target_sensitivity=0.90,
):
    """Select a threshold using validation data only.

    Supported methods:
      - target-sensitivity: highest threshold attaining the requested sensitivity
      - f1: threshold with the highest validation F1
      - youden: threshold with the highest sensitivity + specificity - 1

    A one-class validation split cannot identify an operating point. In that
    situation 0.5 is returned as an explicit fallback rather than raising.
    """
    y_true, positive_probability = _binary_arrays(y_true, predictions)
    supported = {"target-sensitivity", "f1", "youden"}
    if method not in supported:
        raise ValueError(f"threshold method must be one of {sorted(supported)}")
    if not 0.0 < target_sensitivity <= 1.0:
        raise ValueError("target_sensitivity must be in (0, 1]")

    if len(np.unique(y_true)) < 2:
        return {
            "threshold": 0.5,
            "method": "fallback-0.5-single-class-validation",
            "requested_method": method,
            "target_sensitivity": float(target_sensitivity),
        }

    if method == "target-sensitivity":
        false_positive_rate, true_positive_rate, thresholds = metrics.roc_curve(
            y_true, positive_probability
        )
        eligible = np.flatnonzero(
            np.isfinite(thresholds) & (true_positive_rate >= target_sensitivity)
        )
        # The lowest observed probability always attains sensitivity 1, so this
        # branch is defensive. Pick the highest threshold among eligible points,
        # which gives the greatest specificity for the requested sensitivity.
        threshold = (
            float(np.max(thresholds[eligible]))
            if len(eligible)
            else float(np.min(positive_probability))
        )
    elif method == "f1":
        precisions, recalls, thresholds = metrics.precision_recall_curve(
            y_true, positive_probability
        )
        if len(thresholds) == 0:
            threshold = 0.5
        else:
            denominator = precisions[:-1] + recalls[:-1]
            f1_scores = np.divide(
                2 * precisions[:-1] * recalls[:-1],
                denominator,
                out=np.zeros_like(denominator),
                where=denominator > 0,
            )
            best = np.flatnonzero(f1_scores == np.max(f1_scores))
            threshold = float(np.max(thresholds[best]))
    else:
        false_positive_rate, true_positive_rate, thresholds = metrics.roc_curve(
            y_true, positive_probability
        )
        youden_scores = true_positive_rate - false_positive_rate
        finite = np.flatnonzero(np.isfinite(thresholds))
        best_score = np.max(youden_scores[finite])
        best = finite[youden_scores[finite] == best_score]
        threshold = float(np.max(thresholds[best]))

    validation_metrics = print_metrics_binary(
        y_true, positive_probability, threshold=threshold, verbose=False
    )
    return {
        "threshold": threshold,
        "method": method,
        "requested_method": method,
        "target_sensitivity": float(target_sensitivity),
        "validation_sensitivity": validation_metrics["sensitivity"],
        "validation_specificity": validation_metrics["specificity"],
        "validation_f1": validation_metrics["f1_score"],
    }
