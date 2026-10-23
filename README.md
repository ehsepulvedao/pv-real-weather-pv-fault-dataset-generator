# PV Real-Weather Fault Dataset Generator

This repository contains the MATLAB/Simulink workflow used to generate a semi-synthetic photovoltaic fault dataset from **real measured meteorological time series** and controlled photovoltaic fault simulations.

The meteorological inputs come from public datasets. The electrical fault responses and labels are produced by the photovoltaic scenario models maintained in the separate [PV Simulink Fault Scenario Models](https://github.com/ehsepulvedao/pv-simulink-fault-scenario-models) repository.

## What you need

To reproduce the dataset, you need:

1. this generator repository;
2. the separate Simulink model repository;
3. the two public meteorological datasets described below;
4. MATLAB/Simulink R2025b and the MATLAB products required by the model repository.

Parallel Computing Toolbox is optional. If it is unavailable, the generator can run serially.

Python 3.10+ is required only if you want to concatenate all generated experiment CSV files into one CSV. The provided Python script uses only the Python standard library.

## Recommended local folder layout

The simplest setup is to keep the generator and model repositories next to each other and place the meteorological data inside the generator repository:

```text
workspace/
    pv-real-weather-pv-fault-dataset-generator/
        pv_fault_dataset_generator.m
        build_pv_fault_dataset.py
        real_meteorological_time_series/
            Pamplona_Colombia/
            Verney_Portugal/

    pv-simulink-fault-scenario-models/
```

The raw meteorological files are local inputs and are not included in this repository.

If the model repository or meteorological data are stored elsewhere, the paths can be supplied without editing the generator:

```matlab
setenv('PV_MODEL_REPOSITORY', 'D:\path\to\pv-simulink-fault-scenario-models')
setenv('PV_METEO_DATA_ROOT', 'D:\path\to\real_meteorological_time_series')
```

## Meteorological input datasets

The generator uses two public Mendeley Data sources:

1. **Pamplona, Colombia**  
   DOI: [`10.17632/z9sp7hmg5p.1`](https://doi.org/10.17632/z9sp7hmg5p.1)

2. **Verney, Portugal**  
   DOI: [`10.17632/m26hk4ysvz.1`](https://doi.org/10.17632/m26hk4ysvz.1)

Download the original data from Mendeley Data and place them under:

```text
real_meteorological_time_series/
    Pamplona_Colombia/
    Verney_Portugal/
```

For the Verney dataset, the generator uses the one-minute `.dat` records and ignores the coarser 10, 60 and 1440 minute files.

More details are provided in `docs/input_data_requirements.md`.

## Generate the dataset

Open MATLAB in the root of this repository and run:

```matlab
pv_fault_dataset_generator
```

Before starting the simulations, the script checks the meteorological folders, the external model repository and the common model parameter file.

### Main configuration variables

The public defaults are defined near the beginning of `pv_fault_dataset_generator.m`:

```matlab
force_parallel = true;
max_simulations_per_batch = 5;
n_fault_variants_per_scenario = 5;
max_real_meteo_days_per_dataset_to_use = Inf;
scenarios_to_run = {'ALL'};
Ts_data = 1;
real_meteo_interpolation_method = 'linear';
```

For a quick smoke test, for example:

```matlab
scenarios_to_run = {'F0'};
max_real_meteo_days_per_dataset_to_use = 2;
force_parallel = false;
```

Restore the default configuration before generating the complete dataset.

## How real-weather days are used

Each meteorological source is processed independently and split by **real calendar day**.

The generator preserves the measured interval of each day. It does not reconstruct missing hours and does not force every record to span 00:00 to 23:59. The available measurements are resampled to 1 s only inside the interval actually present in the source data.

For each scenario, the generator creates fixed fault-severity experiment templates. The same `experiment_NN` severity configuration is reused across the selected real days and across both meteorological sources. Fault activation time is adapted to the daylight interval available for the corresponding measured day.

### Meteorological preprocessing

Before one-second resampling, negative irradiance values are clipped to 0 W/m² because they represent non-physical night-time sensor offsets. The resulting quality-controlled measured irradiance is the value exported in the `IR` column.

For numerical protection inside Simulink, a separate irradiance signal with a small positive floor is used when required by the PV Array blocks. This internal numerical signal does not replace the exported measured irradiance.

The generated CSV also includes `low_irradiance_flag` to identify samples at or below the configured low-irradiance threshold.

The full preprocessing policy is documented in `docs/preprocessing_policy.md`.

## Generated dataset structure

The MATLAB generator writes the dataset under:

```text
Real_Weather_PhysicsBased_PV_Fault_Datasets/
```

The generated hierarchy is:

```text
Real_Weather_PhysicsBased_PV_Fault_Datasets/
    <Meteorological_Source>/
        <Scenario>/
            <Experiment>/
                <Year>/
                    <YYYY-MM-DD>/
                        signals.csv
                        metadata.json
```

For example:

```text
Real_Weather_PhysicsBased_PV_Fault_Datasets/
    Verney_Portugal/
        F8/
            experiment_03/
                2023/
                    2023-12-15/
                        signals.csv
                        metadata.json
```

### Experiment CSV files

Each `signals.csv` contains the common measured-time and meteorological variables:

```text
datetime
time_s
IR
T
H
low_irradiance_flag
```

`IR` and `T` are the environmental variables supplied to the photovoltaic simulation models.  
`H`, when available in the source records, is resampled to the exported time grid and retained as contextual meteorological information; it is **not used as an input** by the photovoltaic simulation models.

For most scenarios, two string-current channels are exported: one affected string and one simultaneously simulated healthy reference string. Positive- and negative-polarity signals are stored separately:

```text
I1
I1_Neg
I2
I2_Neg
```

The inter-string short-circuit scenario (`F8`) involves two affected strings. Its experiment CSV files therefore contain three string-current channels: the two affected strings and one unaffected reference string:

```text
I1
I1_Neg
I2
I2_Neg
I3
I3_Neg
```

The exact column organization is documented in `docs/output_dataset_structure.md`.

### Experiment metadata

Each `metadata.json` records the information required to interpret the corresponding experiment, including the meteorological source and real day, measured interval, resampling information, scenario and experiment identifiers, exported current channels, and scenario-specific fault parameters.

See `docs/metadata_description.md` for the main fields.

## Optional consolidated CSV

The individual `signals.csv` files are the direct outputs of the MATLAB workflow. To concatenate all generated experiments into a single flat CSV, run from the repository root:

```bash
python build_pv_fault_dataset.py --overwrite
```

The output is:

```text
Real_Weather_PhysicsBased_PV_Fault_Datasets/
    Consolidated_Dataset/
        pv_fault_dataset_real_weather.csv
```

The consolidated file preserves the raw columns and adds four provenance columns to every row:

```text
meteo_source
scenario_id
experiment_id
real_day
```

Because `F8` contains a third current channel, the consolidated CSV includes `I3` and `I3_Neg`; these fields are empty for experiments that do not export them.

The consolidation is streamed file by file so that the complete dataset does not need to be loaded into memory at once.

## Reproduce the complete dataset

1. Clone or download this repository.
2. Clone or download the [model repository](https://github.com/ehsepulvedao/pv-simulink-fault-scenario-models).
3. Download the two meteorological datasets from Mendeley Data.
4. Place them under `real_meteorological_time_series/`, or set `PV_METEO_DATA_ROOT`.
5. Open MATLAB R2025b in this repository.
6. Keep `scenarios_to_run = {'ALL'}` and `max_real_meteo_days_per_dataset_to_use = Inf`.
7. Run `pv_fault_dataset_generator`.
8. Optionally run `python build_pv_fault_dataset.py --overwrite` to create the single consolidated CSV.

## Associated dataset and article

The publication dataset generated with this workflow is deposited in **Recherche Data Gouv – CNRS Research Data**.

**Dataset title:** *Real-weather-driven labelled photovoltaic fault-diagnosis time series from physics-based simulations*  
**Reserved dataset DOI:** [https://doi.org/10.57745/FTAGKB](https://doi.org/10.57745/FTAGKB)

The dataset DOI has been reserved by Recherche Data Gouv and will become active when the dataset is published after completion of the curation process.

**Associated Data in Brief article:** *A labelled semi-synthetic photovoltaic fault diagnosis dataset driven by real meteorological data and physics-based simulations*  
**Article DOI:** `[TO BE ADDED AFTER PUBLICATION]`

## Citation

If you use this generator or the released data, please cite the software repository, the dataset record, and the associated Data in Brief article once the article DOI is available.

Suggested software repository citation:

```text
E.H. Sepúlveda-Oviedo, PV Real-Weather Fault Dataset Generator, GitHub repository, 2026.
https://github.com/ehsepulvedao/pv-real-weather-pv-fault-dataset-generator
```

Dataset citation:

```text
E.H. Sepúlveda-Oviedo, Real-weather-driven labelled photovoltaic fault-diagnosis time series from physics-based simulations,
Recherche Data Gouv, 2026. https://doi.org/10.57745/FTAGKB
```

Associated article:

```text
E.H. Sepúlveda-Oviedo, A labelled semi-synthetic photovoltaic fault diagnosis dataset driven by real meteorological data
and physics-based simulations, Data in Brief, [YEAR], [ARTICLE DOI TO BE ADDED AFTER PUBLICATION].
```

A machine-readable software citation is provided in `CITATION.cff`.

## License

This repository is released under the MIT License. See `LICENSE`.

## Disclaimer

This generator is provided for research and educational purposes. The generated data are intended for controlled photovoltaic fault-diagnosis studies and require additional validation before safety-critical or operational use.
