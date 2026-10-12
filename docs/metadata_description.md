# Experiment metadata

Each generated experiment contains a `metadata.json` file next to `signals.csv`.

The metadata record is constant for the corresponding simulated daily trajectory and includes the main provenance and simulation descriptors used by the generator.

Key groups include:

- `scenario_id`, `scenario_index`, `experiment_id`, `experiment_label`;
- number of exported samples and current channels;
- meteorological source identifier and real calendar day;
- original measured start and end timestamps;
- original median sampling interval and number of source samples;
- meteorological resampling method and simulated segment duration;
- daylight descriptors derived from the measured profile;
- irradiance preprocessing and Simulink numerical-protection parameters;
- scenario-specific fault type, activation time and severity/resistance parameters where applicable.

The `current_signals` field records the current channels exported for that experiment. In `F8`, this includes three current-channel pairs.
