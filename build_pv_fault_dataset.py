#!/usr/bin/env python3
"""Consolidate semi-synthetic PV experiment CSV files into one flat CSV.

The MATLAB generator remains the source of the physical data. This utility only
organizes the generated ``signals.csv`` files and adds provenance identifiers
from their folder hierarchy. It uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

DATASET_FOLDER_NAME = "Real_Weather_PhysicsBased_PV_Fault_Datasets"
OUTPUT_FOLDER_NAME = "Consolidated_Dataset"
OUTPUT_FILE_NAME = "pv_fault_dataset_real_weather.csv"

IDENTIFIER_COLUMNS = [
    "meteo_source",
    "scenario_id",
    "experiment_id",
    "real_day",
]

PREFERRED_SIGNAL_COLUMNS = [
    "datetime",
    "time_s",
    "IR",
    "T",
    "H",
    "low_irradiance_flag",
    "I1",
    "I1_Neg",
    "I2",
    "I2_Neg",
    "I3",
    "I3_Neg",
]

REQUIRED_SIGNAL_COLUMNS = ["datetime", "time_s", "IR", "T", "H", "low_irradiance_flag"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Concatenate generated semi-synthetic PV signals.csv files into one CSV."
    )
    parser.add_argument(
        "--dataset-root",
        type=Path,
        default=None,
        help=(
            "Path to Real_Weather_PhysicsBased_PV_Fault_Datasets. "
            "Default: folder next to this script."
        ),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output CSV path. Default: <dataset-root>/Consolidated_Dataset/pv_fault_dataset_real_weather.csv",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace the output CSV if it already exists.",
    )
    return parser.parse_args()


def scenario_sort_key(value: str) -> tuple[int, str]:
    if value.startswith("F") and value[1:].isdigit():
        return int(value[1:]), value
    return 9999, value


def experiment_sort_key(value: str) -> tuple[int, str]:
    suffix = value.removeprefix("experiment_")
    if suffix.isdigit():
        return int(suffix), value
    return 9999, value


def parse_experiment_path(dataset_root: Path, signals_file: Path) -> dict[str, str]:
    """Extract provenance from the documented dataset folder hierarchy."""
    rel = signals_file.relative_to(dataset_root)
    parts = rel.parts

    # Expected layout:
    # source / F# / experiment_## / YYYY / YYYY-MM-DD / signals.csv
    if len(parts) != 6:
        raise ValueError(
            f"Unexpected signals.csv path: {rel}. Expected "
            "<source>/<scenario>/<experiment>/<year>/<YYYY-MM-DD>/signals.csv"
        )

    meteo_source, scenario_id, experiment_id, year, real_day, filename = parts

    if filename != "signals.csv":
        raise ValueError(f"Unexpected filename: {filename}")
    if not (scenario_id.startswith("F") and scenario_id[1:].isdigit()):
        raise ValueError(f"Unexpected scenario folder in {rel}: {scenario_id}")
    if not experiment_id.startswith("experiment_"):
        raise ValueError(f"Unexpected experiment folder in {rel}: {experiment_id}")
    if len(year) != 4 or not year.isdigit():
        raise ValueError(f"Unexpected year folder in {rel}: {year}")

    return {
        "meteo_source": meteo_source,
        "scenario_id": scenario_id,
        "experiment_id": experiment_id,
        "real_day": real_day,
    }


def discover_signal_files(dataset_root: Path) -> list[tuple[Path, dict[str, str]]]:
    if not dataset_root.is_dir():
        raise FileNotFoundError(f"Dataset folder not found: {dataset_root}")

    discovered: list[tuple[Path, dict[str, str]]] = []

    for path in dataset_root.rglob("signals.csv"):
        if OUTPUT_FOLDER_NAME in path.parts:
            continue
        provenance = parse_experiment_path(dataset_root, path)
        discovered.append((path, provenance))

    discovered.sort(
        key=lambda item: (
            item[1]["meteo_source"],
            scenario_sort_key(item[1]["scenario_id"]),
            experiment_sort_key(item[1]["experiment_id"]),
            item[1]["real_day"],
            str(item[0]),
        )
    )

    if not discovered:
        raise FileNotFoundError(f"No generated signals.csv files found under: {dataset_root}")

    return discovered


def read_header(csv_path: Path) -> list[str]:
    with csv_path.open("r", newline="", encoding="utf-8-sig") as handle:
        reader = csv.reader(handle)
        try:
            header = next(reader)
        except StopIteration as exc:
            raise ValueError(f"Empty CSV file: {csv_path}") from exc

    missing = [column for column in REQUIRED_SIGNAL_COLUMNS if column not in header]
    if missing:
        raise ValueError(f"Missing required column(s) {missing} in {csv_path}")

    return header


def build_union_header(files: list[tuple[Path, dict[str, str]]]) -> list[str]:
    observed: list[str] = []
    observed_set: set[str] = set()

    for csv_path, _ in files:
        for column in read_header(csv_path):
            if column not in observed_set:
                observed.append(column)
                observed_set.add(column)

    signal_columns: list[str] = []
    for column in PREFERRED_SIGNAL_COLUMNS:
        if column in observed_set:
            signal_columns.append(column)

    for column in observed:
        if column not in signal_columns:
            signal_columns.append(column)

    return IDENTIFIER_COLUMNS + signal_columns


def consolidate(
    files: list[tuple[Path, dict[str, str]]],
    output_path: Path,
    overwrite: bool,
) -> tuple[int, int]:
    if output_path.exists() and not overwrite:
        raise FileExistsError(
            f"Output already exists: {output_path}\nUse --overwrite to replace it."
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    header = build_union_header(files)
    signal_columns = header[len(IDENTIFIER_COLUMNS) :]

    total_rows = 0

    with output_path.open("w", newline="", encoding="utf-8") as output_handle:
        writer = csv.DictWriter(output_handle, fieldnames=header, extrasaction="ignore")
        writer.writeheader()

        for index, (csv_path, provenance) in enumerate(files, start=1):
            with csv_path.open("r", newline="", encoding="utf-8-sig") as input_handle:
                reader = csv.DictReader(input_handle)
                if reader.fieldnames is None:
                    raise ValueError(f"CSV header missing: {csv_path}")

                missing = [
                    column for column in REQUIRED_SIGNAL_COLUMNS if column not in reader.fieldnames
                ]
                if missing:
                    raise ValueError(f"Missing required column(s) {missing} in {csv_path}")

                for row in reader:
                    output_row = {column: "" for column in header}
                    output_row.update(provenance)
                    for column in signal_columns:
                        if column in row:
                            output_row[column] = row[column]
                    writer.writerow(output_row)
                    total_rows += 1

            print(f"[{index}/{len(files)}] Added {csv_path}")

    return len(files), total_rows


def main() -> int:
    args = parse_args()
    script_root = Path(__file__).resolve().parent

    dataset_root = (
        args.dataset_root.resolve()
        if args.dataset_root is not None
        else (script_root / DATASET_FOLDER_NAME).resolve()
    )

    output_path = (
        args.output.resolve()
        if args.output is not None
        else dataset_root / OUTPUT_FOLDER_NAME / OUTPUT_FILE_NAME
    )

    try:
        files = discover_signal_files(dataset_root)
        n_files, n_rows = consolidate(files, output_path, args.overwrite)
    except (FileNotFoundError, FileExistsError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print("\nConsolidation completed.")
    print(f"Experiment CSV files: {n_files}")
    print(f"Rows written: {n_rows}")
    print(f"Output: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
