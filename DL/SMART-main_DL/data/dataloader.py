import torch
import numpy as np
from torch.nn.utils.rnn import pad_sequence
from typing import Any, Dict, List


def collate_fn(features: List[Dict[str, Any]]):
    batch = {}
    for key in features[0].keys():
        if key in ["x", "mask", "time"]:
            batch[key] = pad_sequence([torch.tensor(patient[key]) for patient in features], True)
        else:
            batch[key] = torch.as_tensor(np.asarray([patient[key] for patient in features]))
    return batch
