# Output dataset structure

The MATLAB generator writes its outputs under:

```text
Real_Weather_PhysicsBased_PV_Fault_Datasets/
```

Each successful simulation is stored as:

```text
<Meteorological_Source>/
    <Scenario>/
        <Experiment>/
            <Year>/
                <YYYY-MM-DD>/
                    signals.csv
                    metadata.json
```

## `signals.csv`

Common columns are:

- `datetime`: timestamp associated with the real measured day after resampling;
- `time_s`: elapsed seconds from the beginning of the measured daily segment;
- `IR`: quality-controlled measured irradiance in W/m²;
- `T`: measured/resampled ambient temperature;
- `H`: measured/resampled humidity;
- `low_irradiance_flag`: logical indicator for low-irradiance samples.

For most scenarios, the electrical columns are:

```text
I1
I1_Neg
I2
I2_Neg
```

The `F8` inter-string short-circuit scenario exports three current channels because two strings participate in the abnormal interaction and one unaffected string is retained as reference:

```text
I1
I1_Neg
I2
I2_Neg
I3
I3_Neg
```

If the generator exports an additional scenario-specific measurement column, it is preserved by the CSV consolidation utility.

## Consolidated CSV

Running:

```bash
python build_pv_fault_dataset.py --overwrite
```

creates:

```text
Real_Weather_PhysicsBased_PV_Fault_Datasets/Consolidated_Dataset/pv_fault_dataset_real_weather.csv
```

The utility preserves the union of the generated signal columns and adds:

```text
meteo_source
scenario_id
experiment_id
real_day
```

The consolidation is streamed to disk rather than loading the complete dataset into memory.
