# Meteorological preprocessing and numerical protection

The generator is designed to preserve the measured temporal support of each real calendar day while making the meteorological inputs compatible with fixed-step Simulink execution.

## Daily segmentation

Records are split by real calendar date. The generator does not fill missing hours or force a 00:00–23:59 interval. Resampling is performed only within the interval actually present in the source record.

## Resampling

The default exported time step is 1 s and the default interpolation method is linear.

## Irradiance

Negative irradiance values in the source data are treated as non-physical night-time sensor offsets and clipped to 0 W/m² before resampling. The exported `IR` column therefore represents the quality-controlled measured irradiance.

A separate internal irradiance profile is used for Simulink numerical protection. When necessary, this internal signal uses a small positive floor to avoid singularities in PV Array blocks at exactly zero irradiance. The protected internal signal is not exported as `IR`.

## Temperature and humidity

Physically plausible negative ambient temperatures are retained. Non-finite or clearly out-of-range values are protected internally before being passed to Simulink; the exported meteorological profiles remain as close as possible to the measured/resampled source data.

## Electrical outputs

Electrical currents are exported as returned by Simulink by default. They are not converted to absolute values and are not automatically forced to zero at night. The `low_irradiance_flag` column identifies samples at or below the configured low-irradiance threshold.
