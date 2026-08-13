#!/usr/bin/env python3
"""Create a publication-ready cohort selection flowchart from aggregate counts."""

from __future__ import annotations

import argparse
import textwrap
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
from matplotlib.patches import FancyArrowPatch, Rectangle


REQUIRED_COLUMNS = {
    "step_order", "row_type", "criterion_key", "criterion_label",
    "n_before", "n_excluded", "n_remaining",
}


def parse_args():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Draw the amiodarone cohort flowchart.")
    parser.add_argument(
        "--input",
        type=Path,
        default=root / "data/amiodarone/raw/cohort_attrition.csv",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=root / "export/amiodarone",
    )
    return parser.parse_args()


def load_and_validate(path: Path):
    if not path.exists():
        raise FileNotFoundError(f"Cohort attrition CSV not found: {path}")
    frame = pd.read_csv(path).sort_values("step_order").reset_index(drop=True)
    missing = REQUIRED_COLUMNS - set(frame.columns)
    if missing:
        raise ValueError(f"cohort_attrition.csv is missing columns: {sorted(missing)}")

    for column in ("step_order", "n_before", "n_excluded", "n_remaining"):
        frame[column] = pd.to_numeric(frame[column], errors="raise").astype(int)
    if (frame[["n_before", "n_excluded", "n_remaining"]] < 0).any().any():
        raise ValueError("Cohort attrition counts cannot be negative")

    initial = frame.loc[frame["row_type"] == "initial"]
    final = frame.loc[frame["row_type"] == "final"]
    exclusions = frame.loc[frame["row_type"] == "exclusion"].copy()
    if len(initial) != 1 or len(final) != 1 or exclusions.empty:
        raise ValueError("Expected one initial row, exclusion rows, and one final row")

    remaining = int(initial.iloc[0]["n_remaining"])
    for row in exclusions.itertuples(index=False):
        if row.n_before != remaining or row.n_before - row.n_excluded != row.n_remaining:
            raise ValueError(f"Non-sequential attrition counts at: {row.criterion_key}")
        remaining = row.n_remaining
    if int(final.iloc[0]["n_remaining"]) != remaining:
        raise ValueError("Final cohort count does not match sequential attrition")
    return initial.iloc[0], exclusions, final.iloc[0]


def add_box(ax, x, y, width, height, text, fontsize=9):
    ax.add_patch(Rectangle((x, y), width, height, facecolor="white",
                           edgecolor="black", linewidth=1.0))
    ax.text(x + width / 2, y + height / 2, text, ha="center", va="center",
            fontsize=fontsize, family="DejaVu Serif", linespacing=1.25)


def draw_flowchart(initial, exclusions, final, output_dir: Path):
    fig, ax = plt.subplots(figsize=(8.27, 11.69))
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    main_x, main_width, main_height = 0.04, 0.43, 0.065
    side_x, side_width, side_height = 0.50, 0.48, 0.064
    spine_x = main_x + main_width / 2
    top_y, bottom_y = 0.91, 0.035

    initial_label = textwrap.fill(
        "Patients with a first recorded amiodarone prescription", width=42
    )
    initial_text = f"{initial_label}\nn={int(initial.n_remaining):,}"
    add_box(ax, main_x, top_y, main_width, main_height, initial_text, fontsize=9.2)

    exclusion_ys = list(
        reversed([
            bottom_y + main_height + 0.045
            + i * (top_y - bottom_y - 2 * main_height - 0.08) / max(len(exclusions) - 1, 1)
            for i in range(len(exclusions))
        ])
    )

    previous_y = top_y
    for y, row in zip(exclusion_ys, exclusions.itertuples(index=False)):
        junction_y = y + side_height / 2
        ax.add_patch(FancyArrowPatch(
            (spine_x, previous_y), (spine_x, junction_y),
            arrowstyle="-|>", mutation_scale=10, linewidth=1.0, color="black",
        ))
        ax.add_patch(FancyArrowPatch(
            (spine_x, junction_y), (side_x, junction_y),
            arrowstyle="-|>", mutation_scale=10, linewidth=1.0, color="black",
        ))
        label = textwrap.fill(f"Excluded: {row.criterion_label}", width=42)
        text = (
            f"{label}\nExcluded n={int(row.n_excluded):,}; "
            f"remaining n={int(row.n_remaining):,}"
        )
        add_box(ax, side_x, y, side_width, side_height, text, fontsize=7.4)
        previous_y = junction_y

    final_text = f"Final eligible amiodarone cohort\nn={int(final.n_remaining):,}"
    add_box(ax, main_x, bottom_y, main_width, main_height, final_text, fontsize=10)
    ax.add_patch(FancyArrowPatch(
        (spine_x, previous_y), (spine_x, bottom_y + main_height),
        arrowstyle="-|>", mutation_scale=10, linewidth=1.0, color="black",
    ))

    output_dir.mkdir(parents=True, exist_ok=True)
    png_path = output_dir / "cohort_selection_flowchart.png"
    pdf_path = output_dir / "cohort_selection_flowchart.pdf"
    fig.savefig(png_path, dpi=300, bbox_inches="tight", facecolor="white")
    fig.savefig(pdf_path, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return png_path, pdf_path


def main():
    args = parse_args()
    initial, exclusions, final = load_and_validate(args.input)
    png_path, pdf_path = draw_flowchart(initial, exclusions, final, args.output_dir)
    print(exclusions[["criterion_label", "n_excluded", "n_remaining"]].to_string(index=False))
    print(f"Flowchart PNG: {png_path}")
    print(f"Flowchart PDF: {pdf_path}")


if __name__ == "__main__":
    main()
