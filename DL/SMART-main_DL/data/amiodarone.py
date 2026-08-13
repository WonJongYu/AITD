"""SMART dataset loader for the amiodarone AITD study."""

from __future__ import annotations

import pickle
from pathlib import Path

import numpy as np
from torch.utils.data import Dataset


class AmiodaroneDataset(Dataset):
    def __init__(self, split_data: dict):
        self.x = split_data["x"]
        self.mask = split_data["mask"]
        self.lens = split_data["lens"]
        self.static = split_data["static"]
        self.static_mask = split_data["static_mask"]
        self.labels = split_data["labels"]
        self.person_ids = split_data["person_ids"]

        n = len(self.labels)
        lengths = {
            len(self.x), len(self.mask), len(self.lens), len(self.static),
            len(self.static_mask), len(self.person_ids), n,
        }
        if len(lengths) != 1:
            raise ValueError("Processed split arrays have inconsistent patient counts")

    def __len__(self):
        return len(self.labels)

    def __getitem__(self, idx):
        # SMART expects variable-length sequences. Trimming here lets collate_fn
        # pad only to the longest observed patient in each batch.
        length = int(self.lens[idx])
        return {
            "x": np.asarray(self.x[idx, :length], dtype=np.float32),
            "mask": np.asarray(self.mask[idx, :length], dtype=np.float32),
            "lens": length,
            "static": np.asarray(self.static[idx], dtype=np.float32),
            "static_mask": np.asarray(self.static_mask[idx], dtype=np.float32),
            "labels": int(self.labels[idx]),
        }


def load_amiodarone(
    task: str,
    data_dir: str | Path = "./data/amiodarone/processed",
):
    if task not in {"task1", "task2"}:
        raise ValueError("task must be 'task1' or 'task2'")
    path = Path(data_dir) / f"{task}.pkl"
    if not path.exists():
        raise FileNotFoundError(
            f"Processed dataset not found: {path}. Run "
            "python data/amiodarone/preprocess.py first."
        )
    with path.open("rb") as handle:
        payload = pickle.load(handle)

    splits = payload["splits"]
    metadata = payload["metadata"]
    datasets = tuple(
        AmiodaroneDataset(splits[split]) for split in ("train", "val", "test")
    )
    return (*datasets, metadata)

