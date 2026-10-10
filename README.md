# PV Real-Weather Fault Dataset Generator

This repository contains the MATLAB generator used to create a real-weather-driven photovoltaic fault diagnosis dataset from public meteorological time series and scenario-specific MATLAB/Simulink photovoltaic fault models.

The generator processes each meteorological source independently, splits the records by real measured calendar day, injects the measured meteorological profiles into photovoltaic fault scenario models, and exports diagnosis-ready experiment folders.

## Repository scope

This repository is dedicated to the dataset generation workflow.

It includes the MATLAB script used for:

- loading public real meteorological time series;
- splitting the records into real measured days;
- interpolating meteorological profiles inside the measured interval;
- running scenario-specific Simulink photovoltaic models;
- applying fixed fault-severity experiment templates;
- exporting daily `signals.csv` files;
- exporting experiment-level `metadata.json` files;
- documenting the preprocessing and numerical protection policies.

This repository does not include:

- the generated dataset files;
- the raw meteorological source datasets;
- the MATLAB/Simulink `.slx` model files;
- local logs;
- Simulink cache folders;
- generated code folders;
- temporary MATLAB files.

The MATLAB/Simulink photovoltaic fault scenario models are maintained separately in the model repository:

[https://github.com/ehsepulvedao/pv-simulink-fault-scenario-models](https://github.com/ehsepulvedao/pv-simulink-fault-scenario-models)

## Main script

The main generator script is:

```text
pv_fault_dataset_generator.m
```

The script expects a local project structure containing:

```text
project_root/
    pv_fault_dataset_generator.m
    power_PVarray_250kW_param.m
    Models/
        F0_healthy/
        F1_open_circuit/
        F2_intra_string_short/
        F3_ground_fault/
        F4_partial_shading/
        F5_progressive_degradation/
        F6_intermittent_short/
        F7_arc_fault/
        F8_inter_string_short/
        F9_module_mismatch/
        F10_high_resistance_connection/
        F11_combined_fault/
    real_meteorological_time_series/
        Pamplona_Colombia/
        Verney_Portugal/
```

The `Models/` folder should contain the Simulink models from the separate model repository.

## Software requirements

The workflow was prepared for:

- MATLAB R2025b
- Simulink
- Simscape Electrical / Specialized Power Systems, if required by the local model installation
- Parallel Computing Toolbox, optional but recommended for batch execution

Compatibility with older MATLAB releases is not guaranteed.

## Input meteorological datasets

The generator uses two public Mendeley Data sources:

1. Pamplona, Colombia source dataset  
   DOI: [`10.17632/z9sp7hmg5p.1`](https://doi.org/10.17632/z9sp7hmg5p.1)

2. Verney, Portugal source dataset  
   DOI: [`10.17632/m26hk4ysvz.1`](https://doi.org/10.17632/m26hk4ysvz.1)

The raw meteorological datasets are not included in this repository. They must be downloaded from their original repositories and placed locally under:

```text
real_meteorological_time_series/
```

The generator looks for folders such as:

```text
real_meteorological_time_series/Pamplona_Colombia/
real_meteorological_time_series/Verney_Portugal/
```

For the Verney source, the generator selects one-minute `.dat` files and ignores coarser time intervals such as 10, 60 and 1440 minutes.

## Simulink model dependency

The generator expects the following scenario labels and model names:

| Label | Scenario folder | Simulink model |
|---|---|---|
| `F0` | `F0_healthy` | `pv_model_F0_healthy` |
| `F1` | `F1_open_circuit` | `pv_model_F1_open_circuit` |
| `F2` | `F2_intra_string_short` | `pv_model_F2_intra_string_short` |
| `F3` | `F3_ground_fault` | `pv_model_F3_ground_fault` |
| `F4` | `F4_partial_shading` | `pv_model_F4_partial_shading` |
| `F5` | `F5_progressive_degradation` | `pv_model_F5_progressive_degradation` |
| `F6` | `F6_intermittent_short` | `pv_model_F6_intermittent_short` |
| `F7` | `F7_arc_fault` | `pv_model_F7_arc_fault` |
| `F8` | `F8_inter_string_short` | `pv_model_F8_inter_string_short` |
| `F9` | `F9_module_mismatch` | `pv_model_F9_module_mismatch` |
| `F10` | `F10_high_resistance_connection` | `pv_model_F10_high_resistance_connection` |
| `F11` | `F11_combined_fault` | `pv_model_F11_combined_fault` |

## Generated dataset structure

The generator writes the output dataset to:

```text
Real_Weather_PhysicsBased_PV_Fault_Datasets/
```

The generated folders follow the structure:

```text
Real_Weather_PhysicsBased_PV_Fault_Datasets/
    Meteorological_Source/
        Fault_Scenario/
            Experiment_Label/
                Year/
                    YYYY-MM-DD/
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

## Output files

Each successful simulation creates one experiment folder with:

```text
signals.csv
metadata.json
```

The `signals.csv` file stores time-dependent variables such as:

- `datetime`
- `time_s`
- `IR`
- `T`
- `H`
- `low_irradiance_flag`
- current signals such as `I1`, `I1_Neg`, `I2`, `I2_Neg`
- additional current signals when required by a scenario

The `metadata.json` file stores constant descriptors such as:

- scenario label;
- experiment label;
- meteorological source;
- real measured day;
- original measured interval;
- interpolation method;
- fault type;
- fault parameters;
- current signals exported;
- preprocessing policy;
- numerical protection policy.

## Methodological policy

The generator preserves the measured duration of each real day. It does not reconstruct missing hours and does not force an artificial full-day interval from 00:00 to 23:59.

Negative irradiance values in the raw meteorological source are interpreted as non-physical night-time sensor offsets and are clipped to 0 W/m² before one-second resampling.

The exported `IR` column stores the quality-controlled measured irradiance. It is not replaced by the numerical irradiance floor used internally by Simulink.

For Simulink numerical protection, a separate internal irradiance profile with a small positive floor is used to avoid singularities in PV Array blocks during zero-irradiance samples. This protected internal signal is not exported as the `IR` column.

Electrical currents are exported as returned by Simulink by default. They are not converted to absolute values and are not forced to zero. A `low_irradiance_flag` is added to identify night-time or near-zero irradiance samples.

## Fixed severity templates

For each diagnostic scenario, the generator creates fixed experiment templates. Each `experiment_NN` corresponds to one fixed set of scenario parameters and is reused across all selected real measured days and meteorological sources.

Only the fault activation time is adapted to the available measured daylight interval of each day.

## Basic use

1. Clone or download this repository.
2. Clone or download the separate model repository.
3. Place the Simulink models under the local `Models/` folder.
4. Download the meteorological source datasets from Mendeley Data.
5. Place the meteorological files under `real_meteorological_time_series/`.
6. Open MATLAB R2025b.
7. Set the repository folder as the MATLAB working directory.
8. Run:

```matlab
pv_fault_dataset_generator
```

## Important configuration variables

The main configuration variables are defined near the beginning of the script:

```matlab
dataset_folder_name = 'Real_Weather_PhysicsBased_PV_Fault_Datasets';
models_root = fullfile(project_root, 'Models');
output_root = fullfile(project_root, dataset_folder_name);

force_parallel = true;
max_simulations_per_batch = 5;
n_fault_variants_per_scenario = 5;
max_real_meteo_days_per_dataset_to_use = Inf;
scenarios_to_run = {'ALL'};
Ts_data = 1;
real_meteo_interpolation_method = 'linear';
```

For smoke tests, `max_real_meteo_days_per_dataset_to_use` can be set to a small value and `scenarios_to_run` can be set to a subset such as:

```matlab
scenarios_to_run = {'F0'};
max_real_meteo_days_per_dataset_to_use = 2;
```

## Recommended repository files

A clean repository may include:

```text
README.md
LICENSE
CITATION.cff
.gitignore
pv_fault_dataset_generator.m
docs/
    input_data_requirements.md
    output_dataset_structure.md
    metadata_description.md
    preprocessing_policy.md
    quality_control_policy.md
examples/
    example_project_tree.txt
    example_smoke_test_configuration.m
```

## Files and folders that should not be committed

Do not commit:

```text
Real_Weather_PhysicsBased_PV_Fault_Datasets/
real_meteorological_time_series/
Models/
simulink_cache/
simulink_codegen/
slprj/
*.slxc
*.asv
*.autosave
overnight_generation_log_*.txt
*.log
```

## Citation

If you use this generator, please cite the associated data article when available.

Suggested repository citation:

```text
E.H. Sepúlveda-Oviedo, PV Real-Weather Fault Dataset Generator, GitHub repository, 2026.
https://github.com/ehsepulvedao/pv-real-weather-pv-fault-dataset-generator
```

Associated data article:

```text
E.H. Sepúlveda-Oviedo, A hybrid real-weather-driven and physics-based dataset for labelled photovoltaic fault diagnosis, Data in Brief, 2026. [To be completed after publication]
```

## License

This repository is released under the MIT License.

## Disclaimer

This generator is provided for research and educational purposes. The generated data are intended for controlled photovoltaic fault diagnosis studies and should not be used directly for safety-critical design, protection certification or operational maintenance decisions without additional validation.
