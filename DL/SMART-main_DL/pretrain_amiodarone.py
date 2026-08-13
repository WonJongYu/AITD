#!/usr/bin/env python3
"""Missing-aware SMART pretraining on the Task 1 training cohort."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from data.amiodarone import load_amiodarone
from data.dataloader import collate_fn
from models.smart import EmbeddingDecoder, Encoder
from utils.utils import set_seed


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", default="./data/amiodarone/processed")
    parser.add_argument("--save-dir", default="./export/amiodarone/pretrain")
    parser.add_argument("--epochs", type=int, default=25)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--d-model", type=int, default=32)
    parser.add_argument("--dropout", type=float, default=0.1)
    parser.add_argument("--e-layers", type=int, default=2)
    parser.add_argument("--n-heads", type=int, default=4)
    parser.add_argument("--min-mask-ratio", type=float, default=0.15)
    parser.add_argument("--max-mask-ratio", type=float, default=0.75)
    parser.add_argument("--seed", type=int, default=3407)
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda"])
    parser.add_argument("--num-workers", type=int, default=0)
    return parser.parse_args()


def resolve_device(name: str) -> torch.device:
    if name == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if name == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("--device cuda was requested but CUDA is unavailable")
    return torch.device(name)


def move_batch(batch, device):
    return {key: value.to(device) for key, value in batch.items()}


def random_masking(x, original_mask, min_ratio, max_ratio):
    batch_size = x.shape[0]
    ratios = torch.rand(batch_size, device=x.device) * (max_ratio - min_ratio) + min_ratio
    selected = (torch.rand_like(x) < ratios.view(-1, 1, 1)) & original_mask.bool()
    masked_x = x.masked_fill(selected, 0.0)
    encoder_mask = original_mask * (~selected)
    reconstruction_mask = original_mask * selected
    return masked_x, encoder_mask, reconstruction_mask


def smooth_l1_masked(prediction, target, mask, beta=1.0):
    difference = torch.abs(prediction - target)
    loss = torch.where(
        difference < beta,
        0.5 * difference ** 2 / beta,
        difference - 0.5 * beta,
    )
    expanded_mask = mask.bool()
    return (loss * expanded_mask).sum() / expanded_mask.sum().clamp_min(1)


def run_epoch(loader, encoder, predictor, target_encoder, optimizer, device, args, momentum):
    training = optimizer is not None
    encoder.train(training)
    predictor.train(training)
    target_encoder.eval()
    total_loss = 0.0
    total_n = 0

    for batch in loader:
        batch = move_batch(batch, device)
        with torch.no_grad():
            target = target_encoder(**batch)
        masked_x, masked_observation, reconstruction_mask = random_masking(
            batch["x"], batch["mask"], args.min_mask_ratio, args.max_mask_ratio
        )
        model_batch = dict(batch)
        model_batch["x"] = masked_x
        model_batch["mask"] = masked_observation
        with torch.set_grad_enabled(training):
            prediction = predictor(encoder(**model_batch))
            mask = reconstruction_mask.permute(0, 2, 1).unsqueeze(-1)
            mask = mask.expand_as(prediction[:, :, 1:])
            loss = smooth_l1_masked(prediction[:, :, 1:], target[:, :, 1:], mask)
            if training:
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
                with torch.no_grad():
                    for online, target_parameter in zip(encoder.parameters(), target_encoder.parameters()):
                        target_parameter.data.mul_(momentum).add_((1.0 - momentum) * online.detach().data)
        n = batch["x"].shape[0]
        total_loss += float(loss.item()) * n
        total_n += n
    return total_loss / max(total_n, 1)


def main():
    args = parse_args()
    set_seed(args.seed)
    device = resolve_device(args.device)
    train_data, val_data, test_data, metadata = load_amiodarone("task1", args.data_dir)
    if min(len(train_data), len(val_data), len(test_data)) == 0:
        raise ValueError("Task 1 train/val/test splits must all be non-empty")

    args.input_dim = metadata["input_dim"]
    args.demo_dim = metadata["static_dim"]
    args.max_len = metadata["max_len"]
    args.num_class = 2
    if args.d_model % args.n_heads != 0:
        raise ValueError("d_model must be divisible by n_heads")

    loaders = [
        DataLoader(dataset, batch_size=args.batch_size, shuffle=(idx == 0),
                   num_workers=args.num_workers, collate_fn=collate_fn)
        for idx, dataset in enumerate((train_data, val_data, test_data))
    ]
    encoder = Encoder(args).to(device)
    predictor = EmbeddingDecoder(args).to(device)
    target_encoder = copy.deepcopy(encoder).to(device)
    for parameter in target_encoder.parameters():
        parameter.requires_grad = False
    optimizer = torch.optim.Adam(
        list(encoder.parameters()) + list(predictor.parameters()), lr=args.lr
    )

    save_dir = Path(args.save_dir)
    save_dir.mkdir(parents=True, exist_ok=True)
    best_loss = float("inf")
    history = []
    for epoch in range(1, args.epochs + 1):
        progress = (epoch - 1) / max(args.epochs - 1, 1)
        momentum = 0.996 + progress * (1.0 - 0.996)
        train_loss = run_epoch(loaders[0], encoder, predictor, target_encoder, optimizer, device, args, momentum)
        with torch.no_grad():
            val_loss = run_epoch(loaders[1], encoder, predictor, target_encoder, None, device, args, momentum)
        history.append({"epoch": epoch, "train_loss": train_loss, "val_loss": val_loss})
        print(f"Epoch {epoch:03d} train={train_loss:.6f} val={val_loss:.6f}")
        if val_loss < best_loss:
            best_loss = val_loss
            torch.save(
                {
                    "epoch": epoch,
                    "encoder": encoder.state_dict(),
                    "predictor": predictor.state_dict(),
                    "target_encoder": target_encoder.state_dict(),
                    "metadata": metadata,
                    "args": vars(args),
                },
                save_dir / "checkpoint-mse.pth",
            )

    checkpoint = torch.load(save_dir / "checkpoint-mse.pth", map_location=device)
    encoder.load_state_dict(checkpoint["encoder"])
    predictor.load_state_dict(checkpoint["predictor"])
    target_encoder.load_state_dict(checkpoint["target_encoder"])
    with torch.no_grad():
        test_loss = run_epoch(loaders[2], encoder, predictor, target_encoder, None, device, args, 1.0)
    result = {"best_val_loss": best_loss, "test_loss": test_loss, "history": history}
    with (save_dir / "pretrain_metrics.json").open("w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2)
    print(f"Pretraining complete. test_loss={test_loss:.6f}; device={device}")


if __name__ == "__main__":
    main()

