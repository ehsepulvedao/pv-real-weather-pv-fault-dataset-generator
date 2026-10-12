% =========================================================
% Author      : Edgar Hernando Sepulveda Oviedo
% Year        : 2026
% File        : pv_fault_dataset_generator.m
% Version     : 1.0.0
% Description : Semi-synthetic photovoltaic fault dataset generator using
%               scenario-based Simulink models and real meteorological
%               time series from public Mendeley Data datasets.
%
% Repository note:
% This generator processes each meteorological source independently and by
% real calendar day:
%
%   dataset source -> fault scenario -> fault severity experiment -> real measured day
%
% The two source datasets are never mixed in the same execution loop. 
% https://data.mendeley.com/datasets/z9sp7hmg5p/1
% https://data.mendeley.com/datasets/m26hk4ysvz/1
% 
% The script first completes all selected scenarios for Pamplona_Colombia and then completes
% all selected scenarios for Verney_Portugal. Within each scenario, the same
% experiment_NN parameters are applied to all selected real days; only the fault
% start time is adapted to the measured daylight interval of each day.
%
% Each successful simulation creates one experiment folder containing:
%   - signals.csv    : time-dependent signals only
%   - metadata.json  : compact constant descriptors and fault parameters
%
% Important design choice:
% A "day" means the real samples belonging to that calendar date. The script does
% NOT reconstruct missing hours. If the first Pamplona day starts at
% 2025-11-12 14:05:33, the exported signals.csv starts at 2025-11-12 14:05:33.
% If a day ends at 23:59:31, it ends there. No artificial 00:00 -> 23:59
% forcing is applied. The only resampling operation is interpolation to
% Ts_data = 1 s inside the measured interval of that real day.
% =========================================================

clc;
clear;
close all;
format short

%% ========================================================
% PROJECT ROOT
% =========================================================

script_path = mfilename('fullpath');
if isempty(script_path)
    project_root = pwd;
else
    project_root = fileparts(script_path);
end

% External Simulink model dependency. By default, the model repository is
% expected as a sibling of this generator repository. The location can be
% overridden without editing this script by setting PV_MODEL_REPOSITORY.
model_repository_root = getenv('PV_MODEL_REPOSITORY');
if isempty(model_repository_root)
    model_repository_root = fullfile( ...
        fileparts(project_root), 'pv-simulink-fault-scenario-models');
end

if ~exist(model_repository_root, 'dir')
    error([ ...
        'Model repository not found:\n%s\n\n' ...
        'Clone pv-simulink-fault-scenario-models next to this generator repository, ' ...
        'or define PV_MODEL_REPOSITORY with its local path.'], ...
        model_repository_root);
end

% Real meteorological data are local inputs and are intentionally not versioned
% with this repository. By default they are expected under
% ./real_meteorological_time_series. PV_METEO_DATA_ROOT can point elsewhere.
meteo_root = getenv('PV_METEO_DATA_ROOT');
if isempty(meteo_root)
    meteo_root = fullfile(project_root, 'real_meteorological_time_series');
end

%% ========================================================
% LOG FILE
% =========================================================

log_file = fullfile(project_root, ...
    ['overnight_generation_log_' datestr(now,'yyyymmdd_HHMMSS') '.txt']);

diary(log_file);
diary on;

fprintf('\n=================================================\n');
fprintf('LOG FILE ACTIVATED\n');
fprintf('=================================================\n');
fprintf('Log file: %s\n', log_file);
fprintf('Started at: %s\n', datestr(now));
fprintf('=================================================\n');

%% ========================================================
% GENERAL CONFIGURATION
% =========================================================

dataset_folder_name = 'Real_Weather_PhysicsBased_PV_Fault_Datasets';
output_root = fullfile(project_root, dataset_folder_name);
simulink_work_root = fullfile(project_root, '.simulink_work');

if ~exist(simulink_work_root, 'dir')
    mkdir(simulink_work_root);
end

% Use true to run batches with parsim when the Parallel Computing Toolbox is available.
force_parallel = true;

% Number of SimulationInput objects prepared per batch. This controls memory,
% not the number of workers. parsim distributes the batch over the available pool.
max_simulations_per_batch = 5;

% Number of fixed fault-severity experiments generated for each scenario.
n_fault_variants_per_scenario = 3;

% For smoke tests, use a small number such as 2. For the complete dataset use Inf.
% This limit is applied independently to each meteorological source dataset.
max_real_meteo_days_per_dataset_to_use = Inf;

% Set {'ALL'} for the complete dataset, or for example {'F0'} for a smoke test.
scenarios_to_run = {'ALL'};

% Arc-fault enriched measurement. Set [] to disable.
target_arc_string = 50;

% Fixed output sampling time after meteorological resampling.
Ts_data = 1;

% Interpolation method used to convert measured meteorology to 1 s.
real_meteo_interpolation_method = 'linear';
% =========================================================
% FULL-DAY QUALITY-CONTROL AND NUMERICAL PROTECTION POLICY
% =========================================================
% The final dataset must preserve the full measured meteorological day, including
% night-time samples. Therefore, the script DOES NOT crop the night and DOES NOT
% remove samples with IR = 0 W/m2.
%
% Scientific/export policy:
%   - Negative irradiance values in the raw meteorological source are interpreted
%     as sensor offset/noise around night-time zero irradiance.
%   - Those negative irradiance values are clipped to exactly 0 W/m2 BEFORE the
%     1-second resampling step. This avoids creating extra negative values during
%     linear interpolation between positive and negative noisy samples.
%   - signals.csv stores this quality-controlled, resampled irradiance. It is
%     still a measured meteorological signal, but with the physically meaningless
%     negative irradiance offsets removed.
%   - The exported IR column is NOT replaced by the Simulink numerical floor.
%   - Physically plausible negative ambient temperatures are preserved.
%
% Simulink numerical policy:
%   - Some Simulink PV Array blocks may become singular when their irradiance
%     input is exactly 0 W/m2, especially in faulted topologies.
%   - To protect the PV Array blocks, Simulink receives a separate internal
%     irradiance signal with a very small positive numerical floor.
%   - This protected internal signal is NOT exported as the IR column.
%   - Electrical currents are exported as returned by Simulink by default; they
%     are NOT converted to absolute values and are NOT forced to zero. A
%     low_irradiance_flag is added to the CSV to identify night/near-zero
%     irradiance samples for later analysis.
%
% This is intentionally documented here because it is an important methodological
% choice for any future paper describing the semi-synthetic dataset.
IR_floor_for_simulink_Wm2 = 0.1;

% Threshold used only to tag night-time / very-low-irradiance samples in the
% exported CSV. It is not used as the Simulink floor. It is a diagnostic flag
% for downstream filtering or analysis.
IR_low_irradiance_threshold_Wm2 = 5.0;

% For the main scientific dataset, keep the electrical currents exactly as they
% are returned by Simulink. Do not take abs(I) and do not force night-time
% currents to zero. The low_irradiance_flag allows these periods to be identified.
zero_electrical_outputs_below_IR_floor = false;

% Kept for backward compatibility with metadata/save logic. It has the same
% value as the low-irradiance flag threshold, but current zeroing is disabled.
IR_output_zero_threshold_Wm2 = IR_low_irradiance_threshold_Wm2;

temperature_min_physical_degC = -40;
temperature_max_physical_degC = 85;


% Do not save or overwrite Simulink models.
save_model_configuration = false;

% Console verbosity for CSV writing.
verbose_save = false;

rng(2026);

if ~exist(output_root, 'dir')
    mkdir(output_root);
end
writeSemiSyntheticSourceDescription(output_root);

%% ========================================================
% SOURCE METEOROLOGICAL DATASETS
% =========================================================

pamplona_source = resolveExistingPath(meteo_root, { ...
    fullfile(meteo_root, 'Pamplona_Colombia'), ...
    fullfile(meteo_root, 'Pamplona,Colombia'), ...
    fullfile(meteo_root, 'Pamplona Colombia'), ...
    fullfile(meteo_root, 'Pamplona') ...
}, {'pamplona','colombia'});

verney_source = resolveExistingPath(meteo_root, { ...
    fullfile(meteo_root, 'Verney_Portugal'), ...
    fullfile(meteo_root, 'Verney,Portugal'), ...
    fullfile(meteo_root, 'Verney Portugal'), ...
    fullfile(meteo_root, 'Verney'), ...
    fullfile(meteo_root, 'Portugal') ...
}, {'verney','portugal'});

if exist(pamplona_source, 'dir') ~= 7
    error('Pamplona meteorological source folder not found under: %s', meteo_root);
end
if exist(verney_source, 'dir') ~= 7
    error('Verney meteorological source folder not found under: %s', meteo_root);
end

meteo_dataset_files = {pamplona_source, verney_source};
meteo_dataset_labels = {'Pamplona_Colombia', 'Verney_Portugal'};

%meteo_dataset_files = {verney_source};
%meteo_dataset_labels = {'Verney_Portugal'};

%% ========================================================
% SIMULINK MODELS ORGANIZATION
% =========================================================

models_root = fullfile(model_repository_root, 'Models');
parameter_file = fullfile(model_repository_root, 'power_PVarray_250kW_param.m');

if ~exist(models_root, 'dir')
    error('Models folder not found in external model repository: %s', models_root);
end
if ~exist(parameter_file, 'file')
    error('Common model parameter file not found: %s', parameter_file);
end

% Make the external repository visible to Simulink callbacks. Some models call
% power_PVarray_250kW_param by name from PreLoadFcn.
addpath(model_repository_root);
addpath(models_root);
rehash path;

scenario_folder_map = containers.Map( ...
    {'F0','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11'}, ...
    {'F0_healthy', ...
     'F1_open_circuit', ...
     'F2_intra_string_short', ...
     'F3_ground_fault', ...
     'F4_partial_shading', ...
     'F5_progressive_degradation', ...
     'F6_intermittent_short', ...
     'F7_arc_fault', ...
     'F8_inter_string_short', ...
     'F9_module_mismatch', ...
     'F10_high_resistance_connection', ...
     'F11_combined_fault'});

scenario_model_map = containers.Map( ...
    {'F0','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11'}, ...
    {'pv_model_F0_healthy', ...
     'pv_model_F1_open_circuit', ...
     'pv_model_F2_intra_string_short', ...
     'pv_model_F3_ground_fault', ...
     'pv_model_F4_partial_shading', ...
     'pv_model_F5_progressive_degradation', ...
     'pv_model_F6_intermittent_short', ...
     'pv_model_F7_arc_fault', ...
     'pv_model_F8_inter_string_short', ...
     'pv_model_F9_module_mismatch', ...
     'pv_model_F10_high_resistance_connection', ...
     'pv_model_F11_combined_fault'});

scenario_numeric_map = containers.Map( ...
    {'F0','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11'}, ...
    {0,1,2,3,4,5,6,7,8,9,10,11});

scenario_label_map = containers.Map( ...
    {'F0','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11'}, ...
    {'healthy reference', ...
     'open circuit', ...
     'intra-string short circuit', ...
     'ground fault', ...
     'partial shading', ...
     'progressive degradation', ...
     'intermittent short circuit', ...
     'arc fault', ...
     'inter-string short circuit', ...
     'module mismatch', ...
     'high-resistance connection', ...
     'combined fault'});

fault_names = {'F0','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11'};
if ~isequal(scenarios_to_run, {'ALL'})
    fault_names = scenarios_to_run;
end
scenario_ids = fault_names;
n_faults = numel(scenario_ids);

%% ========================================================
% MODEL PARAMETERS
% =========================================================

run(parameter_file);

model_params = struct();
model_params.Ts_Power = Ts_Power;
model_params.Ts_Control = Ts_Control;
model_params.Rload_day = Rload_day;
model_params.Fnom = Fnom;
model_params.Vnom_dc = Vnom_dc;

if ~exist('tfinal', 'var') || isempty(tfinal)
    tfinal = 86400;
end

%% ========================================================
% NOMINAL FAULT PARAMETERS
% =========================================================

base = struct();
base.RF1  = 1e4;
base.RF2  = 100;
base.RF3  = 0.1;
base.RF4  = 10;
base.RF5  = 100;
base.RF6  = 100;
base.RF7  = 1000;
base.RF8  = 50;
base.RF10 = 50;
base.RF11 = 5;
base.RF12 = 150;

base.timef0  = tfinal;
base.timef1  = 10.0 * 3600;
base.timef2  = 11.0 * 3600;
base.timef3  = 12.0 * 3600;
base.timef4  = 13.0 * 3600;
base.timef5  = 14.0 * 3600;
base.timef6  = 15.0 * 3600;
base.timef7  = 16.0 * 3600;
base.timef8  = 15.5 * 3600;
base.timef10 = 13.5 * 3600;
base.timef11 = 12.5 * 3600;
base.timef12 = 14.5 * 3600;

base.DEG_final = 0.10;
base.Pint   = 30;
base.Dint   = 10;
base.Pint12 = 40;
base.Dint12 = 10;

base.arc_episodes_rel_nominal = [ ...
      5    8
     15   18
     28   32
     40   44
     54   58
     63   67
     78   82
     92   96
    105  109];

base.mismatch_level = 'randomized';
base.module_mismatch_choice = 'randomized';

%% ========================================================
% CONFIGURATION SUMMARY
% =========================================================

fprintf('\n=================================================\n');
fprintf('GENERAL CONFIGURATION\n');
fprintf('=================================================\n');
fprintf('Model repository: %s\n', model_repository_root);
fprintf('Models root folder: %s\n', models_root);
fprintf('Meteorological data root: %s\n', meteo_root);
fprintf('Dataset root: %s\n', output_root);
fprintf('Data time step Ts_data: %.3f s\n', Ts_data);
fprintf('Number of scenarios: %d\n', n_faults);
fprintf('Fault severity experiments per scenario: %d\n', n_fault_variants_per_scenario);
fprintf('Max real meteo days per dataset: %s\n', valueToString(max_real_meteo_days_per_dataset_to_use));

%% ========================================================
% LOAD REAL METEOROLOGICAL DATASETS
% =========================================================

fprintf('\n=================================================\n');
fprintf('LOADING REAL METEOROLOGICAL DATASETS\n');
fprintf('=================================================\n');

meteo_database = loadRealMeteoDatasets( ...
    meteo_dataset_files, meteo_dataset_labels, ...
    real_meteo_interpolation_method, project_root);

n_available_days_total = 0;
for dset_idx = 1:numel(meteo_database.datasets)
    n_available_days_total = n_available_days_total + numel(meteo_database.datasets(dset_idx).segments);
end

fprintf('\nReadable meteorological datasets: %d\n', numel(meteo_database.datasets));
fprintf('Readable meteorological real days total: %d\n', n_available_days_total);

%% ========================================================
% PARALLEL EXECUTION SETUP
% =========================================================

use_parallel = false;
parallel_available = license('test', 'Distrib_Computing_Toolbox') && exist('gcp', 'file') == 2;

if force_parallel && parallel_available
    poolobj = gcp('nocreate');
    if isempty(poolobj)
        parpool;
    end
    use_parallel = true;
elseif force_parallel && ~parallel_available
    warning('Parallel Computing Toolbox is not available. Serial simulation will be used.');
else
    fprintf('Parallel execution disabled manually. Serial simulation will be used.\n');
end

%% ========================================================
% FIXED SEVERITY TEMPLATES
% =========================================================

% Each experiment_NN is created once per scenario and then reused across all
% meteorological datasets and all real days. Therefore, for example, F4 / 
% experiment_01 has the same shading severity in Pamplona and Verney. Only the
% fault activation time is adapted later to each measured day.
severity_template_bank = struct();
for template_s = 1:n_faults
    template_scenario_id = scenario_ids{template_s};
    template_cells = cell(n_fault_variants_per_scenario, 1);
    for variant_template_idx = 1:n_fault_variants_per_scenario
        template_params = generateExperimentParameters( ...
            base, template_scenario_id, scenario_numeric_map(template_scenario_id), variant_template_idx);
        template_params.experiment_label = sprintf('experiment_%02d', variant_template_idx);
        template_params.arc_string_index = target_arc_string;
        template_params = randomizeFaultSeverityTemplate(template_params, template_scenario_id);
        template_cells{variant_template_idx} = template_params;
    end
    severity_template_bank.(template_scenario_id) = template_cells;
end

%% ========================================================
% DATASET-BY-DATASET OPTION C GENERATION LOOP
% =========================================================

total_timer = tic;
completed_simulations = 0;
failed_simulations = 0;
total_planned_simulations = 0;

for dset_idx = 1:numel(meteo_database.datasets)

    current_dataset = meteo_database.datasets(dset_idx);
    dataset_label = current_dataset.label;
    dataset_days = current_dataset.segments;
    n_days_available = numel(dataset_days);

    if n_days_available == 0
        fprintf('\nDataset %s has no readable real days. Skipping.\n', dataset_label);
        continue
    end

    if isinf(max_real_meteo_days_per_dataset_to_use)
        selected_day_indices = 1:n_days_available;
    else
        selected_day_indices = 1:min(max_real_meteo_days_per_dataset_to_use, n_days_available);
    end

    dataset_experiment_plan = buildDatasetDailyExperimentPlan( ...
        selected_day_indices, n_fault_variants_per_scenario);

    n_experiments_for_dataset = numel(dataset_experiment_plan);
    planned_for_dataset = n_faults * n_experiments_for_dataset;
    total_planned_simulations = total_planned_simulations + planned_for_dataset;

    fprintf('\n===============================================================\n');
    fprintf('METEOROLOGICAL DATASET : %s\n', dataset_label);
    fprintf('===============================================================\n');
    fprintf('Source root: %s\n', current_dataset.source_root);
    fprintf('Readable real days available: %d\n', n_days_available);
    fprintf('Real days selected: %d\n', numel(selected_day_indices));
    fprintf('Day simulations per scenario in this dataset: %d\n', n_experiments_for_dataset);
    fprintf('Fixed severity experiments per scenario: %d\n', n_fault_variants_per_scenario);
    fprintf('Planned simulations for this dataset: %d\n', planned_for_dataset);

    for s = 1:n_faults
        scenario_id = scenario_ids{s};
        scenario_label = scenario_label_map(scenario_id);

        fprintf('\n---------------------------------------------------------------\n');
        fprintf('DATASET : %s | SCENARIO : %s - %s\n', dataset_label, scenario_id, scenario_label);
        fprintf('---------------------------------------------------------------\n');

        model_name = scenario_model_map(scenario_id);
        flat_model_file = fullfile(models_root, [model_name '.slx']);
        legacy_model_file = fullfile(models_root, scenario_folder_map(scenario_id), [model_name '.slx']);

        if exist(flat_model_file, 'file')
            model_file = flat_model_file;
        elseif exist(legacy_model_file, 'file')
            model_file = legacy_model_file;
        else
            error('Simulink model not found for %s. Expected under: %s', scenario_id, models_root);
        end

        model_folder = fileparts(model_file);
        scenario_work_folder = fullfile(simulink_work_root, scenario_id);
        simulink_cache_dir   = fullfile(scenario_work_folder, 'cache');
        simulink_codegen_dir = fullfile(scenario_work_folder, 'codegen');
        if ~exist(simulink_cache_dir, 'dir'); mkdir(simulink_cache_dir); end
        if ~exist(simulink_codegen_dir, 'dir'); mkdir(simulink_codegen_dir); end

        Simulink.fileGenControl('set', ...
            'CacheFolder', simulink_cache_dir, ...
            'CodeGenFolder', simulink_codegen_dir, ...
            'createDir', true);

        load_system(model_file);
        set_param(model_name, 'SimulationMode', 'normal');
        set_param(model_name, 'SolverType', 'Fixed-step');
        set_param(model_name, 'FixedStep', num2str(Ts_data));
        set_param(model_name, 'LoadInitialState', 'off');
        set_param(model_name, 'SaveFinalState', 'off');
        set_param(model_name, 'FastRestart', 'off');

        if save_model_configuration
            warning('save_model_configuration is true, but this script never saves Simulink models.');
        end

        % Reuse the fixed severity templates generated once for this scenario.
        severity_templates = severity_template_bank.(scenario_id);

        for batch_start = 1:max_simulations_per_batch:n_experiments_for_dataset

            batch_end = min(batch_start + max_simulations_per_batch - 1, n_experiments_for_dataset);
            batch_indices = batch_start:batch_end;
            n_batch = numel(batch_indices);

            fprintf('\nPreparing batch %d-%d of %d | Dataset: %s | Scenario: %s\n', ...
                batch_start, batch_end, n_experiments_for_dataset, dataset_label, scenario_id);

            simIn_batch = Simulink.SimulationInput.empty(n_batch, 0);
            for rr = 1:n_batch
                simIn_batch(rr, 1) = Simulink.SimulationInput(model_name);
            end

            params_list = cell(n_batch, 1);
            exp_folder_list = cell(n_batch, 1);
            t_profile_list = cell(n_batch, 1);
            datetime_profile_list = cell(n_batch, 1);
            IR_profile_list = cell(n_batch, 1);
            IR_profile_for_sim_list = cell(n_batch, 1);
            T_profile_list = cell(n_batch, 1);
            H_profile_list = cell(n_batch, 1);
            arc_hf_noise_list = cell(n_batch, 1);

            for rr = 1:n_batch
                local_experiment_index = batch_indices(rr);
                plan_entry = dataset_experiment_plan(local_experiment_index);

                day_idx = plan_entry.day_idx;
                variant_idx = plan_entry.variant_idx;
                day_segment = dataset_days(day_idx);

                exp_label = sprintf('experiment_%02d', variant_idx);

                % Start from the fixed severity template for this experiment.
                % This keeps the same fault resistance/severity/degradation level
                % across all real days. The call below only adapts the fault timing
                % to the available measured interval of the current day.
                params = severity_templates{variant_idx};
                params.experiment_id = variant_idx;
                params.experiment_label = exp_label;
                params.day_simulation_index = local_experiment_index;

                [t_profile, datetime_profile, IR_profile, T_profile, H_profile, meteo_params] = ...
                    buildRealMeteoVariant(day_segment, Ts_data, plan_entry);

                params = attachMeteoParams(params, meteo_params, local_experiment_index);
                params = assignFaultTimingForDay(params, scenario_id, meteo_params, Ts_data, t_profile(end));

                % =========================================================
                % QUALITY-CONTROLLED METEOROLOGICAL EXPORT + INTERNAL MODEL PROTECTION
                % =========================================================
                % The variables returned by buildRealMeteoVariant are the real
                % meteorological measurements after time alignment and interpolation
                % to Ts_data. At this point, irradiance has already been quality-
                % controlled at the source level: negative irradiance values were
                % clipped to 0 W/m2 BEFORE resampling.
                %
                % IMPORTANT SCIENTIFIC POLICY:
                %   - signals.csv stores the quality-controlled, resampled
                %     meteorological irradiance.
                %   - The IR column is NOT replaced by the Simulink numerical floor.
                %   - Currents are exported as returned by Simulink by default.
                %     No abs(I) and no night-time zero forcing are applied in the
                %     main dataset.
                %
                % Internal Simulink policy:
                %   - PV Array blocks may become singular when irradiance is exactly
                %     zero in some faulted topologies.
                %   - A separate non-exported signal, IR_profile_for_sim, is created
                %     only to protect the Simulink model.
                %
                % This separation avoids mixing two different notions:
                %   1) IR_profile_export   : quality-controlled measured irradiance
                %                            saved in signals.csv.
                %   2) IR_profile_for_sim  : protected internal Simulink input,
                %                            not exported as IR.

                IR_profile_export = IR_profile;
                T_profile_export  = T_profile;
                H_profile_export  = H_profile;

                % ---------------------------------------------------------
                % Irradiance exported to CSV
                % ---------------------------------------------------------
                % In normal operation, IR_profile_export should already be finite
                % and non-negative because negative raw irradiance values are clipped
                % before the 1-second interpolation step. The checks below are kept
                % as a final safety guard and are counted in metadata.
                n_IR_negative_after_resampling = sum(isfinite(IR_profile_export) & IR_profile_export < 0);
                n_IR_nonfinite_after_resampling = sum(~isfinite(IR_profile_export));

                IR_profile_export(~isfinite(IR_profile_export)) = 0;
                IR_profile_export(IR_profile_export < 0) = 0;
                IR_profile_export(IR_profile_export > 1200) = 1200;

                % ---------------------------------------------------------
                % Temperature and humidity internal protection
                % ---------------------------------------------------------
                % Negative Celsius temperatures are physically possible and must not
                % be forced to zero. For Simulink, only non-finite or clearly
                % impossible values are corrected. The exported T/H profiles are kept
                % as close as possible to the measured/resampled data.

                n_T_nonfinite_after_resampling = sum(~isfinite(T_profile_export));
                n_T_out_of_range_after_resampling = sum(isfinite(T_profile_export) & ...
                    (T_profile_export < temperature_min_physical_degC | T_profile_export > temperature_max_physical_degC));

                T_profile_for_sim = T_profile_export;
                T_profile_for_sim(~isfinite(T_profile_for_sim)) = 25;
                T_profile_for_sim(T_profile_for_sim < temperature_min_physical_degC) = temperature_min_physical_degC;
                T_profile_for_sim(T_profile_for_sim > temperature_max_physical_degC) = temperature_max_physical_degC;

                n_H_out_of_range_after_resampling = sum(isfinite(H_profile_export) & (H_profile_export < 0 | H_profile_export > 100));
                n_H_nonfinite_after_resampling = sum(~isfinite(H_profile_export));

                H_profile_for_sim = H_profile_export;
                H_profile_for_sim(H_profile_for_sim < 0) = 0;
                H_profile_for_sim(H_profile_for_sim > 100) = 100;
                H_profile_for_sim(~isfinite(H_profile_for_sim)) = 0;

                % ---------------------------------------------------------
                % Numerically protected irradiance for Simulink only
                % ---------------------------------------------------------
                % The full day is simulated, including the night. To avoid PV Array
                % algebraic singularities, Simulink receives a very small positive
                % floor. This protected irradiance is NOT exported in signals.csv.

                IR_profile_for_sim = IR_profile_export;
                IR_profile_for_sim(~isfinite(IR_profile_for_sim)) = IR_floor_for_simulink_Wm2;
                IR_profile_for_sim(IR_profile_for_sim < IR_floor_for_simulink_Wm2) = IR_floor_for_simulink_Wm2;
                IR_profile_for_sim(IR_profile_for_sim > 1200) = 1200;

                % F1 is implemented as an irradiance-suppression equivalent of an
                % open circuit. The physical target is zero production, but the
                % Simulink signal must not be exactly zero. Therefore the affected
                % string is also protected by the same numerical floor.
                if strcmp(scenario_id, 'F1')
                    params.IR_f1_physical_target_Wm2 = 0;
                    params.IR_f1_min = max(getfieldWithDefault(params, 'IR_f1_min', 0), IR_floor_for_simulink_Wm2);
                end

                % Store methodological information in params so that every
                % metadata.json records exactly what was done. This is useful for
                % reproducibility and for writing the future dataset paper.
                params.IR_floor_for_simulink_Wm2 = IR_floor_for_simulink_Wm2;
                params.IR_low_irradiance_threshold_Wm2 = IR_low_irradiance_threshold_Wm2;
                params.IR_output_zero_threshold_Wm2 = IR_output_zero_threshold_Wm2;
                params.zero_electrical_outputs_below_IR_floor = zero_electrical_outputs_below_IR_floor;
                params.temperature_min_physical_degC = temperature_min_physical_degC;
                params.temperature_max_physical_degC = temperature_max_physical_degC;

                params.meteo_preprocessing = struct();
                params.meteo_preprocessing.csv_IR_policy = ...
                    'signals.csv stores the quality-controlled measured irradiance: negative source irradiance values were clipped to 0 W/m2 before 1-second resampling.';
                params.meteo_preprocessing.simulink_IR_policy = ...
                    'Simulink receives a separate protected irradiance profile with a 0.1 W/m2 numerical floor to avoid PV Array singularities.';
                params.meteo_preprocessing.current_export_policy = ...
                    'Electrical currents are exported as returned by Simulink by default; no abs(I) and no night-time zero forcing are applied.';
                params.meteo_preprocessing.raw_negative_irradiance_clipped_before_resampling = true;
                params.meteo_preprocessing.exported_IR_replaced_by_simulink_floor = false;
                params.meteo_preprocessing.internal_negative_irradiance_clipped_to_zero = true;
                params.meteo_preprocessing.nonfinite_irradiance_replaced_by_zero_in_export_signal = true;
                params.meteo_preprocessing.irradiance_upper_limit_Wm2_export = 1200;
                params.meteo_preprocessing.IR_floor_for_simulink_Wm2 = IR_floor_for_simulink_Wm2;
                params.meteo_preprocessing.IR_low_irradiance_threshold_Wm2 = IR_low_irradiance_threshold_Wm2;
                params.meteo_preprocessing.zero_electrical_outputs_below_IR_floor = zero_electrical_outputs_below_IR_floor;
                params.meteo_preprocessing.temperature_min_physical_degC_internal = temperature_min_physical_degC;
                params.meteo_preprocessing.temperature_max_physical_degC_internal = temperature_max_physical_degC;
                params.meteo_preprocessing.temperature_nonfinite_replacement_degC_internal = 25;
                params.meteo_preprocessing.humidity_sent_to_simulink_clipped_to_0_100_percent = true;
                params.meteo_preprocessing.humidity_nonfinite_value_sent_to_simulink = 0;
                params.meteo_preprocessing.n_IR_negative_after_resampling = n_IR_negative_after_resampling;
                params.meteo_preprocessing.n_IR_nonfinite_after_resampling = n_IR_nonfinite_after_resampling;
                params.meteo_preprocessing.n_T_nonfinite_after_resampling = n_T_nonfinite_after_resampling;
                params.meteo_preprocessing.n_T_out_of_range_after_resampling = n_T_out_of_range_after_resampling;
                params.meteo_preprocessing.n_H_out_of_range_after_resampling = n_H_out_of_range_after_resampling;
                params.meteo_preprocessing.n_H_nonfinite_after_resampling = n_H_nonfinite_after_resampling;
                params.meteo_preprocessing.comment = ...
                    ['Negative irradiance values in the source data are treated as ' ...
                     'night-time sensor offset/noise and clipped to 0 W/m2 before ' ...
                     'resampling. The exported IR column is not replaced by the ' ...
                     'Simulink numerical floor.'];

                IR_profile = IR_profile_export;
                T_profile = T_profile_export;
                H_profile = H_profile_export;

                [IR_deg, deg_factor, arc_ctrl, arc_hf_noise] = ...
                    buildDynamicProfiles(params, t_profile, IR_profile_for_sim);

                simIn_batch(rr) = configureSimulationInput( ...
                    simIn_batch(rr), params, model_params, t_profile, IR_profile_for_sim, IR_deg, ...
                    T_profile_for_sim, H_profile_for_sim, deg_factor, arc_ctrl, arc_hf_noise, t_profile(end));

                exp_folder = buildDiagnosisReadyExperimentFolder( ...
                    output_root, meteo_params, scenario_id, exp_label);

                params_list{rr} = params;
                exp_folder_list{rr} = exp_folder;
                t_profile_list{rr} = t_profile;
                datetime_profile_list{rr} = datetime_profile;
                IR_profile_list{rr} = IR_profile_export;
                IR_profile_for_sim_list{rr} = IR_profile_for_sim;
                T_profile_list{rr} = T_profile_export;
                H_profile_list{rr} = H_profile_export;
                arc_hf_noise_list{rr} = arc_hf_noise;

                fprintf('Prepared | Dataset: %s | Scenario: %s | %s | Source: %s | Day: %s | Interval: %s to %s | samples: %d\n', ...
                    dataset_label, scenario_id, exp_label, meteo_params.source_stem, meteo_params.real_day, ...
                    char(meteo_params.original_start), char(meteo_params.original_end), numel(t_profile));
            end

            if use_parallel
                fprintf('Running batch %d-%d in parallel | Dataset: %s | Scenario: %s\n', ...
                    batch_start, batch_end, dataset_label, scenario_id);
                simOut = parsim(simIn_batch, ...
                    'ShowProgress', 'on', ...
                    'UseFastRestart', 'off', ...
                    'TransferBaseWorkspaceVariables', 'on');
            else
                fprintf('Running batch %d-%d in serial mode | Dataset: %s | Scenario: %s\n', ...
                    batch_start, batch_end, dataset_label, scenario_id);
                simOut = sim(simIn_batch, ...
                    'ShowProgress', 'on', ...
                    'UseFastRestart', 'off');
            end

            for rr = 1:n_batch
                params = params_list{rr};

                if isprop(simOut(rr), 'ErrorMessage') && ~isempty(simOut(rr).ErrorMessage)
                
                    failed_simulations = failed_simulations + 1;
                
                    fprintf('\n');
                    fprintf('============================================================\n');
                    fprintf('SIMULATION FAILURE DIAGNOSTIC\n');
                    fprintf('============================================================\n');
                
                    fprintf('Dataset      : %s\n', params.meteo_dataset_label);
                    fprintf('Scenario     : %s\n', scenario_id);
                    fprintf('Experiment   : %s\n', params.experiment_label);
                    fprintf('Real day     : %s\n', params.meteo_real_day);
                    fprintf('Source file  : %s\n', params.meteo_source_file);
                
                    fprintf('\n');
                    fprintf('Day type     : %s\n', params.day_type);
                    fprintf('Sunrise      : %.2f h\n', params.sunrise_h);
                    fprintf('Sunset       : %.2f h\n', params.sunset_h);
                    fprintf('Day length   : %.2f h\n', params.day_length_h);
                
                    fprintf('\n');
                    fprintf('Fault parameters:\n');
                
                    switch scenario_id
                
                        case 'F1'
                            fprintf('RF1 = %.6g\n', params.RF1);
                
                        case 'F2'
                            fprintf('RF2 = %.6g\n', params.RF2);
                
                        case 'F3'
                            fprintf('RF3 = %.6g\n', params.RF3);
                
                        case 'F4'
                            fprintf('RF4 = %.6g\n', params.RF4);
                            fprintf('Shading severity = %.3f\n', params.shading_severity);
                
                        case 'F5'
                            fprintf('DEG_final = %.3f\n', params.DEG_final);
                
                        case 'F6'
                            fprintf('RF6 = %.6g\n', params.RF6);
                            fprintf('Pint = %.3f\n', params.Pint);
                            fprintf('Dint = %.3f\n', params.Dint);
                
                        case 'F7'
                            fprintf('RF7 = %.6g\n', params.RF7);
                            fprintf('arc_noise_amp = %.3f\n', params.arc_noise_amp);
                
                        case 'F8'
                            fprintf('RF8 = %.6g\n', params.RF8);
                
                        case 'F9'
                            fprintf('Mismatch level = %s\n', string(params.mismatch_level));
                
                        case 'F10'
                            fprintf('RF10 = %.6g\n', params.RF10);
                
                        case 'F11'
                            fprintf('RF11 = %.6g\n', params.RF11);
                            fprintf('RF12 = %.6g\n', params.RF12);
                
                    end
                
                    fprintf('\n');
                    fprintf('Meteorological conditions:\n');
                
                    fprintf('IR min/max/mean = %.2f / %.2f / %.2f W/m2\n', ...
                        min(IR_profile_list{rr}), ...
                        max(IR_profile_list{rr}), ...
                        mean(IR_profile_list{rr}));
                    fprintf('IR sent to Simulink min/max/mean = %.2f / %.2f / %.2f W/m2\n', ...
                        min(IR_profile_for_sim_list{rr}), ...
                        max(IR_profile_for_sim_list{rr}), ...
                        mean(IR_profile_for_sim_list{rr}));
                
                
                    fprintf('T min/max/mean = %.2f / %.2f / %.2f °C\n', ...
                        min(T_profile_list{rr}), ...
                        max(T_profile_list{rr}), ...
                        mean(T_profile_list{rr}));
                
                
                    % ----------------------------------------------------
                    % Extract failure time from Simulink message
                    % ----------------------------------------------------
                
                    tokens = regexp( ...
                        simOut(rr).ErrorMessage, ...
                        'time\s+([0-9]+\.?[0-9]*)', ...
                        'tokens', ...
                        'once');
                
                    if ~isempty(tokens)
                
                        fail_time = str2double(tokens{1});
                
                        idx_fail = min( ...
                            max(round(fail_time)+1,1), ...
                            numel(IR_profile_list{rr}));
                
                        fprintf('\n');
                        fprintf('Failure time diagnostic:\n');
                
                        fprintf('Failure time = %.1f s (%.2f h)\n', ...
                            fail_time, ...
                            fail_time/3600);
                
                        fprintf('IR at failure = %.2f W/m2\n', ...
                            IR_profile_list{rr}(idx_fail));
                        fprintf('IR sent to Simulink at failure = %.2f W/m2\n', ...
                            IR_profile_for_sim_list{rr}(idx_fail));
                
                
                        fprintf('Temperature at failure = %.2f °C\n', ...
                            T_profile_list{rr}(idx_fail));
                
                        fprintf('Humidity at failure = %.2f %%\n', ...
                            H_profile_list{rr}(idx_fail));
                
                    end
                
                    fprintf('\n');
                    fprintf('Simulink error:\n');
                    fprintf('%s\n', simOut(rr).ErrorMessage);
                
                    fprintf('============================================================\n\n');
                
                    continue
                
                end
                try
                    saveSimulationOutputs( ...
                        simOut(rr), exp_folder_list{rr}, scenario_id, params, ...
                        t_profile_list{rr}, datetime_profile_list{rr}, ...
                        IR_profile_list{rr}, T_profile_list{rr}, H_profile_list{rr}, ...
                        arc_hf_noise_list{rr}, verbose_save, target_arc_string);
                    completed_simulations = completed_simulations + 1;
                catch ME
                    failed_simulations = failed_simulations + 1;
                    warning('Saving failed | Dataset: %s | Scenario: %s | %s:\n%s', ...
                        params.meteo_dataset_label, scenario_id, params.experiment_label, ME.message);
                end
            end

            clear simIn_batch simOut params_list exp_folder_list t_profile_list datetime_profile_list
            clear IR_profile_list IR_profile_for_sim_list T_profile_list H_profile_list arc_hf_noise_list
        end

        close_system(model_name, 0);
    end
end

elapsed_total = toc(total_timer);

fprintf('\n=================================================\n');
fprintf('DATASET GENERATION COMPLETED\n');
fprintf('=================================================\n');
fprintf(' Total planned simulations: %d\n', total_planned_simulations);
fprintf(' Completed simulations: %d\n', completed_simulations);
fprintf(' Failed simulations: %d\n', failed_simulations);
fprintf(' Real computation time: %.2f s = %.2f min\n', elapsed_total, elapsed_total/60);
fprintf(' Dataset root: %s\n', output_root);
fprintf('=================================================\n');

fprintf('\nFinished at: %s\n', datestr(now));
fprintf('Log file saved at: %s\n', log_file);

diary off;

%% =========================================================
% LOCAL FUNCTIONS
% =========================================================

function params = generateExperimentParameters(base, scenario_id, scenario_index, experiment_id)
    params = base;
    params.scenario_id = scenario_id;
    params.scenario_index = scenario_index;
    params.experiment_id = experiment_id;
    params.experiment_label = sprintf('exp_%05d', experiment_id);
end

function params = attachMeteoParams(params, meteo_params, experiment_index)
    params.meteo_source_mode = meteo_params.source_mode;
    params.meteo_dataset_label = meteo_params.dataset_label;
    params.meteo_source_file = meteo_params.source_file;
    params.meteo_real_day = meteo_params.real_day;
    params.meteo_segment_label = meteo_params.segment_label;
    params.meteo_original_start = char(meteo_params.original_start);
    params.meteo_original_end = char(meteo_params.original_end);
    params.meteo_original_median_step_s = meteo_params.original_median_step_s;
    params.meteo_resampling_method = meteo_params.interpolation_method;
    params.meteo_segment_index = meteo_params.day_idx;
    params.meteo_variant_index = meteo_params.variant_idx;
    params.option_c_experiment_index = experiment_index;
    params.meteo_n_original_samples = meteo_params.n_original_samples;
    params.segment_duration_s = meteo_params.segment_duration_s;
    params.day_type = meteo_params.day_type;
    params.sunrise_h = meteo_params.sunrise_h;
    params.sunset_h = meteo_params.sunset_h;
    params.day_length_h = meteo_params.day_length_h;
    params.seasonal_IR_max = meteo_params.seasonal_IR_max;
    params.T_night = meteo_params.T_night;
    params.T_amp = meteo_params.T_amp;
    params.T_min_hour = meteo_params.T_min_hour;
    params.T_max_hour = meteo_params.T_max_hour;
    params.IR_scale = 1.0;
    params.T_offset = 0.0;
end

function [IR_deg, deg_factor, arc_ctrl, arc_hf_noise] = buildDynamicProfiles(params, t_profile, IR_day)
    deg_factor = ones(size(t_profile));
    if isfield(params, 'timef5') && isfinite(params.timef5)
        idx_deg = t_profile >= params.timef5;
        tau_deg = max((max(t_profile) - params.timef5) / 3, 1);
        deg_factor(idx_deg) = (1 - params.DEG_final) + ...
            params.DEG_final * exp(-(t_profile(idx_deg) - params.timef5) / tau_deg);
    end
    IR_deg = IR_day .* deg_factor;

    % Numerical protection for degradation scenarios:
    % IR_day already contains the Simulink irradiance floor, but degradation can
    % multiply it by a factor below 1. Enforce the same floor on IR_deg so that
    % degraded PV Array inputs are never exactly zero.
    IR_floor_local = getfieldWithDefault(params, 'IR_floor_for_simulink_Wm2', 0);
    if IR_floor_local > 0
        IR_deg(~isfinite(IR_deg)) = IR_floor_local;
        IR_deg(IR_deg < IR_floor_local) = IR_floor_local;
    end

    arc_ctrl = zeros(size(t_profile));
    arc_hf_noise = zeros(size(t_profile));

    if ~isfield(params, 'timef7') || ~isfinite(params.timef7)
        return
    end

    episodes_rel_base = params.arc_episodes_rel_nominal;
    scale = getfieldWithDefault(params, 'arc_episode_scale', 1);
    jitter = getfieldWithDefault(params, 'arc_time_jitter_s', 0);
    episodes_rel = round(episodes_rel_base * scale + jitter);
    episodes_rel(episodes_rel < 0) = 0;
    episodes = episodes_rel + params.timef7;

    for k = 1:size(episodes, 1)
        idx_arc = t_profile >= episodes(k, 1) & t_profile <= episodes(k, 2);
        arc_ctrl(idx_arc) = 1;
        if strcmp(params.scenario_id, 'F7')
            n_arc = sum(idx_arc);
            if n_arc > 0
                amp = getfieldWithDefault(params, 'arc_noise_amp', 0.08);
                arc_hf_noise(idx_arc) = (0.7 + 0.3 * rand(n_arc, 1)) .* amp .* randn(n_arc, 1);
            end
        end
    end
end

function simIn = configureSimulationInput( ...
    simIn, params, model_params, t_profile, IR_day, IR_deg, T_day, H_day, deg_factor, arc_ctrl, arc_hf_noise, tfinal_exp)

    IR_ts = timeseries(IR_day, t_profile);
    IR_ts_deg = timeseries(IR_deg, t_profile);
    T_ts = timeseries(T_day, t_profile);
    H_ts = timeseries(H_day, t_profile);
    arc_ts = timeseries(arc_ctrl, t_profile);
    arc_noise_ts = timeseries(arc_hf_noise, t_profile);

    % =========================================================
    % Scenario-specific irradiance signals with numerical protection
    % =========================================================
    % IR_day is the protected Simulink irradiance input. It can differ from the
    % exported CSV irradiance only during zero/near-zero light conditions.
    %
    % F1 is represented as an irradiance-suppression equivalent of an open
    % circuit. The model does not use an ideal switch opening the circuit.
    % The affected string is sent to the same numerical floor instead of an exact
    % zero to prevent PV Array algebraic singularities.

    IR_floor_local = getfieldWithDefault(params, 'IR_floor_for_simulink_Wm2', 0.1);

    IR_f1_open = IR_day;
    if strcmp(params.scenario_id, 'F1')
        IR_f1_min_for_sim = max(getfieldWithDefault(params, 'IR_f1_min', IR_floor_local), IR_floor_local);
        IR_f1_open(t_profile >= params.timef1) = IR_f1_min_for_sim;
    end
    IR_ts_f1_open = timeseries(IR_f1_open, t_profile);

    shading_severity = getfieldWithDefault(params, 'shading_severity', 0);
    tau_shading = getfieldWithDefault(params, 'shading_transition_s', 20);
    alpha_f4 = 1 ./ (1 + exp(-(t_profile - params.timef4)/tau_shading));
    IR_shaded = IR_day .* (1 - shading_severity * alpha_f4);

    % F4 shading may mathematically push irradiance below the safe Simulink
    % floor. Keep the protected signal above the floor; the exported CSV still
    % stores the real resampled irradiance, not this internal signal.
    IR_shaded(~isfinite(IR_shaded)) = IR_floor_local;
    IR_shaded(IR_shaded < IR_floor_local) = IR_floor_local;
    IR_ts_shaded = timeseries(IR_shaded, t_profile);

    simIn = simIn.setModelParameter('SimulationMode', 'normal');
    simIn = simIn.setModelParameter('StopTime', num2str(tfinal_exp));
    simIn = simIn.setModelParameter('LoadInitialState', 'off');
    simIn = simIn.setModelParameter('SaveFinalState', 'off');

    simIn = simIn.setVariable('scenario_id', params.scenario_id);
    simIn = simIn.setVariable('Ts_Power', model_params.Ts_Power);
    simIn = simIn.setVariable('Ts_Control', model_params.Ts_Control);
    simIn = simIn.setVariable('Rload_day', model_params.Rload_day);
    simIn = simIn.setVariable('Fnom', model_params.Fnom);
    simIn = simIn.setVariable('Vnom_dc', model_params.Vnom_dc);

    simIn = simIn.setVariable('IR_ts', IR_ts);
    simIn = simIn.setVariable('IR_ts_deg', IR_ts_deg);
    simIn = simIn.setVariable('T_ts', T_ts);
    simIn = simIn.setVariable('H_ts', H_ts);
    simIn = simIn.setVariable('H_day', H_day);
    simIn = simIn.setVariable('arc_ts', arc_ts);
    simIn = simIn.setVariable('arc_noise_ts', arc_noise_ts);
    simIn = simIn.setVariable('IR_ts_f1_open', IR_ts_f1_open);
    simIn = simIn.setVariable('IR_ts_shaded', IR_ts_shaded);
    simIn = simIn.setVariable('IR_shaded', IR_shaded);
    simIn = simIn.setVariable('shading_severity', shading_severity);

    simIn = simIn.setVariable('RF1', params.RF1);
    simIn = simIn.setVariable('RF2', params.RF2);
    simIn = simIn.setVariable('RF3', params.RF3);
    simIn = simIn.setVariable('RF4', params.RF4);
    simIn = simIn.setVariable('RF5', params.RF5);
    simIn = simIn.setVariable('RF6', params.RF6);
    simIn = simIn.setVariable('RF7', params.RF7);
    simIn = simIn.setVariable('RF8', params.RF8);
    simIn = simIn.setVariable('RF10', params.RF10);
    simIn = simIn.setVariable('RF11', params.RF11);
    simIn = simIn.setVariable('RF12', params.RF12);

    simIn = simIn.setVariable('timef0', params.timef0);
    simIn = simIn.setVariable('timef1', params.timef1);
    simIn = simIn.setVariable('timef2', params.timef2);
    simIn = simIn.setVariable('timef3', params.timef3);
    simIn = simIn.setVariable('timef4', params.timef4);
    simIn = simIn.setVariable('timef5', params.timef5);
    simIn = simIn.setVariable('timef6', params.timef6);
    simIn = simIn.setVariable('timef7', params.timef7);
    simIn = simIn.setVariable('timef8', params.timef8);
    simIn = simIn.setVariable('timef10', params.timef10);
    simIn = simIn.setVariable('timef11', params.timef11);
    simIn = simIn.setVariable('timef12', params.timef12);

    simIn = simIn.setVariable('DEG_final', params.DEG_final);
    simIn = simIn.setVariable('deg_factor', deg_factor);
    simIn = simIn.setVariable('Pint', params.Pint);
    simIn = simIn.setVariable('Dint', params.Dint);
    simIn = simIn.setVariable('Pint12', params.Pint12);
    simIn = simIn.setVariable('Dint12', params.Dint12);
    simIn = simIn.setVariable('mismatch_level', params.mismatch_level);
    simIn = simIn.setVariable('module_mismatch_choice', params.module_mismatch_choice);
end

function saveSimulationOutputs(simout, exp_folder, scenario_id, params, ...
    t_profile, datetime_profile, IR_day, T_day, H_day, arc_hf_noise, verbose_save, target_arc_string)

    selected_currents = getScenarioCurrents(scenario_id);
    I_pos_all = containers.Map('KeyType', 'double', 'ValueType', 'any');
    I_neg_all = containers.Map('KeyType', 'double', 'ValueType', 'any');
    found_currents = [];

    for idx = 1:numel(selected_currents)
        k = selected_currents(idx);
        sig_pos = sprintf('I%d', k);
        sig_neg = sprintf('I%d_Neg', k);
        try
            I_pos_all(k) = getSignalData(simout.get(sig_pos));
            found_currents(end+1) = k; %#ok<AGROW>
        catch
            warning('Signal %s not found in simulation output for scenario %s.', sig_pos, scenario_id);
            continue
        end
        try
            I_neg_all(k) = getSignalData(simout.get(sig_neg));
        catch
            warning('Signal %s not found. Replacing it with NaN.', sig_neg);
            I_neg_all(k) = NaN(size(I_pos_all(k)));
        end
    end

    if isempty(found_currents)
        error('No selected current signals were found for scenario %s.', scenario_id);
    end

    lengths = [numel(t_profile), numel(datetime_profile), numel(IR_day), numel(T_day), numel(H_day), numel(arc_hf_noise)];
    current_lengths = zeros(2*numel(found_currents), 1);
    for idx = 1:numel(found_currents)
        k = found_currents(idx);
        current_lengths(2*idx-1) = numel(I_pos_all(k));
        current_lengths(2*idx) = numel(I_neg_all(k));
    end
    N = min([lengths(:); current_lengths(:)]);

    t_out = t_profile(1:N);
    datetime_out = datetime_profile(1:N);
    IR_out = IR_day(1:N);
    T_out = T_day(1:N);
    H_out = H_day(1:N);
    arc_hf_noise_out = arc_hf_noise(1:N);

    % =========================================================
    % LOW-IRRADIANCE FLAG AND OPTIONAL OUTPUT POST-PROCESSING
    % =========================================================
    % The Simulink model may have used a very small irradiance floor internally
    % to avoid singularities in PV Array blocks. The CSV, however, stores the
    % quality-controlled measured irradiance, not the internal protected signal.
    %
    % To keep the main dataset minimally processed, electrical currents are
    % exported as returned by Simulink by default. They are NOT converted to
    % absolute values and are NOT forced to zero unless the optional parameter
    % zero_electrical_outputs_below_IR_floor is explicitly set to true.
    %
    % A low_irradiance_flag is always added to identify samples where the
    % exported irradiance is below the chosen low-light threshold.

    IR_low_threshold = getfieldWithDefault(params, 'IR_low_irradiance_threshold_Wm2', ...
        getfieldWithDefault(params, 'IR_output_zero_threshold_Wm2', 5.0));
    force_zero_outputs = getfieldWithDefault(params, 'zero_electrical_outputs_below_IR_floor', false);

    IR_out_for_flag = IR_out;
    IR_out_for_flag(~isfinite(IR_out_for_flag)) = 0;
    IR_out_for_flag(IR_out_for_flag < 0) = 0;
    low_irradiance_flag = IR_out_for_flag <= IR_low_threshold;

    if force_zero_outputs
        arc_hf_noise_out(low_irradiance_flag) = 0;
    end

    signal_table = table(datetime_out(:), t_out(:), IR_out(:), T_out(:), H_out(:), logical(low_irradiance_flag(:)), ...
        'VariableNames', {'datetime', 'time_s', 'IR', 'T', 'H', 'low_irradiance_flag'});

    for idx = 1:numel(found_currents)
        k = found_currents(idx);
        pos = I_pos_all(k);
        neg = I_neg_all(k);

        pos_out = pos(1:N);
        neg_out = neg(1:N);

        if force_zero_outputs
            pos_out(low_irradiance_flag) = 0;
            neg_out(low_irradiance_flag) = 0;
        end

        signal_table.(sprintf('I%d', k)) = pos_out(:);
        signal_table.(sprintf('I%d_Neg', k)) = neg_out(:);
    end

    if ~isempty(target_arc_string) && isKey(I_pos_all, target_arc_string) && strcmp(scenario_id, 'F7')
        signal_table.(sprintf('I%d_arc_hf_noise', target_arc_string)) = arc_hf_noise_out(:);
    end

    metadata = buildExperimentMetadata(params, scenario_id, N, found_currents);

    % =========================================================
    % ENSURE OUTPUT FOLDER EXISTS
    % =========================================================
    exp_folder = char(exp_folder);
    
    if ~exist(exp_folder, 'dir')
        [status, msg, msgID] = mkdir(exp_folder);
    
        if ~status
            error(['Unable to create experiment output folder:\n%s\n' ...
                   'MATLAB message: %s\nMessage ID: %s'], ...
                exp_folder, msg, msgID);
        end
    end
    
    % Final verification before writing
    if ~exist(exp_folder, 'dir')
        error('Experiment output folder does not exist: %s', exp_folder);
    end

    signals_file = fullfile(exp_folder, 'signals.csv');
    
    if verbose_save
        fprintf('Saving signals CSV: %s\n', signals_file);
    end
    
    writetable(signal_table, signals_file, ...
        'FileType', 'text', ...
        'WriteMode', 'overwrite');
    json_text = jsonencode(metadata, 'PrettyPrint', true);
    fid = fopen(fullfile(exp_folder, 'metadata.json'), 'w');
    if fid < 0
        error('Could not create metadata.json in %s', exp_folder);
    end
    fprintf(fid, '%s', json_text);
    fclose(fid);

    if verbose_save
        fprintf('Saved %s with %d samples.\n', exp_folder, N);
    end
end

function metadata = buildExperimentMetadata(params, scenario_id, n_samples, found_currents)
    fault_info = getFaultDescriptor(params, scenario_id);
    metadata = struct();
    metadata.scenario_id = scenario_id;
    metadata.scenario_index = params.scenario_index;
    metadata.experiment_id = params.experiment_id;
    metadata.experiment_label = params.experiment_label;
    metadata.fixed_severity_experiment = true;
    metadata.day_simulation_index = getfieldWithDefault(params, 'day_simulation_index', NaN);
    metadata.n_samples = n_samples;
    metadata.current_signals = arrayfun(@(k) sprintf('I%d/I%d_Neg', k, k), found_currents, 'UniformOutput', false);

    metadata.meteo_dataset = char(getfieldWithDefault(params, 'meteo_dataset_label', 'synthetic'));
    metadata.meteo_real_day = char(getfieldWithDefault(params, 'meteo_real_day', 'synthetic'));
    metadata.meteo_segment_label = char(getfieldWithDefault(params, 'meteo_segment_label', 'synthetic'));
    metadata.meteo_source_file = char(getfieldWithDefault(params, 'meteo_source_file', 'synthetic'));
    metadata.meteo_original_start = char(getfieldWithDefault(params, 'meteo_original_start', 'synthetic'));
    metadata.meteo_original_end = char(getfieldWithDefault(params, 'meteo_original_end', 'synthetic'));
    metadata.meteo_original_median_step_s = getfieldWithDefault(params, 'meteo_original_median_step_s', NaN);
    metadata.meteo_n_original_samples = getfieldWithDefault(params, 'meteo_n_original_samples', NaN);
    metadata.meteo_resampling_method = char(getfieldWithDefault(params, 'meteo_resampling_method', 'linear'));
    metadata.segment_duration_s = getfieldWithDefault(params, 'segment_duration_s', NaN);
    metadata.day_type = char(getfieldWithDefault(params, 'day_type', 'unknown'));
    metadata.sunrise_h_relative_to_segment_start = getfieldWithDefault(params, 'sunrise_h', NaN);
    metadata.sunset_h_relative_to_segment_start = getfieldWithDefault(params, 'sunset_h', NaN);
    metadata.max_irradiance_Wm2 = getfieldWithDefault(params, 'seasonal_IR_max', NaN);

    metadata.full_day_preserved = true;
    metadata.IR_floor_for_simulink_Wm2 = getfieldWithDefault(params, 'IR_floor_for_simulink_Wm2', NaN);
    metadata.IR_low_irradiance_threshold_Wm2 = getfieldWithDefault(params, 'IR_low_irradiance_threshold_Wm2', NaN);
    metadata.IR_output_zero_threshold_Wm2 = getfieldWithDefault(params, 'IR_output_zero_threshold_Wm2', NaN);
    metadata.zero_electrical_outputs_below_IR_floor = getfieldWithDefault(params, 'zero_electrical_outputs_below_IR_floor', false);
    metadata.temperature_min_physical_degC = getfieldWithDefault(params, 'temperature_min_physical_degC', NaN);
    metadata.temperature_max_physical_degC = getfieldWithDefault(params, 'temperature_max_physical_degC', NaN);
    metadata.meteo_preprocessing = getfieldWithDefault(params, 'meteo_preprocessing', struct());

    metadata.simulation_export_policy = ...
        ['signals.csv stores the quality-controlled measured meteorological profile. ' ...
         'Negative source irradiance values are clipped to 0 W/m2 before resampling. ' ...
         'The exported IR column is not replaced by the Simulink numerical floor. ' ...
         'A separate internal irradiance signal is floored only to protect Simulink PV Array blocks. ' ...
         'Electrical currents are exported as returned by Simulink by default; low_irradiance_flag identifies night/near-zero irradiance samples.'];

    metadata.fault = fault_info;
    metadata.files = {'signals.csv', 'metadata.json'};
end

function fault_info = getFaultDescriptor(params, scenario_id)
    fault_info = struct();
    fault_info.fault_active_rule = 'defined by scenario and fault_start_s';
    fault_info.fault_start_s = NaN;
    fault_info.fault_resistance_ohm = NaN;
    fault_info.fault_severity = NaN;
    fault_info.fault_period_s = NaN;
    fault_info.fault_duty_percent = NaN;
    fault_info.secondary_fault_start_s = NaN;
    fault_info.secondary_fault_resistance_ohm = NaN;
    fault_info.mismatch_level = '';
    fault_info.module_mismatch_choice = '';

    switch scenario_id
        case 'F0'
            fault_info.fault_type = 'healthy';
        case 'F1'
            fault_info.fault_type = 'open_circuit';
            fault_info.fault_start_s = params.timef1;
            fault_info.fault_resistance_ohm = params.RF1;
            fault_info.open_circuit_model = getfieldWithDefault(params, 'open_circuit_model', 'irradiance_suppression');
            fault_info.physical_target_irradiance_after_fault_Wm2 = getfieldWithDefault(params, 'IR_f1_physical_target_Wm2', 0);
            fault_info.simulink_min_irradiance_after_fault_Wm2 = getfieldWithDefault(params, 'IR_f1_min', NaN);
        case 'F2'
            fault_info.fault_type = 'intra_string_short_circuit';
            fault_info.fault_start_s = params.timef2;
            fault_info.fault_resistance_ohm = params.RF2;
        case 'F3'
            fault_info.fault_type = 'ground_fault';
            fault_info.fault_start_s = params.timef3;
            fault_info.fault_resistance_ohm = params.RF3;
        case 'F4'
            fault_info.fault_type = 'partial_shading';
            fault_info.fault_start_s = params.timef4;
            fault_info.fault_resistance_ohm = params.RF4;
            fault_info.fault_severity = params.shading_severity;
        case 'F5'
            fault_info.fault_type = 'progressive_degradation';
            fault_info.fault_start_s = params.timef5;
            fault_info.fault_severity = params.DEG_final;
        case 'F6'
            fault_info.fault_type = 'intermittent_short_circuit';
            fault_info.fault_start_s = params.timef6;
            fault_info.fault_resistance_ohm = params.RF6;
            fault_info.fault_period_s = params.Pint;
            fault_info.fault_duty_percent = params.Dint;
        case 'F7'
            fault_info.fault_type = 'arc_fault';
            fault_info.fault_start_s = params.timef7;
            fault_info.fault_resistance_ohm = params.RF7;
            fault_info.fault_severity = params.arc_noise_amp;
        case 'F8'
            fault_info.fault_type = 'inter_string_short_circuit';
            fault_info.fault_start_s = params.timef8;
            fault_info.fault_resistance_ohm = params.RF8;
        case 'F9'
            fault_info.fault_type = 'module_mismatch';
            fault_info.fault_start_s = 0;
            fault_info.mismatch_level = params.mismatch_level;
            fault_info.module_mismatch_choice = params.module_mismatch_choice;
        case 'F10'
            fault_info.fault_type = 'high_resistance_connection';
            fault_info.fault_start_s = params.timef10;
            fault_info.fault_resistance_ohm = params.RF10;
        case 'F11'
            fault_info.fault_type = 'combined_fault';
            fault_info.fault_start_s = params.timef11;
            fault_info.fault_resistance_ohm = params.RF11;
            fault_info.secondary_fault_start_s = params.timef12;
            fault_info.secondary_fault_resistance_ohm = params.RF12;
            fault_info.fault_period_s = params.Pint12;
            fault_info.fault_duty_percent = params.Dint12;
    end
end

function selected_currents = getScenarioCurrents(scenario_id)
    if strcmp(scenario_id, 'F8')
        selected_currents = [1 2 3];
    else
        selected_currents = [1 2];
    end
end

function y = getSignalData(sig)
    if isa(sig, 'timeseries')
        y = sig.Data;
    elseif isstruct(sig)
        if isfield(sig, 'signals') && isfield(sig.signals, 'values')
            y = sig.signals.values;
        elseif isfield(sig, 'Data')
            y = sig.Data;
        else
            y = sig;
        end
    else
        y = sig;
    end
    y = squeeze(y);
    if size(y, 2) > 1
        y = y(:, 1);
    end
end

function resolved_path = resolveExistingPath(base_root, candidates, keywords)
    resolved_path = candidates{1};
    for i = 1:numel(candidates)
        candidate_i = candidates{i};
        if exist(candidate_i, 'dir') == 7 || exist(candidate_i, 'file') == 2
            resolved_path = candidate_i;
            return
        end
    end
    for i = 1:numel(candidates)
        candidate_i = fullfile(base_root, candidates{i});
        if exist(candidate_i, 'dir') == 7 || exist(candidate_i, 'file') == 2
            resolved_path = candidate_i;
            return
        end
    end

    % Robust fallback for GitHub/local folders: look recursively under
    % real_meteorological_time_series for a folder whose path contains at least
    % one of the requested keywords. This prevents skipping Verney only because
    % the local folder is named slightly differently.
    if nargin >= 3 && ~isempty(keywords)
        base_folder = base_root;
        if exist(base_folder, 'dir') == 7
            listing = dir(fullfile(base_folder, '**'));
            keywords = lower(string(keywords));
            best_path = '';
            best_score = -Inf;
            for k = 1:numel(listing)
                if ~listing(k).isdir
                    continue
                end
                folder_name = listing(k).name;
                if strcmp(folder_name, '.') || strcmp(folder_name, '..')
                    continue
                end
                candidate_path = fullfile(listing(k).folder, listing(k).name);
                candidate_lower = lower(string(candidate_path));
                score = 0;
                for q = 1:numel(keywords)
                    if contains(candidate_lower, keywords(q))
                        score = score + 1;
                    end
                end
                if score > best_score
                    best_score = score;
                    best_path = candidate_path;
                end
            end
            if best_score > 0 && exist(best_path, 'dir') == 7
                resolved_path = best_path;
            end
        end
    end
end

function writeSemiSyntheticSourceDescription(run_folder)
    description_file = fullfile(run_folder, 'SOURCE_DATASETS_DESCRIPTION.txt');
    txt = [ ...
        "Semi-synthetic PV fault diagnosis dataset generated with a physics-based Simulink PV model." + newline + ...
        "Environmental excitation is taken from two public Mendeley Data datasets, while labelled fault responses are generated by simulation." + newline + newline + ...
        "1) Pamplona, Colombia source dataset" + newline + ...
        "Citation: NEIRA ROPERO, LUIS ERNESTO; Pardo Garcia, Aldo; Suarez, Oscar (2025), Data on environmental and electrical variables for a photovoltaic system, Mendeley Data, V1, doi: 10.17632/z9sp7hmg5p.1." + newline + ...
        "Description: environmental and electrical data acquisition system for a photovoltaic system in Pamplona, Norte de Santander, Colombia. Variables include temperature, humidity, irradiance, and voltage/current measurements at the input and output of the photovoltaic converter and charge controller. PV panels: 100 W monocrystalline RTM100M. Sensors: RIKA RK330-02, ZTS-300AL-RA-120, JXK-10 and JXDA4U. Licence: CC BY 4.0." + newline + newline + ...
        "2) Verney, Portugal source dataset" + newline + ...
        "Citation: Islam, Mahmudul; Rashel, Masud Rana; Al-Wadud, M Abdullah; Islam, A. K. M. Kamrul; Tlemcani, Mouhaydine (2024), Time series weather dataset for predicting photovoltaic Energy in Portugal, Mendeley Data, V1, doi: 10.17632/m26hk4ysvz.1." + newline + ...
        "Description: weather time series from the University of Evora Verney weather station, Portugal. Data are organized by year and by recording interval folders named 1, 10, 60 and 1440 minutes. Variables include temperature, humidity, wind speed, solar radiation and precipitation. Licence: CC BY 4.0." + newline + newline + ...
        "Important note: the generated PV fault labels and electrical responses are semi-synthetic. The meteorological inputs are real measured time series; the PV fault scenarios are controlled simulations." + newline + newline + ...
        "Full-day numerical policy: the exported signals.csv files preserve the measured day duration and store the quality-controlled measured irradiance. Negative irradiance values in the source data are interpreted as night-time sensor offset/noise and clipped to 0 W/m2 before resampling. For Simulink only, a separate numerically protected irradiance signal with a 0.1 W/m2 floor is used to avoid PV Array singularities during zero-irradiance samples. The protected internal irradiance is not exported as the IR column. Electrical currents are exported as returned by Simulink by default, and low_irradiance_flag identifies night/near-zero irradiance samples." + newline ...
    ];
    fid = fopen(description_file, 'w');
    fprintf(fid, '%s', txt);
    fclose(fid);
end

function exp_folder = buildDiagnosisReadyExperimentFolder(run_folder, meteo_params, scenario_id, exp_label)
    dataset_label = char(getfieldWithDefault(meteo_params, 'dataset_label', 'synthetic'));
    real_day = char(getfieldWithDefault(meteo_params, 'real_day', 'unknown_day'));

    % Folder naming policy:
    % The folder name is only the real calendar date YYYY-MM-DD.
    % The exact measured interval, for example 14:05:33 -> 23:59:31, is not
    % written in the folder name anymore; it remains stored in metadata.json
    % through meteo_original_start and meteo_original_end.
    day_folder = regexprep(real_day, '[^A-Za-z0-9_\-]', '_');

    if numel(real_day) >= 4
        year_folder = real_day(1:4);
    else
        year_folder = 'unknown_year';
    end

    if contains(lower(dataset_label), 'verney') || contains(lower(dataset_label), 'portugal')
        dataset_folder = 'Verney_Portugal';
    elseif contains(lower(dataset_label), 'pamplona') || contains(lower(dataset_label), 'colombia')
        dataset_folder = 'Pamplona_Colombia';
    else
        dataset_folder = regexprep(dataset_label, '[^A-Za-z0-9_\-]', '_');
    end

    % Final organization:
    %   Dataset / Scenario / Experiment(severity variant) / Year / YYYY-MM-DD
    exp_folder = fullfile(run_folder, dataset_folder, scenario_id, exp_label, year_folder, day_folder);
end

function value = getfieldWithDefault(s, field_name, default_value)
    if isstruct(s) && isfield(s, field_name)
        value = s.(field_name);
    else
        value = default_value;
    end
end

function txt = valueToString(x)
    if isinf(x)
        txt = 'Inf';
    elseif isnumeric(x)
        txt = num2str(x);
    else
        txt = char(string(x));
    end
end

function meteo_database = loadRealMeteoDatasets(dataset_files, dataset_labels, interpolation_method, project_root)
    datasets = struct([]);

    for i = 1:numel(dataset_files)
        source_i = dataset_files{i};
        label_i = dataset_labels{i};
        source_files = collectMeteoSourceFiles(source_i);

        dataset_item = struct();
        dataset_item.label = label_i;
        dataset_item.source_root = source_i;
        dataset_item.segments = struct([]);

        if isempty(source_files)
            warning('No real meteorological files found and source will be skipped: %s', source_i);
            continue
        end

        fprintf('Dataset source %s: %d meteorological files found.\n', label_i, numel(source_files));

        for f = 1:numel(source_files)
            file_i = source_files{f};
            try
                T = readFlexibleMeteoTable(file_i);
                [time_dt, IR, Temp, Hum] = extractRealMeteoColumns(T, file_i);
            catch ME
                [~, bad_name, bad_ext] = fileparts(file_i);
                fprintf('Skipping non-standard meteorological file: %s%s | %s\n', bad_name, bad_ext, ME.message);
                continue
            end

            valid_rows = ~isnat(time_dt) & isfinite(IR) & isfinite(Temp);
            time_dt = time_dt(valid_rows);
            IR = IR(valid_rows);
            Temp = Temp(valid_rows);
            Hum = Hum(valid_rows);

            if numel(time_dt) < 2
                continue
            end

            [time_dt, sort_idx] = sort(time_dt);
            IR = IR(sort_idx);
            Temp = Temp(sort_idx);
            Hum = Hum(sort_idx);

            [time_dt, unique_idx] = unique(time_dt, 'stable');
            IR = IR(unique_idx);
            Temp = Temp(unique_idx);
            Hum = Hum(unique_idx);

            if numel(time_dt) < 2
                continue
            end

            % ---------------------------------------------------------
            % Source-level meteorological quality control BEFORE resampling
            % ---------------------------------------------------------
            % Small negative irradiance values in outdoor weather-station data are
            % commonly caused by night-time sensor offset/noise around zero. They
            % are not physically meaningful for PV irradiance. Therefore, negative
            % irradiance is clipped to 0 W/m2 before the 1-second interpolation step.
            %
            % Doing this before resampling is important: if one measured point is
            % positive and the next one is negative, linear interpolation would
            % otherwise create many additional negative samples. Clipping first keeps
            % the low-light variability while avoiding non-physical negative solar
            % irradiance in the exported dataset.
            IR(~isfinite(IR)) = NaN;
            IR(IR < 0) = 0;
            IR(IR > 1200) = 1200;
            IR = fillmissing(IR, 'linear', 'EndValues', 'nearest');

            % For temperature and humidity, only non-finite/missing or clearly
            % impossible values are handled. Negative Celsius temperatures are
            % physically possible and are not forced to zero.
            Temp(Temp < -40 | Temp > 85) = NaN;
            Hum(Hum < 0 | Hum > 100) = NaN;
            Temp = fillmissing(Temp, 'linear', 'EndValues', 'nearest');
            Hum = fillmissing(Hum, 'linear', 'EndValues', 'nearest');

            % V5 final daily strategy: split by real calendar day, but keep only
            % the measured interval of each day. No missing hours are reconstructed
            % and no artificial 00:00 -> 23:59 forcing is applied.
            file_segments = splitMeasuredFileByRealDays( ...
                label_i, source_i, file_i, time_dt, IR, Temp, Hum, ...
                interpolation_method, project_root);

            for sg = 1:numel(file_segments)
                dataset_item.segments = [dataset_item.segments; file_segments(sg)]; %#ok<AGROW>
            end
        end

        if ~isempty(dataset_item.segments)
            datasets = [datasets; dataset_item]; %#ok<AGROW>
            fprintf('Dataset source %s: %d readable real days loaded.\n', ...
                label_i, numel(dataset_item.segments));
        else
            warning('Dataset source %s did not produce any readable real day.', label_i);
        end
    end

    if isempty(datasets)
        error('No readable meteorological datasets were loaded. Check folders and column names.');
    end

    meteo_database = struct();
    meteo_database.datasets = datasets;
end


function segments = splitMeasuredFileByRealDays(label_i, source_i, file_i, time_dt, IR, Temp, Hum, interpolation_method, project_root)
    % Split the measured file by real calendar day, but NEVER reconstruct a full
    % 00:00:00 -> 23:59:59 day. Each output day keeps only the samples that are
    % actually present in the source file for that date.
    %
    % Example:
    %   Original Pamplona first day: 2025-11-12 14:05:33 -> 2025-11-12 23:59:31
    %   Generated day segment:      2025-11-12 14:05:33 -> 2025-11-12 23:59:31
    %
    % The interpolation to 1 second happens later and only inside these measured
    % start/end timestamps.

    segments = struct([]);

    if numel(time_dt) < 2
        return
    end

    [time_dt, sort_idx] = sort(time_dt);
    IR = IR(sort_idx);
    Temp = Temp(sort_idx);
    Hum = Hum(sort_idx);

    [time_dt, unique_idx] = unique(time_dt, 'stable');
    IR = IR(unique_idx);
    Temp = Temp(unique_idx);
    Hum = Hum(unique_idx);

    if numel(time_dt) < 2
        return
    end

    day_start = dateshift(time_dt, 'start', 'day');
    unique_days = unique(day_start);

    for k = 1:numel(unique_days)
        idx = day_start == unique_days(k);
        if sum(idx) < 2
            continue
        end
        segment_k = createMeteoSegment(label_i, source_i, file_i, ...
            time_dt(idx), IR(idx), Temp(idx), Hum(idx), interpolation_method, project_root);
        if ~isempty(segment_k)
            segment_k.file_segment_index = k;
            segment_k.file_segment_count = numel(unique_days);
            segments = [segments; segment_k]; %#ok<AGROW>
        end
    end
end

function segment = createMeteoSegment(label_i, source_i, file_i, time_dt, IR, Temp, Hum, interpolation_method, project_root)
    segment = [];

    if numel(time_dt) < 2
        return
    end

    [time_dt, sort_idx] = sort(time_dt);
    IR = IR(sort_idx);
    Temp = Temp(sort_idx);
    Hum = Hum(sort_idx);

    [time_dt, unique_idx] = unique(time_dt, 'stable');
    IR = IR(unique_idx);
    Temp = Temp(unique_idx);
    Hum = Hum(unique_idx);

    if numel(time_dt) < 2
        return
    end

    duration_s = floor(seconds(time_dt(end) - time_dt(1)));
    if duration_s < 1
        return
    end

    [rel_folder, source_stem] = buildRelativeSourceInfo(file_i, source_i, project_root);

    segment = struct();
    real_day = datestr(time_dt(1), 'yyyy-mm-dd');

    segment.dataset_label = label_i;
    segment.source_file = file_i;
    segment.source_stem = source_stem;
    segment.relative_source_folder = rel_folder;
    segment.real_day = real_day;
    segment.segment_label = sprintf('%s_%s_to_%s', real_day, datestr(time_dt(1), 'HHMMSS'), datestr(time_dt(end), 'HHMMSS'));
    segment.time_dt = time_dt;
    segment.IR = IR;
    segment.T = Temp;
    segment.H = Hum;
    segment.interpolation_method = interpolation_method;
    segment.original_start = time_dt(1);
    segment.original_end = time_dt(end);
    dt_seconds = seconds(diff(time_dt));
    segment.original_median_step_s = median(dt_seconds, 'omitnan');
    segment.n_original_samples = numel(time_dt);
    segment.segment_duration_s = duration_s;
end

function source_files = collectMeteoSourceFiles(source_path)
    % Robust source-file discovery without relying on dir(''**/*.dat'').
    %
    % Some MATLAB installations do not expand the ** wildcard recursively in the
    % same way. The Verney dataset can also be nested as:
    %   Verney_Portugal/2020/2020/1/verney_20200406_1.dat
    % Therefore this function uses an explicit recursive directory walk.

    source_files = {};
    source_path = char(source_path);

    if exist(source_path, 'file') == 2
        source_files = {source_path};
        return
    end

    source_lower = lower(string(source_path));
    is_verney_source = contains(source_lower, 'verney') || contains(source_lower, 'portugal');

    search_roots = {};

    if exist(source_path, 'dir') == 7
        search_roots{end+1} = source_path; %#ok<AGROW>
    end

    if is_verney_source
        parent_folder = fileparts(source_path);
        if exist(parent_folder, 'dir') == 7
            search_roots{end+1} = parent_folder; %#ok<AGROW>
        end
    end

    if isempty(search_roots)
        return
    end

    search_roots = unique(search_roots, 'stable');

    if is_verney_source
        source_files = collectVerneyOneMinuteDatFiles(search_roots);
    else
        for r = 1:numel(search_roots)
            root_i = search_roots{r};
            source_files = [source_files; recursiveListFiles(root_i, {'.csv','.txt','.dat'})]; %#ok<AGROW>
        end
    end

    source_files = sort(unique(source_files, 'stable'));
end

function source_files = collectVerneyOneMinuteDatFiles(search_roots)
    source_files = {};

    for r = 1:numel(search_roots)
        root_i = search_roots{r};
        dat_files = recursiveListFiles(root_i, {'.dat'});

        for k = 1:numel(dat_files)
            full_k = dat_files{k};
            [folder_k, name_k, ext_k] = fileparts(full_k);
            if ~strcmpi(ext_k, '.dat')
                continue
            end

            folder_parts = regexp(folder_k, '[\\/]+', 'split');
            folder_parts_lower = lower(string(folder_parts));
            file_name_lower = lower(string([name_k ext_k]));

            is_in_one_min_folder = any(folder_parts_lower == "1");
            has_one_min_suffix = endsWith(file_name_lower, "_1.dat");

            looks_like_other_interval = endsWith(file_name_lower, "_10.dat") || ...
                                        endsWith(file_name_lower, "_60.dat") || ...
                                        endsWith(file_name_lower, "_1440.dat");

            if looks_like_other_interval
                continue
            end

            if is_in_one_min_folder || has_one_min_suffix
                source_files{end+1,1} = full_k; %#ok<AGROW>
            end
        end
    end

    source_files = sort(unique(source_files, 'stable'));
end

function files = recursiveListFiles(root_folder, allowed_extensions)
    % Return a column cell array of files under root_folder whose extensions are
    % included in allowed_extensions. The recursion is explicit and portable.

    files = {};

    if exist(root_folder, 'dir') ~= 7
        return
    end

    listing = dir(root_folder);

    for i = 1:numel(listing)
        name_i = listing(i).name;
        if strcmp(name_i, '.') || strcmp(name_i, '..')
            continue
        end

        full_i = fullfile(listing(i).folder, name_i);

        if listing(i).isdir
            files_i = recursiveListFiles(full_i, allowed_extensions);
            if ~isempty(files_i)
                files = [files; files_i]; %#ok<AGROW>
            end
        else
            [~,~,ext_i] = fileparts(full_i);
            if any(strcmpi(ext_i, allowed_extensions))
                files{end+1,1} = full_i; %#ok<AGROW>
            end
        end
    end
end

function T = readFlexibleMeteoTable(file_i)
    [~,~,ext] = fileparts(file_i);
    switch lower(ext)
        case '.dat'
            opts = detectImportOptions(file_i, ...
                'FileType', 'text', ...
                'Delimiter', ',', ...
                'VariableNamingRule', 'preserve');
            opts.VariableNamesLine = 2;
            opts.DataLines = [5 Inf];
            T = readtable(file_i, opts);
        otherwise
            T = readtable(file_i, 'VariableNamingRule', 'preserve');
    end
end

function [rel_folder, source_stem] = buildRelativeSourceInfo(file_i, source_i, project_root)
    [file_folder, source_stem, ~] = fileparts(file_i);
    if exist(source_i, 'dir') == 7
        base_folder = source_i;
    elseif exist(source_i, 'file') == 2
        base_folder = fileparts(source_i);
    else
        base_folder = project_root;
    end
    rel_folder = erase(file_folder, base_folder);
    if startsWith(rel_folder, filesep)
        rel_folder = extractAfter(rel_folder, 1);
    end
    rel_folder = char(rel_folder);
    if isempty(rel_folder)
        rel_folder = '_root_file';
    end
end

function [time_dt, IR, Temp, Hum] = extractRealMeteoColumns(T, file_name)
    if istimetable(T)
        time_dt = T.Properties.RowTimes;
        T = timetable2table(T, 'ConvertRowTimes', false);
    else
        time_dt = NaT(height(T), 1);
    end

    names = string(T.Properties.VariableNames);
    names_lower = lower(names);

    if all(isnat(time_dt))
        time_col = findFirstColumn(names_lower, { ...
            'timestamp','time_stamp','date_time','datetime','date_time_utc', ...
            'time','ts','fecha_hora','fecha'});
        if isempty(time_col)
            if any(names_lower == "fecha") && any(names_lower == "hora")
                fecha_col = find(names_lower == "fecha", 1);
                hora_col = find(names_lower == "hora", 1);
                raw_time = string(T{:, fecha_col}) + " " + string(T{:, hora_col});
            else
                error('No valid timestamp header was found in %s.', file_name);
            end
        else
            raw_time = string(T{:, time_col});
        end
        time_dt = parseFlexibleDatetime(raw_time);
    end

    IR_col = findFirstColumn(names_lower, { ...
        'radianza','irradiance','irradiancia', ...
        'radiation','solar_radiation','global_radiation', ...
        'ghi','g_h_i','r_gbl_avg','r_gbl','rgbl', ...
        'rsdes_avg_avg','rsdes_avg','rsdes', ...
        'r_dir_avg','r_dif_avg', ...
        'global','solar','rad','sw_in','shortwave'});
    T_col = findFirstColumn(names_lower, { ...
        'temperatura','temperature','temp', ...
        'air_temperature','t_air_avg','t_air','tair', ...
        'tar_avg_avg','tar_avg','tar','airtemp','temp_air'});
    H_col = findFirstColumn(names_lower, { ...
        'humedad','humidity','relative_humidity','rh', ...
        'h_air_avg','h_air','hair','rh_avg','rh_air', ...
        'hr_avg_avg','hr_avg','hr','relativehumidity'});

    if isempty(IR_col)
        error('No valid irradiance/radiation column was found in %s.', file_name);
    end
    if isempty(T_col)
        error('No valid temperature column was found in %s.', file_name);
    end

    IR = toNumericColumn(T{:, IR_col});
    Temp = toNumericColumn(T{:, T_col});
    if isempty(H_col)
        Hum = NaN(size(IR));
    else
        Hum = toNumericColumn(T{:, H_col});
    end
end

function idx = findFirstColumn(names_lower, candidates)
    idx = [];
    names_lower = lower(string(names_lower));
    names_norm = regexprep(names_lower, '[^a-z0-9]', '');
    candidates_norm = strings(size(candidates));
    for c = 1:numel(candidates)
        candidates_norm(c) = regexprep(lower(string(candidates{c})), '[^a-z0-9]', '');
    end
    for c = 1:numel(candidates_norm)
        exact = find(names_norm == candidates_norm(c), 1);
        if ~isempty(exact)
            idx = exact;
            return
        end
    end
    for c = 1:numel(candidates_norm)
        contains_idx = find(contains(names_norm, candidates_norm(c)), 1);
        if ~isempty(contains_idx)
            idx = contains_idx;
            return
        end
    end
end

function x = toNumericColumn(col)
    if isnumeric(col)
        x = double(col);
    else
        s = string(col);
        s = strrep(s, ',', '.');
        s = regexprep(s, '[^0-9eE+\-\.]', '');
        x = str2double(s);
    end
end

function time_dt = parseFlexibleDatetime(raw_time)
    formats = { ...
        'yyyy-MM-dd HH:mm:ss', ...
        'yyyy-MM-dd HH:mm', ...
        'dd/MM/yyyy HH:mm:ss', ...
        'dd/MM/yyyy HH:mm', ...
        'MM/dd/yyyy HH:mm:ss', ...
        'MM/dd/yyyy HH:mm'};
    time_dt = NaT(size(raw_time));
    for k = 1:numel(formats)
        idx = isnat(time_dt);
        if ~any(idx)
            break
        end
        try
            tmp = datetime(raw_time(idx), 'InputFormat', formats{k});
            time_dt(idx) = tmp;
        catch
        end
    end
    idx = isnat(time_dt);
    if any(idx)
        try
            time_dt(idx) = datetime(raw_time(idx));
        catch
        end
    end
end

function dataset_experiment_plan = buildDatasetDailyExperimentPlan(selected_day_indices, n_variants_per_scenario)
    % Experiment plan ordered as:
    %   experiment_01 -> all real days
    %   experiment_02 -> all real days
    %   ...
    % This makes experiment_NN a fixed fault-severity configuration applied
    % consistently across the same meteorological days.
    n_days = numel(selected_day_indices);
    n_total = n_days * n_variants_per_scenario;
    dataset_experiment_plan = repmat(struct( ...
        'day_idx', NaN, ...
        'variant_idx', NaN, ...
        'experiment_idx', NaN), n_total, 1);
    kk = 0;
    for v = 1:n_variants_per_scenario
        for d = 1:n_days
            kk = kk + 1;
            dataset_experiment_plan(kk).day_idx = selected_day_indices(d);
            dataset_experiment_plan(kk).variant_idx = v;
            dataset_experiment_plan(kk).experiment_idx = kk;
        end
    end
end

function [t_profile, datetime_profile, IR_profile, T_profile, H_profile, meteo_params] = ...
    buildRealMeteoVariant(day_segment, Ts_data, plan_entry)

    segment = day_segment;
    t_start = segment.time_dt(1);
    t_end = segment.time_dt(end);
    duration_s = floor(seconds(t_end - t_start));
    if duration_s < Ts_data
        error('Meteorological segment is shorter than one simulation step.');
    end

    t_profile = (0:Ts_data:duration_s)';
    datetime_profile = t_start + seconds(t_profile);
    t_original = seconds(segment.time_dt - t_start);
    method = segment.interpolation_method;

    % Interpolate only inside the measured time span. No extrapolation is used.
    IR_profile = interp1(t_original, segment.IR, t_profile, method);
    T_profile  = interp1(t_original, segment.T,  t_profile, method);
    H_profile  = interp1(t_original, segment.H,  t_profile, method);

    % Preserve the resampled meteorological variables as close as possible to
    % the source data. In particular, do not clip negative irradiance here:
    % these values may be real sensor offsets and are exported in signals.csv.
    %
    % Any physically cleaned or numerically protected versions needed by Simulink
    % are built later as separate internal signals.
    IR_profile = fillmissing(IR_profile, 'linear', 'EndValues', 'nearest');
    T_profile  = fillmissing(T_profile,  'linear', 'EndValues', 'nearest');
    H_profile  = fillmissing(H_profile,  'linear', 'EndValues', 'nearest');

    daylight_idx = find(IR_profile > 50);
    if isempty(daylight_idx)
        sunrise_h = NaN;
        sunset_h = NaN;
        day_length_h = 0;
    else
        sunrise_h = t_profile(daylight_idx(1))/3600;
        sunset_h = t_profile(daylight_idx(end))/3600;
        day_length_h = max(0, sunset_h - sunrise_h);
    end

    IR_max = max(IR_profile);
    meteo_params = struct();
    meteo_params.source_mode = 'real_mendeley';
    meteo_params.dataset_label = segment.dataset_label;
    meteo_params.day_idx = plan_entry.day_idx;
    meteo_params.variant_idx = plan_entry.variant_idx;
    meteo_params.experiment_idx = plan_entry.experiment_idx;
    meteo_params.source_file = segment.source_file;
    meteo_params.relative_source_folder = segment.relative_source_folder;
    meteo_params.source_stem = segment.source_stem;
    meteo_params.real_day = segment.real_day;
    meteo_params.segment_label = segment.segment_label;
    meteo_params.original_start = t_start;
    meteo_params.original_end = t_end;
    meteo_params.original_median_step_s = segment.original_median_step_s;
    meteo_params.interpolation_method = method;
    meteo_params.n_original_samples = segment.n_original_samples;
    meteo_params.segment_duration_s = duration_s;
    meteo_params.season_type = 'measured_real_day';
    meteo_params.sunrise_h = sunrise_h;
    meteo_params.sunset_h = sunset_h;
    meteo_params.day_length_h = day_length_h;
    meteo_params.seasonal_IR_max = IR_max;

    night_temperature = median(T_profile(IR_profile < 20), 'omitnan');
    if isnan(night_temperature)
        night_temperature = min(T_profile, [], 'omitnan');
    end
    meteo_params.T_night = night_temperature;
    meteo_params.T_amp = max(T_profile, [], 'omitnan') - min(T_profile, [], 'omitnan');
    [~, idx_min_T] = min(T_profile);
    [~, idx_max_T] = max(T_profile);
    meteo_params.T_min_hour = t_profile(idx_min_T)/3600;
    meteo_params.T_max_hour = t_profile(idx_max_T)/3600;

    if IR_max >= 800
        day_type = 'measured_clear_or_high_irradiance';
    elseif IR_max >= 400
        day_type = 'measured_mixed_or_cloudy';
    elseif IR_max > 50
        day_type = 'measured_low_irradiance';
    else
        day_type = 'measured_night_or_very_low_irradiance';
    end
    meteo_params.day_type = day_type;
end

function value = randUniform(a, b)
    value = a + (b - a) * rand();
end

function value = randLogUniform(a, b)
    value = 10^(log10(a) + (log10(b) - log10(a)) * rand());
end

function params = randomizeFaultSeverityTemplate(params, scenario_id)
    % Randomize only the fault severity/resistance/template variables.
    % This function is called once per scenario and experiment_NN. The same
    % resulting parameters are then reused for all real meteorological days.
    switch scenario_id
        case 'F0'
            % Healthy reference: no severity parameter.
        case 'F1'
            params.RF1 = 1e12;
            params.open_circuit_model = 'irradiance_suppression';
            params.RF1_interpretation = 'ideal_open_circuit_equivalent_not_used_by_simulink_model';
            % Physical target of the open-circuit equivalent: zero production
            % in the affected string. During simulation this value is raised to
            % the numerical irradiance floor to protect the PV Array block.
            params.IR_f1_physical_target_Wm2 = 0;
            params.IR_f1_min = 0;
        case 'F2'
            params.RF2 = randLogUniform(0.1, 100);
        case 'F3'
            params.RF3 = randLogUniform(0.5, 1000);
        case 'F4'
            params.shading_severity = randUniform(0.10, 0.90);
            params.shading_transition_s = randUniform(10, 40);
        case 'F5'
            params.DEG_final = randUniform(0.05, 0.60);
        case 'F6'
            params.RF6 = randLogUniform(0.5, 100);
            valid_pulses = [120 5; 100 10; 80 15; 60 20; 40 25];
            idx = randi(size(valid_pulses, 1));
            params.Pint = valid_pulses(idx, 1);
            params.Dint = valid_pulses(idx, 2);
        case 'F7'
            params.RF7 = 1000;
            params.arc_episode_scale = randUniform(0.85, 0.95);
            params.arc_time_jitter_s = randi([-2, 2]);
            params.arc_noise_amp = 0.04 + 0.08 * rand();
        case 'F8'
            params.RF8 = randLogUniform(1, 1000);
        case 'F9'
            % The module mismatch is encoded directly in the F9 Simulink model.
            % Do not report randomly selected module names that are not applied
            % physically by the model.
            params.mismatch_level = 'fixed_in_model';
            params.module_mismatch_choice = 'configured_in_model';
        case 'F10'
            params.RF10 = randUniform(10, 100);
        case 'F11'
            params.RF11 = randUniform(20, 80);
            params.RF12 = randUniform(70, 150);
            valid_pulses12 = [120 5; 100 8; 80 10; 75 12; 60 15];
            idx = randi(size(valid_pulses12, 1));
            params.Pint12 = valid_pulses12(idx, 1);
            params.Dint12 = valid_pulses12(idx, 2);
    end
end

function params = assignFaultTimingForDay(params, scenario_id, meteo_params, Ts_data, segment_duration_s)
    % Adapt only the fault activation time to the available measured interval
    % of the current day. Severity parameters are not modified here.
    switch scenario_id
        case 'F0'
            params.timef0 = segment_duration_s;
        case 'F1'
            params.timef1 = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s);
        case 'F2'
            params.timef2 = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s);
        case 'F3'
            params.timef3 = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s);
        case 'F4'
            params.timef4 = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s);
        case 'F5'
            params.timef5 = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s);
        case 'F6'
            params.timef6 = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s);
        case 'F7'
            params.timef7 = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s);
        case 'F8'
            params.timef8 = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s);
        case 'F9'
            % Module mismatch is active from the beginning of the simulated day.
        case 'F10'
            params.timef10 = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s);
        case 'F11'
            [params.timef11, params.timef12] = randomFaultTimePairInsideProduction(meteo_params, Ts_data, 1800, segment_duration_s);
    end
end

function t = randomFaultTimeInsideProduction(meteo_params, Ts_data, segment_duration_s)
    [t_min, t_max] = getProductionWindow(meteo_params, Ts_data, segment_duration_s);
    t = t_min + (t_max - t_min) * rand();
    t = round(t / Ts_data) * Ts_data;
end

function [t_min, t_max] = getProductionWindow(meteo_params, Ts_data, segment_duration_s)
    if isfinite(meteo_params.sunrise_h) && isfinite(meteo_params.sunset_h)
        margin_after_sunrise_h = 0.5;
        margin_before_sunset_h = 0.5;
        t_min = (meteo_params.sunrise_h + margin_after_sunrise_h) * 3600;
        t_max = (meteo_params.sunset_h - margin_before_sunset_h) * 3600;
    else
        t_min = 0.20 * segment_duration_s;
        t_max = 0.80 * segment_duration_s;
    end
    if ~isfinite(t_min) || ~isfinite(t_max) || t_max <= t_min
        t_min = 0.20 * segment_duration_s;
        t_max = 0.80 * segment_duration_s;
    end
    t_min = max(0, min(segment_duration_s, t_min));
    t_max = max(0, min(segment_duration_s, t_max));
    if t_max <= t_min
        t_min = 0;
        t_max = max(Ts_data, segment_duration_s);
    end
    t_min = round(t_min / Ts_data) * Ts_data;
    t_max = round(t_max / Ts_data) * Ts_data;
end

function [t1, t2] = randomFaultTimePairInsideProduction(meteo_params, Ts_data, min_separation_s, segment_duration_s)
    [t_min, t_max] = getProductionWindow(meteo_params, Ts_data, segment_duration_s);
    min_separation_s = min(min_separation_s, max(Ts_data, 0.25*(t_max - t_min)));
    min_separation_s = round(min_separation_s / Ts_data) * Ts_data;
    if t_max - t_min <= min_separation_s
        t1 = t_min;
        t2 = t_max;
        return
    end
    t1_max = t_max - min_separation_s;
    t1 = t_min + (t1_max - t_min) * rand();
    t1 = round(t1 / Ts_data) * Ts_data;
    t2_min = t1 + min_separation_s;
    t2 = t2_min + (t_max - t2_min) * rand();
    t2 = round(t2 / Ts_data) * Ts_data;
end
