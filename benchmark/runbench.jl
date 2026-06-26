import Pkg
Pkg.activate(@__DIR__)
const Target_Package_Path = abspath(get(ENV, "BENCH_TARGET_PATH", joinpath(@__DIR__, "..")))
if haskey(ENV, "BENCH_TARGET_PATH")
    Pkg.develop(path=Target_Package_Path)
    Pkg.instantiate()
end

using BenchmarkTools, Dates, SHA, JSON, UUIDs
using DBInterface, SQLite

# ⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄⌄
# write your benchmark code here
include(joinpath(@__DIR__, "benchmarks.jl"))
const Benchledger_Metadata_Defaults = (
    name="ComponentLogging.jl",
    description="Benchmark history for ComponentLogging.jl",
    project_url="https://github.com/JuliaLogging/ComponentLogging.jl",
    logo_url="",
    logo_url_dark="",
    notes="",
)
# ⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃⌃

const Bench_DB_In_Current_Branch = lowercase(get(ENV, "BENCH_DB_IN_CURRENT_BRANCH", "false")) in ("true", "1", "yes")
const Pages_Branch = "gh-pages"
const Pages_Worktree = abspath(joinpath(tempdir(), "benchledger-pages"))
const Pages_DB_Path = joinpath(Pages_Worktree, "benchmarks", "data", "benchledger.sqlite")

const Results_DB_Path = if haskey(ENV, "BENCH_DB_PATH")
    ENV["BENCH_DB_PATH"]
elseif Bench_DB_In_Current_Branch
    joinpath(@__DIR__, "results.sqlite")
else
    !isdir(Pages_Worktree) && run(`git worktree add $Pages_Worktree $Pages_Branch`)
    Pages_DB_Path
end

function publish_pages_db!()
    if !Bench_DB_In_Current_Branch && !haskey(ENV, "BENCH_DB_PATH")
        run(`git -C $Pages_Worktree add benchmarks/data/benchledger.sqlite`)
        if success(`git -C $Pages_Worktree diff --cached --quiet`)
            println("No benchmark database changes.")
        else
            run(`git -C $Pages_Worktree commit -m "Update benchmark database"`)
            run(`git -C $Pages_Worktree push origin HEAD:$Pages_Branch`)
        end
    end
end

const Benchledger_Schema_Version = "4"

iso_utc_now() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"

struct BenchmarkMetricRow
    benchmark_path::Vector{String}
    benchmark_id::String
    benchmark_label::String
    metric_name::String
    statistic::String
    unit::String
    value::Float64
    better::String
end

function is_git_repository()
    try
        return success(pipeline(`git -C $Target_Package_Path rev-parse --is-inside-work-tree`, stdout=devnull, stderr=devnull))
    catch
        return false
    end
end

function detect_branch(is_git::Bool)
    branch = get(ENV, "BENCH_SOURCE_BRANCH", "")
    !isempty(branch) && return branch

    is_git || return ""
    branch = readchomp(`git -C $Target_Package_Path branch --show-current`)
    !isempty(branch) && return branch
    return ""
end

function parse_string_list_env(name::AbstractString)
    raw = strip(get(ENV, name, ""))
    isempty(raw) && return String[]
    values = strip.(split(replace(raw, '\n' => ','), ','; keepempty=false))
    filter!(!isempty, values)
    values
end

function detect_tags(is_git::Bool)
    tags = parse_string_list_env("BENCH_SOURCE_TAGS")
    !isempty(tags) && return tags
    is_git || return String[]
    tags = readchomp(`git -C $Target_Package_Path tag --points-at HEAD`)
    isempty(tags) ? String[] : split(tags, '\n'; keepempty=false)
end

function detect_commit(is_git::Bool)
    commit = get(ENV, "BENCH_SOURCE_REVISION", "")
    !isempty(commit) && return commit
    is_git ? readchomp(`git -C $Target_Package_Path rev-parse HEAD`) : ""
end

function detect_code_date(is_git::Bool)
    code_date = get(ENV, "BENCH_DATE", "")
    !isempty(code_date) && return code_date
    is_git || return iso_utc_now()

    timestamp = tryparse(Int, readchomp(`git -C $Target_Package_Path show -s --format=%ct HEAD`))
    timestamp === nothing && return iso_utc_now()
    Dates.format(Dates.unix2datetime(timestamp), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
end

function detect_dirty_state(is_git::Bool)
    is_git || return (is_dirty=false, diff_hash="")
    staged_dirty = !success(pipeline(`git -C $Target_Package_Path diff --cached --quiet`, stdout=devnull, stderr=devnull))
    unstaged_dirty = !success(pipeline(`git -C $Target_Package_Path diff --quiet`, stdout=devnull, stderr=devnull))

    if !(staged_dirty || unstaged_dirty)
        return (is_dirty=false, diff_hash="")
    else
        staged_diff = staged_dirty ? read(pipeline(ignorestatus(`git -C $Target_Package_Path diff --cached --binary`), stderr=devnull)) : UInt8[]
        unstaged_diff = unstaged_dirty ? read(pipeline(ignorestatus(`git -C $Target_Package_Path diff --binary`), stderr=devnull)) : UInt8[]
        diff_hash = bytes2hex(sha1(vcat(staged_diff, UInt8[0x0a], unstaged_diff)))
        return (is_dirty=true, diff_hash=diff_hash)
    end
end

function detect_cpu_model()
    buf = IOBuffer()
    Sys.cpu_summary(buf)
    lines = split(String(take!(buf)), '\n'; keepempty=false)
    isempty(lines) ? string(Sys.MACHINE) : rstrip(first(lines), [':', ' '])
end

function detect_os_release()
    name = lowercase(string(Sys.KERNEL))
    version = ""
    if Sys.islinux() && isfile("/etc/os-release")
        os_release = Dict{String,String}()
        for line in eachline("/etc/os-release")
            isempty(line) && continue
            startswith(line, '#') && continue
            fields = split(line, '='; limit=2)
            length(fields) == 2 || continue
            os_release[first(fields)] = strip(last(fields), ['"'])
        end
        name = get(os_release, "ID", name)
        version = get(os_release, "VERSION_ID", "")
    elseif Sys.isapple()
        try
            version = readchomp(`sw_vers -productVersion`)
        catch
        end
    end
    (; name, version)
end

function detect_kernel_version()
    if Sys.isunix()
        try
            return readchomp(`uname -r`)
        catch
        end
    end
    return ""
end

function detect_code_state_id(commit::AbstractString, diff_hash::AbstractString, measured_at::AbstractString)
    code_state_id = get(ENV, "BENCH_CODE_STATE_ID", "")
    !isempty(code_state_id) && return code_state_id
    if !isempty(commit)
        return isempty(diff_hash) ? commit : string(commit, "+", diff_hash)
    else
        return string("local+", bytes2hex(sha256(codeunits(measured_at))))
    end
end

function detect_code_state_label(commit::AbstractString)
    label = get(ENV, "BENCH_CODE_LABEL", "")
    !isempty(label) && return label
    isempty(commit) ? "local" : first(commit, min(7, ncodeunits(commit)))
end

function merge_metadata!(metadata::AbstractDict, override::AbstractDict)
    for (key, value) in pairs(override)
        key_string = String(key)
        if haskey(metadata, key_string) && metadata[key_string] isa AbstractDict && value isa AbstractDict
            merge_metadata!(metadata[key_string], value)
        else
            metadata[key_string] = value
        end
    end
    metadata
end

function parse_metadata_override(name::AbstractString)
    raw = get(ENV, name, "")
    isempty(strip(raw)) && return Dict{String,Any}()
    metadata = JSON.parse(raw)
    metadata isa AbstractDict || error("$(name) must contain a JSON object.")
    metadata
end

function canonical_json(value)
    if value isa AbstractDict
        all(key -> key isa AbstractString, keys(value)) || error("Metadata object keys must be strings.")
        entries = String[]
        for key in sort!(String[String(key) for key in keys(value)])
            push!(entries, string(JSON.json(key), ":", canonical_json(value[key])))
        end
        return string("{", join(entries, ","), "}")
    elseif value isa Tuple || value isa AbstractVector
        return string("[", join((canonical_json(item) for item in value), ","), "]")
    elseif value isa AbstractFloat
        isfinite(value) || error("Metadata floating-point values must be finite.")
        return JSON.json(value)
    elseif value isa Nothing || value isa Bool || value isa Integer || value isa AbstractString
        return JSON.json(value)
    else
        error("Unsupported metadata value type: $(typeof(value)).")
    end
end

function make_source_context(measured_at::AbstractString)
    is_git = is_git_repository()
    branch = detect_branch(is_git)
    tags = detect_tags(is_git)
    commit = detect_commit(is_git)
    code_date = detect_code_date(is_git)
    (is_dirty, diff_hash) = detect_dirty_state(is_git)
    code_state_id = detect_code_state_id(commit, diff_hash, measured_at)
    label = detect_code_state_label(commit)
    (; is_git, branch, tags, commit, code_date, is_dirty, diff_hash, code_state_id, label)
end

function make_code_state(source)
    source_metadata = Dict{String,Any}(
        "kind" => source.is_git || !isempty(source.commit) ? "git" : "working_tree",
        "dirty" => source.is_dirty,
    )
    !isempty(source.commit) && (source_metadata["revision"] = source.commit)
    !isempty(source.diff_hash) && (source_metadata["diff_digest"] = source.diff_hash)
    metadata = Dict{String,Any}("source" => source_metadata)
    merge_metadata!(metadata, parse_metadata_override("BENCH_CODE_STATE_METADATA"))
    (; code_state_id=source.code_state_id, label=source.label, code_date=source.code_date, metadata=canonical_json(metadata))
end

function make_environment()
    cpu_model = detect_cpu_model()
    os_release = detect_os_release()
    kernel_version = detect_kernel_version()
    os_metadata = Dict{String,Any}("name" => os_release.name)
    !isempty(os_release.version) && (os_metadata["version"] = os_release.version)
    kernel_metadata = Dict{String,Any}("name" => lowercase(string(Sys.KERNEL)))
    !isempty(kernel_version) && (kernel_metadata["version"] = kernel_version)
    platform_metadata = Dict{String,Any}(
        "os" => os_metadata,
        "kernel" => kernel_metadata,
        "architecture" => string(Sys.ARCH),
    )
    runtime_metadata = Dict{String,Any}(
        "name" => "Julia",
        "version" => string(VERSION),
    )
    metadata = Dict{String,Any}(
        "platform" => platform_metadata,
        "hardware" => Dict{String,Any}(
            "cpu" => Dict{String,Any}(
                "model" => cpu_model,
                "logical_threads" => Sys.CPU_THREADS,
            ),
        ),
        "runtime" => runtime_metadata,
        "benchmark" => Dict{String,Any}(
            "framework" => Dict{String,Any}(
                "name" => "BenchmarkTools.jl",
                "version" => string(Base.pkgversion(BenchmarkTools)),
            ),
        ),
        "execution" => Dict{String,Any}(
            "processes" => 1,
            "threads" => Threads.nthreads(),
        ),
    )
    merge_metadata!(metadata, parse_metadata_override("BENCH_ENVIRONMENT_METADATA"))
    metadata_json = canonical_json(metadata)
    identity_metadata = Dict{String,Any}(
        "platform" => Dict{String,Any}("os" => os_metadata, "architecture" => string(Sys.ARCH)),
        "hardware" => Dict{String,Any}("cpu" => Dict{String,Any}("model" => cpu_model, "logical_threads" => Sys.CPU_THREADS)),
        "runtime" => runtime_metadata,
        "benchmark" => Dict{String,Any}("framework" => Dict{String,Any}("name" => "BenchmarkTools.jl", "version" => string(Base.pkgversion(BenchmarkTools)))),
        "execution" => Dict{String,Any}("processes" => 1, "threads" => Threads.nthreads()),
    )
    identity_json = canonical_json(identity_metadata)
    environment_id = string("env-", bytes2hex(sha256(codeunits(identity_json))))
    label = get(ENV, "BENCH_ENVIRONMENT_LABEL", "")
    isempty(label) && (label = string(cpu_model, " / Julia ", VERSION, " / ", Threads.nthreads(), " threads"))
    (; environment_id, label, metadata=metadata_json)
end

function make_run_context(source, code_state, environment, measured_at::AbstractString)
    source_metadata = Dict{String,Any}()
    !isempty(source.branch) && (source_metadata["branch"] = source.branch)
    !isempty(source.tags) && (source_metadata["tags"] = source.tags)
    metadata = Dict{String,Any}(
        "writer" => Dict{String,Any}(
            "name" => "BenchLedger Julia template",
            "version" => Benchledger_Schema_Version,
        ),
    )
    !isempty(source_metadata) && (metadata["source"] = source_metadata)
    merge_metadata!(metadata, parse_metadata_override("BENCH_RUN_METADATA"))
    return (
        run_id=string(uuid4()),
        code_state_id=code_state.code_state_id,
        environment_id=environment.environment_id,
        measured_at,
        notes=get(ENV, "BENCH_NOTES", ""),
        metadata=canonical_json(metadata),
    )
end

function init_database!(db)
    SQLite.execute(db,
        """
CREATE TABLE IF NOT EXISTS benchledger_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL)
""")
    SQLite.execute(db,
        """
CREATE TABLE IF NOT EXISTS benchmark_code_states (
    code_state_id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    code_date TEXT NOT NULL,
    metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)))
""")
    SQLite.execute(db,
        """
CREATE TABLE IF NOT EXISTS benchmark_environments (
    environment_id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)))
""")
    SQLite.execute(db,
        """
CREATE TABLE IF NOT EXISTS benchmark_runs (
    run_id TEXT PRIMARY KEY,
    code_state_id TEXT NOT NULL,
    environment_id TEXT NOT NULL,
    measured_at TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '',
    metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)),
    FOREIGN KEY (code_state_id) REFERENCES benchmark_code_states(code_state_id) ON DELETE RESTRICT,
    FOREIGN KEY (environment_id) REFERENCES benchmark_environments(environment_id) ON DELETE RESTRICT)
""")
    SQLite.execute(db,
        """
CREATE TABLE IF NOT EXISTS benchmark_results (
    run_id TEXT NOT NULL,
    benchmark_id TEXT NOT NULL,
    benchmark_path TEXT NOT NULL,
    benchmark_label TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    statistic TEXT NOT NULL,
    unit TEXT NOT NULL,
    value REAL NOT NULL,
    better TEXT NOT NULL CHECK (better IN ('lower', 'higher', 'neutral')),
    PRIMARY KEY (run_id, benchmark_id, metric_name, statistic),
    FOREIGN KEY (run_id) REFERENCES benchmark_runs(run_id) ON DELETE CASCADE)
""")
    SQLite.execute(db,
        """
CREATE VIEW IF NOT EXISTS benchmark_results_latest AS
SELECT
    run_id,
    code_state_id,
    environment_id,
    code_label,
    environment_label,
    code_date,
    measured_at,
    notes,
    code_state_metadata,
    environment_metadata,
    run_metadata,
    benchmark_path,
    benchmark_id,
    benchmark_label,
    metric_name,
    statistic,
    unit,
    value,
    better
FROM (
    SELECT
        runs.run_id AS run_id,
        runs.code_state_id AS code_state_id,
        runs.environment_id AS environment_id,
        code_states.label AS code_label,
        environments.label AS environment_label,
        code_states.code_date AS code_date,
        runs.measured_at AS measured_at,
        runs.notes AS notes,
        code_states.metadata AS code_state_metadata,
        environments.metadata AS environment_metadata,
        runs.metadata AS run_metadata,
        results.benchmark_path AS benchmark_path,
        results.benchmark_id AS benchmark_id,
        results.benchmark_label AS benchmark_label,
        results.metric_name AS metric_name,
        results.statistic AS statistic,
        results.unit AS unit,
        results.value AS value,
        results.better AS better,
        ROW_NUMBER() OVER (
            PARTITION BY
                runs.code_state_id,
                runs.environment_id,
                results.benchmark_id,
                results.metric_name,
                results.statistic
            ORDER BY runs.measured_at DESC, results.run_id DESC
        ) AS rn
    FROM benchmark_results AS results
    JOIN benchmark_runs AS runs USING (run_id)
    JOIN benchmark_code_states AS code_states USING (code_state_id)
    JOIN benchmark_environments AS environments USING (environment_id)
)
WHERE rn = 1
""")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_code_states_code_date_index ON benchmark_code_states (code_date)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_measured_at_index ON benchmark_runs (measured_at)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_code_state_id_index ON benchmark_runs (code_state_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_environment_id_index ON benchmark_runs (environment_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_latest_partition_index ON benchmark_runs (code_state_id, environment_id, measured_at, run_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_metric_lookup_index ON benchmark_results (benchmark_id, metric_name, statistic)")
end

function make_metadata!(db, context)
    metadata = (
        schema_version=Benchledger_Schema_Version,
        name=Benchledger_Metadata_Defaults.name,
        description=Benchledger_Metadata_Defaults.description,
        project_url=Benchledger_Metadata_Defaults.project_url,
        logo_url=Benchledger_Metadata_Defaults.logo_url,
        logo_url_dark=Benchledger_Metadata_Defaults.logo_url_dark,
        updated_at=context.measured_at,
        notes=Benchledger_Metadata_Defaults.notes,
    )
    for (key, value) in pairs(metadata)
        DBInterface.execute(db, """
INSERT INTO benchledger_metadata (key, value)
VALUES (?, ?)
ON CONFLICT (key) DO UPDATE SET value = excluded.value
""", (String(key), String(value)))
    end
    DBInterface.execute(db, """
INSERT INTO benchledger_metadata (key, value)
VALUES ('created_at', ?)
ON CONFLICT (key) DO NOTHING
""", (context.measured_at,))
end

function validate_table_columns(db::SQLite.DB, path::AbstractString, table::AbstractString, required_columns)
    columns = Set{String}()
    for row in DBInterface.execute(db, "PRAGMA table_info($(table))")
        push!(columns, String(row.name))
    end
    isempty(columns) && error("Unsupported BenchLedger database in $(path): missing $(table).")
    for column in required_columns
        column in columns || error("Unsupported $(table) layout in $(path): missing $(column).")
    end
end

function validate_schema_version!(db::SQLite.DB, path::AbstractString)
    metadata_table = iterate(DBInterface.execute(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'benchledger_metadata'"))
    metadata_table === nothing && error("Unsupported BenchLedger database in $(path): missing benchledger_metadata.")

    # Avoid collect(...) here: SQLite.jl can materialize this single-column result as missing.
    schema_iter = iterate(DBInterface.execute(db, "SELECT value FROM benchledger_metadata WHERE key = 'schema_version'"))
    if schema_iter === nothing
        error("Unsupported BenchLedger database in $(path): missing benchledger_metadata.schema_version.")
    end
    schema_version = String(schema_iter[1].value)
    schema_version == Benchledger_Schema_Version || error("Unsupported BenchLedger schema version in $(path): $(schema_version). Expected $(Benchledger_Schema_Version). This experimental release does not migrate older databases.")

    validate_table_columns(db, path, "benchmark_code_states", ("code_state_id", "label", "code_date", "metadata"))
    validate_table_columns(db, path, "benchmark_environments", ("environment_id", "label", "metadata"))
    validate_table_columns(db, path, "benchmark_runs", ("run_id", "code_state_id", "environment_id", "measured_at", "notes", "metadata"))
    validate_table_columns(db, path, "benchmark_results", ("run_id", "benchmark_id", "benchmark_path", "benchmark_label", "metric_name", "statistic", "unit", "value", "better"))
end

function open_database(path::AbstractString, context)
    mkpath(dirname(path))
    is_new_db = !isfile(path)
    db = SQLite.DB(path)
    SQLite.execute(db, "PRAGMA foreign_keys=ON")
    SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA synchronous=NORMAL")
    !is_new_db && validate_schema_version!(db, path)
    init_database!(db)
    make_metadata!(db, context)
    db
end

function metric_rows(benchmark_path::Vector{String}, trial::BenchmarkTools.Trial)
    stats = median(trial)
    best = minimum(trial)
    benchmark_id_value = benchmark_id(benchmark_path)
    benchmark_label_value = join(benchmark_path, " / ")
    [
        BenchmarkMetricRow(benchmark_path, benchmark_id_value, benchmark_label_value, "time", "median", "ns", Float64(stats.time), "lower"),
        BenchmarkMetricRow(benchmark_path, benchmark_id_value, benchmark_label_value, "time", "min", "ns", Float64(best.time), "lower"),
        BenchmarkMetricRow(benchmark_path, benchmark_id_value, benchmark_label_value, "memory", "min", "bytes", Float64(best.memory), "lower"),
        BenchmarkMetricRow(benchmark_path, benchmark_id_value, benchmark_label_value, "allocs", "min", "count", Float64(best.allocs), "lower"),
    ]
end

function metric_rows(benchmark_path::Vector{String}, value)
    error("Unsupported benchmark leaf at $(join(benchmark_path, " / ")): $(typeof(value)). Provide a BenchmarkTools.Trial or normalize custom results into BenchmarkMetricRow rows.")
end

metric_rows(rows::Vector{BenchmarkMetricRow}) = rows
metric_rows(rows::AbstractVector{<:BenchmarkMetricRow}) = BenchmarkMetricRow[row for row in rows]
metric_rows(rows::AbstractVector{<:NamedTuple}) = [metric_row(row) for row in rows]
metric_rows(results::Tuple{<:AbstractVector{<:NamedTuple},<:BenchmarkGroup}) = vcat(metric_rows(results[1]), metric_rows(results[2]))

function flatten_trial_rows(results::BenchmarkGroup, prefix::Vector{String}=String[])
    rows = Tuple{Vector{String},Any}[]
    for (name, value) in pairs(results)
        benchmark_path = [prefix; String(name)]
        if value isa BenchmarkGroup
            append!(rows, flatten_trial_rows(value, benchmark_path))
        else
            push!(rows, (benchmark_path, value))
        end
    end
    rows
end

function metric_rows(results::BenchmarkGroup)
    rows = BenchmarkMetricRow[]
    for (benchmark_path, value) in flatten_trial_rows(results)
        append!(rows, metric_rows(benchmark_path, value))
    end
    rows
end

function benchmark_id(path::Vector{String})
    encoded = IOBuffer()
    for segment in path
        write(encoded, string(sizeof(segment), ":"))
        write(encoded, segment)
    end
    bytes2hex(sha1(take!(encoded)))
end

function required_metric_field(row::NamedTuple, field::Symbol)
    hasproperty(row, field) || error("Missing required metric field: $(field).")
    getproperty(row, field)
end

function metric_row(row::NamedTuple)
    benchmark_path = hasproperty(row, :benchmark_path) ? begin
        value = getproperty(row, :benchmark_path)
        value isa AbstractVector || error("benchmark_path must be a vector of strings.")
        String[String(segment) for segment in value]
    end : error("Missing required metric field: benchmark_path.")
    benchmark_id_value = hasproperty(row, :benchmark_id) ? String(getproperty(row, :benchmark_id)) : benchmark_id(benchmark_path)
    benchmark_label_value = hasproperty(row, :benchmark_label) ? String(getproperty(row, :benchmark_label)) : join(benchmark_path, " / ")
    BenchmarkMetricRow(
        benchmark_path,
        isempty(benchmark_id_value) ? benchmark_id(benchmark_path) : benchmark_id_value,
        isempty(benchmark_label_value) ? join(benchmark_path, " / ") : benchmark_label_value,
        String(required_metric_field(row, :metric_name)),
        String(required_metric_field(row, :statistic)),
        String(required_metric_field(row, :unit)),
        Float64(required_metric_field(row, :value)),
        String(required_metric_field(row, :better)),
    )
end

function validate_metric_rows(rows::AbstractVector{<:BenchmarkMetricRow})
    seen = Set{Tuple{String,String,String}}()
    for row in rows
        isempty(row.benchmark_id) && error("benchmark_id must not be empty.")
        isempty(row.benchmark_label) && error("benchmark_label must not be empty.")
        isempty(row.metric_name) && error("metric_name must not be empty.")
        isempty(row.statistic) && error("statistic must not be empty.")
        isfinite(row.value) || error("Metric value must be finite for $(row.benchmark_label) / $(row.metric_name) / $(row.statistic).")
        row.better in ("lower", "higher", "neutral") || error("Unsupported better value for $(row.benchmark_label): $(row.better). Expected lower, higher, or neutral.")
        key = (row.benchmark_id, row.metric_name, row.statistic)
        key in seen && error("Duplicate metric row in the same run for benchmark_id=$(row.benchmark_id), metric_name=$(row.metric_name), statistic=$(row.statistic).")
        push!(seen, key)
    end
    rows
end

function benchmark_result_row(run_id::AbstractString, row::BenchmarkMetricRow)
    (
        row.benchmark_id,
        run_id,
        JSON.json(row.benchmark_path),
        row.benchmark_label,
        row.metric_name,
        row.statistic,
        row.unit,
        row.value,
        row.better,
    )
end

function persist_labeled_entity!(db::SQLite.DB, table::AbstractString, id_column::AbstractString, id_value::AbstractString, metadata::AbstractString, label::AbstractString; code_date::Union{Nothing,AbstractString}=nothing)
    code_date === nothing ? DBInterface.execute(db, "INSERT INTO $(table) ($(id_column), label, metadata) VALUES (?, ?, ?) ON CONFLICT ($(id_column)) DO NOTHING", (id_value, label, metadata)) :
    DBInterface.execute(db, "INSERT INTO $(table) ($(id_column), label, code_date, metadata) VALUES (?, ?, ?, ?) ON CONFLICT ($(id_column)) DO NOTHING", (id_value, label, code_date, metadata))
    
    row_iter = iterate(DBInterface.execute(db, code_date === nothing ? "SELECT label, metadata FROM $(table) WHERE $(id_column) = ?" : "SELECT label, code_date, metadata FROM $(table) WHERE $(id_column) = ?", (id_value,)))
    row_iter === nothing && error("Failed to persist $(table) $(id_value).")
    row = row_iter[1]
    code_date === nothing || String(row.code_date) == code_date || error("Conflicting code_date for $(id_column)=$(id_value).")
    String(row.metadata) == metadata || error("Conflicting metadata for $(id_column)=$(id_value).")
    String(row.label) == label || DBInterface.execute(db, "UPDATE $(table) SET label = ? WHERE $(id_column) = ?", (label, id_value))
end

function insert_run!(db::SQLite.DB, context)
    DBInterface.execute(db, """
INSERT INTO benchmark_runs (
    run_id,
    code_state_id,
    environment_id,
    measured_at,
    notes,
    metadata
)
VALUES (?, ?, ?, ?, ?, ?)
""", (
            context.run_id,
            context.code_state_id,
            context.environment_id,
            context.measured_at,
            context.notes,
            context.metadata,
        ))
end

function insert_metric_rows!(stmt::SQLite.Stmt, rows::AbstractVector{<:BenchmarkMetricRow}, run_id::AbstractString)
    for row in rows
        SQLite.execute(stmt, benchmark_result_row(run_id, row))
    end
    length(rows)
end

function persist_metric_rows!(db::SQLite.DB, rows::AbstractVector{<:BenchmarkMetricRow}, code_state, environment, context)
    stmt = SQLite.Stmt(db,
        """
INSERT INTO benchmark_results (
    benchmark_id,
    run_id,
    benchmark_path,
    benchmark_label,
    metric_name,
    statistic,
    unit,
    value,
    better
)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
""")
    SQLite.execute(db, "BEGIN IMMEDIATE TRANSACTION")
    try
        persist_labeled_entity!(db, "benchmark_code_states", "code_state_id", code_state.code_state_id, code_state.metadata, code_state.label; code_date=code_state.code_date)
        persist_labeled_entity!(db, "benchmark_environments", "environment_id", environment.environment_id, environment.metadata, environment.label)
        insert_run!(db, context)
        count = insert_metric_rows!(stmt, validate_metric_rows(rows), context.run_id)
        DBInterface.close!(stmt)
        SQLite.execute(db, "COMMIT")
        return count
    catch err
        DBInterface.close!(stmt)
        SQLite.execute(db, "ROLLBACK")
        rethrow(err)
    end
end

measured_at = iso_utc_now()
source = make_source_context(measured_at)
code_state = make_code_state(source)
environment = make_environment()
context = make_run_context(source, code_state, environment, measured_at)
db = open_database(Results_DB_Path, context)
count = persist_metric_rows!(db, metric_rows(results), code_state, environment, context)
close(db)
publish_pages_db!()

println("Wrote $count benchmark rows to $(Results_DB_Path)")
