# Input meteorological data requirements

The generator uses two public meteorological sources and does not redistribute their raw files.

## Pamplona, Colombia

Mendeley Data DOI: `10.17632/z9sp7hmg5p.1`

Recommended local folder:

```text
real_meteorological_time_series/Pamplona_Colombia/
```

The generator recursively searches this source for `.csv`, `.txt` and `.dat` files and attempts to identify the required datetime, irradiance, temperature and humidity variables.

## Verney, Portugal

Mendeley Data DOI: `10.17632/m26hk4ysvz.1`

Recommended local folder:

```text
real_meteorological_time_series/Verney_Portugal/
```

The source contains several recording intervals. The generator selects one-minute `.dat` records and ignores files corresponding to 10, 60 and 1440 minute intervals.

## Alternative input location

If the raw meteorological data are not stored inside the repository, define their common parent folder before running the generator:

```matlab
setenv('PV_METEO_DATA_ROOT', 'D:\path\to\real_meteorological_time_series')
```

That folder must contain recognizable Pamplona and Verney source directories.
