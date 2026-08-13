#!/usr/bin/env python3
"""Fine-tune SMART for AITD Task 1 or thyroid subtype Task 2."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from torch.utils.data import DataLoader

from data.amiodarone import load_amiodarone
from data.dataloader import collate_fn
from models.smart import Classifier, Encoder
from utils.metrics import print_metrics_binary, select_binary_threshold
from utils.utils import set_seed


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", required=True, choices=["task1", "task2"])
    parser.add_argument("--data-dir", default="./data/amiodarone/processed")
    parser.add_argument("--save-root", default="./export/amiodarone")
    parser.add_argument(
        "--pretrain-checkpoint",
        default="./export/amiodarone/pretrain/checkpoint-mse.pth",
    )
    parser.add_argument("--require-pretrained", action="store_true")
    parser.add_argument("--epochs", type=int, default=50)
    parser.add_argument("--freeze-epochs", type=int, default=5)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--d-model", type=int, default=32)
    parser.add_argument("--dropout", type=float, default=0.1)
    parser.add_argument("--e-layers", type=int, default=2)
    parser.add_argument("--n-heads", type=int, default=4)
    parser.add_argument("--seed", type=int, default=3407)
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda"])
    parser.add_argument("--num-workers", type=int, default=0)
    parser.add_argument("--class-weights", action="store_true")
    parser.add_argument(
        "--threshold-method",
        default="target-sensitivity",
        choices=["target-sensitivity", "f1", "youden"],
        help="Select the operating threshold on validation data only.",
    )
    parser.add_argument(
        "--target-sensitivity",
        type=float,
        default=0.90,
        help="Validation sensitivity target when --threshold-method=target-sensitivity.",
    )
    return parser.parse_args()


def resolve_device(name: str) -> torch.device:
    if name == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if name == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("--device cuda was requested but CUDA is unavailable")
    return torch.device(name)


def move_batch(batch, device):
    return {key: value.to(device) for key, value in batch.items()}


def build_class_weights(labels: np.ndarray, device: torch.device):
    counts = np.bincount(labels.astype(int), minlength=2)
    if np.any(counts == 0):
        raise ValueError(f"Training split must contain both labels; counts={counts.tolist()}")
    weights = len(labels) / (2.0 * counts.astype(np.float64))
    return torch.tensor(weights, dtype=torch.float32, device=device)


def train_epoch(loader, encoder, classifier, criterion, optimizer, device, freeze_encoder):
    classifier.train()
    encoder.eval() if freeze_encoder else encoder.train()
    total_loss = 0.0
    total_n = 0
    for batch in loader:
        batch = move_batch(batch, device)
        if freeze_encoder:
            with torch.no_grad():
                representation = encoder(**batch)
        else:
            representation = encoder(**batch)
        logits = classifier(representation, **batch)
        loss = criterion(logits, batch["labels"])
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
        n = batch["labels"].shape[0]
        total_loss += float(loss.item()) * n
        total_n += n
    return total_loss / max(total_n, 1)


def evaluate(loader, encoder, classifier, criterion, device, threshold=0.5):
    encoder.eval()
    classifier.eval()
    total_loss = 0.0
    total_n = 0
    probabilities = []
    labels = []
    with torch.no_grad():
        for batch in loader:
            batch = move_batch(batch, device)
            logits = classifier(encoder(**batch), **batch)
            loss = criterion(logits, batch["labels"])
            probability = torch.softmax(logits, dim=-1)
            probabilities.append(probability.cpu())
            labels.append(batch["labels"].cpu())
            n = batch["labels"].shape[0]
            total_loss += float(loss.item()) * n
            total_n += n
    if total_n == 0:
        raise ValueError("Evaluation split is empty")
    probability = torch.cat(probabilities)
    label = torch.cat(labels)
    metric_values = print_metrics_binary(
        label, probability, threshold=threshold, verbose=False
    )
    metric_values["loss"] = total_loss / total_n
    return metric_values, probability.numpy(), label.numpy()


def json_ready(value):
    if isinstance(value, dict):
        return {key: json_ready(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_ready(item) for item in value]
    if isinstance(value, (np.floating, float)):
        return None if not math.isfinite(float(value)) else float(value)
    if isinstance(value, (np.integer,)):
        return int(value)
    return value


def main():
    args = parse_args()
    set_seed(args.seed)
    device = resolve_device(args.device)
    train_data, val_data, test_data, metadata = load_amiodarone(args.task, args.data_dir)
    if min(len(train_data), len(val_data), len(test_data)) == 0:
        raise ValueError(f"{args.task} train/val/test splits must all be non-empty")

    args.input_dim = metadata["input_dim"]
    args.demo_dim = metadata["static_dim"]
    args.max_len = metadata["max_len"]
    args.num_class = 2
    if args.d_model % args.n_heads != 0:
        raise ValueError("d_model must be divisible by n_heads")

    train_loader = DataLoader(
        train_data, batch_size=args.batch_size, shuffle=True,
        num_workers=args.num_workers, collate_fn=collate_fn,
    )
    val_loader = DataLoader(
        val_data, batch_size=args.batch_size, shuffle=False,
        num_workers=args.num_workers, collate_fn=collate_fn,
    )
    test_loader = DataLoader(
        test_data, batch_size=args.batch_size, shuffle=False,
        num_workers=args.num_workers, collate_fn=collate_fn,
    )

    encoder = Encoder(args).to(device)
    classifier = Classifier(args).to(device)
    print(
        "Classifier pooling: variable-axis mean; "
        f"final input dimension={args.d_model + (args.d_model if args.demo_dim > 0 else 0)}; "
        f"classifier parameters={sum(parameter.numel() for parameter in classifier.parameters())}"
    )
    checkpoint_path = Path(args.pretrain_checkpoint)
    pretrained_loaded = checkpoint_path.exists()
    if pretrained_loaded:
        checkpoint = torch.load(checkpoint_path, map_location=device)
        checkpoint_metadata = checkpoint.get("metadata", {})
        if checkpoint_metadata.get("dynamic_features") not in (None, metadata["dynamic_features"]):
            raise ValueError("Pretraining checkpoint uses a different dynamic feature order")
        encoder.load_state_dict(checkpoint["encoder"])
        print(f"Loaded pretrained encoder: {checkpoint_path}")
    elif args.require_pretrained:
        raise FileNotFoundError(f"Required pretrained checkpoint not found: {checkpoint_path}")
    else:
        args.freeze_epochs = 0
        print("Pretraining checkpoint not found; training encoder from scratch")

    class_weight = None
    train_labels = np.asarray(train_data.labels)
    if args.class_weights:
        class_weight = build_class_weights(train_labels, device)
        print(f"Class weights: {class_weight.detach().cpu().tolist()}")
    elif len(np.unique(train_labels)) < 2:
        raise ValueError("Training split must contain both labels")
    criterion = torch.nn.CrossEntropyLoss(weight=class_weight)
    optimizer = torch.optim.Adam(
        list(encoder.parameters()) + list(classifier.parameters()), lr=args.lr
    )

    save_dir = Path(args.save_root) / args.task
    save_dir.mkdir(parents=True, exist_ok=True)
    best_score = -float("inf")
    history = []
    for epoch in range(1, args.epochs + 1):
        freeze_encoder = pretrained_loaded and epoch <= args.freeze_epochs
        train_loss = train_epoch(
            train_loader, encoder, classifier, criterion, optimizer, device, freeze_encoder
        )
        val_metrics, _, _ = evaluate(val_loader, encoder, classifier, criterion, device)
        # Checkpoint ranking uses standard Average Precision, not trapezoidal PR-AUC.
        score = val_metrics["average_precision"]
        if not np.isfinite(score):
            score = -val_metrics["loss"]
        history.append({"epoch": epoch, "train_loss": train_loss, **json_ready(val_metrics)})
        print(
            f"Epoch {epoch:03d} train={train_loss:.6f} "
            f"val_loss={val_metrics['loss']:.6f} "
            f"val_auroc={val_metrics['auroc']:.4f} "
            f"val_average_precision={val_metrics['average_precision']:.4f}"
        )
        if score > best_score:
            best_score = score
            torch.save(
                {
                    "epoch": epoch,
                    "encoder": encoder.state_dict(),
                    "classifier": classifier.state_dict(),
                    "metadata": metadata,
                    "args": vars(args),
                },
                save_dir / "checkpoint-best.pth",
            )

    best = torch.load(save_dir / "checkpoint-best.pth", map_location=device)
    encoder.load_state_dict(best["encoder"])
    classifier.load_state_dict(best["classifier"])
    best_val_at_05, val_probabilities, val_labels = evaluate(
        val_loader, encoder, classifier, criterion, device, threshold=0.5
    )
    threshold_selection = select_binary_threshold(
        val_labels,
        val_probabilities,
        method=args.threshold_method,
        target_sensitivity=args.target_sensitivity,
    )
    decision_threshold = threshold_selection["threshold"]
    validation_metrics = print_metrics_binary(
        val_labels, val_probabilities, threshold=decision_threshold, verbose=False
    )
    validation_metrics["loss"] = best_val_at_05["loss"]

    test_metrics, probabilities, labels = evaluate(
        test_loader, encoder, classifier, criterion, device,
        threshold=decision_threshold,
    )
    test_metrics_at_05 = print_metrics_binary(
        labels, probabilities, threshold=0.5, verbose=False
    )
    test_metrics_at_05["loss"] = test_metrics["loss"]
    results = {
        "task": args.task,
        "label_definition": metadata[f"{args.task}_label"],
        "best_epoch": int(best["epoch"]),
        "device": str(device),
        "pretrained_loaded": pretrained_loaded,
        "classifier_pooling": "variable_axis_mean",
        "threshold_selection": json_ready(threshold_selection),
        "validation": json_ready(validation_metrics),
        "test": json_ready(test_metrics),
        "test_at_fixed_0_5_for_comparison": json_ready(test_metrics_at_05),
        "history": history,
    }
    with (save_dir / "metrics.json").open("w", encoding="utf-8") as handle:
        json.dump(results, handle, ensure_ascii=False, indent=2)
    pd.DataFrame(
        {
            "person_id": test_data.person_ids,
            "label": labels.astype(int),
            "probability_label_0": probabilities[:, 0],
            "probability_label_1": probabilities[:, 1],
            "decision_threshold": decision_threshold,
            "predicted_label": (probabilities[:, 1] >= decision_threshold).astype(int),
        }
    ).to_csv(save_dir / "test_predictions.csv", index=False)
    print(json.dumps(results["test"], ensure_ascii=False, indent=2))
    print(f"Fine-tuning complete: {save_dir}")


if __name__ == "__main__":
    main()
