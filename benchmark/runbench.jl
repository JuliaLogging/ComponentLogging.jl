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

const Results_DB_Path = let path = strip(get(ENV, "BENCH_DB_PATH", ""))
    isempty(path) && error("BENCH_DB_PATH must be set to the SQLite database file to update.")
    abspath(path)
end

const Benchledger_Schema_Version = "5"

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
    is_git || return ""
    readchomp(`git -C $Target_Package_Path branch --show-current`)
end

function detect_tags(is_git::Bool)
    is_git || return String[]
    tags = readchomp(`git -C $Target_Package_Path tag --points-at HEAD`)
    isempty(tags) ? String[] : split(tags, '\n'; keepempty=false)
end

detect_commit(is_git::Bool) = is_git ? readchomp(`git -C $Target_Package_Path rev-parse HEAD`) : ""

function detect_code_date(is_git::Bool)
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

function loaded_module_by_name(name::Symbol)
    try
        for _module in values(Base.loaded_modules)
            nameof(_module) == name && return _module
        end
    catch
    end
    nothing
end

function module_version_string(_module::Module)
    try
        version = Base.pkgversion(_module)
        version === nothing ? "" : string(version)
    catch
        ""
    end
end

function module_call_version(_module::Module, name::Symbol)
    isdefined(_module, name) || return ""
    try
        string(getfield(_module, name)())
    catch
        ""
    end
end

function detect_nvidia_gpu()
    output = try
        readchomp(`nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits`)
    catch
        return (gpus=Dict{String,Any}[], driver_version="")
    end
    isempty(strip(output)) && return (gpus=Dict{String,Any}[], driver_version="")

    counts = Dict{Tuple{String,Int},Int}()
    driver_versions = Set{String}()
    for line in split(output, '\n'; keepempty=false)
        fields = strip.(split(line, ','; limit=3))
        length(fields) >= 2 || continue
        model = fields[1]
        memory_mib = tryparse(Int, fields[2])
        memory_mib === nothing && continue
        key = (model, memory_mib * 1024^2)
        counts[key] = get(counts, key, 0) + 1
        length(fields) == 3 && !isempty(fields[3]) && push!(driver_versions, fields[3])
    end

    gpus = Dict{String,Any}[]
    for (model, memory_bytes) in sort!(collect(keys(counts)); by=x -> (x[1], x[2]))
        push!(gpus, Dict{String,Any}(
            "vendor" => "NVIDIA",
            "model" => model,
            "memory_bytes" => memory_bytes,
            "count" => counts[(model, memory_bytes)],
        ))
    end
    driver_version = isempty(driver_versions) ? "" : first(sort!(collect(driver_versions)))
    (; gpus, driver_version)
end

function visible_gpu_count(detected_count::Int)
    for name in ("CUDA_VISIBLE_DEVICES", "ROCR_VISIBLE_DEVICES", "HIP_VISIBLE_DEVICES")
        haskey(ENV, name) || continue
        raw = strip(ENV[name])
        isempty(raw) && return 0
        lowercase(raw) in ("-1", "none", "nodevfiles") && return 0
        devices = filter(!isempty, strip.(split(raw, ','; keepempty=false)))
        return length(devices)
    end
    detected_count > 0 ? detected_count : nothing
end

function detect_gpu_interface()
    for (module_name, display_name) in ((:CUDA, "CUDA.jl"), (:AMDGPU, "AMDGPU.jl"), (:Metal, "Metal.jl"), (:oneAPI, "oneAPI.jl"))
        _module = loaded_module_by_name(module_name)
        _module === nothing && continue
        interface = Dict{String,Any}("name" => display_name)
        version = module_version_string(_module)
        !isempty(version) && (interface["version"] = version)
        return interface
    end
    return Dict{String,Any}()
end

function detect_gpu_runtime(nvidia_driver_version::AbstractString)
    runtime = Dict{String,Any}()
    cuda = loaded_module_by_name(:CUDA)
    amdgpu = loaded_module_by_name(:AMDGPU)

    if cuda !== nothing
        runtime["backend"] = "CUDA"
        driver_version = module_call_version(cuda, :driver_version)
        isempty(driver_version) && (driver_version = String(nvidia_driver_version))
        !isempty(driver_version) && (runtime["driver"] = Dict{String,Any}("version" => driver_version))

        runtime_version = module_call_version(cuda, :runtime_version)
        runtime_info = Dict{String,Any}("name" => "CUDA")
        !isempty(runtime_version) && (runtime_info["version"] = runtime_version)
        runtime["runtime"] = runtime_info
    elseif amdgpu !== nothing
        runtime["backend"] = "ROCm"
        runtime_info = Dict{String,Any}("name" => "ROCm")
        runtime_version = module_call_version(amdgpu, :runtime_version)
        !isempty(runtime_version) && (runtime_info["version"] = runtime_version)
        runtime["runtime"] = runtime_info
    elseif !isempty(nvidia_driver_version)
        runtime["driver"] = Dict{String,Any}("version" => String(nvidia_driver_version))
    end

    return runtime
end

function normalize_code_state_id(value::AbstractString)
    startswith(value, "code-") && return String(value)
    startswith(value, "local+") && return string("code-local-", replace(String(value), "local+" => ""; count=1))
    string("code-", value)
end

function make_code_state_id(identity::AbstractDict, measured_at::AbstractString)
    source = get(identity, "source", Dict{String,Any}())
    revision = source isa AbstractDict ? String(get(source, "revision", "")) : ""
    diff_digest = source isa AbstractDict ? String(get(source, "diff_digest", "")) : ""
    if !isempty(revision)
        return normalize_code_state_id(isempty(diff_digest) ? revision : string(revision, "+", diff_digest))
    end
    string("code-local-", bytes2hex(sha256(codeunits(measured_at))))
end

function detect_code_state_label(commit::AbstractString)
    isempty(commit) ? "local" : first(commit, min(7, ncodeunits(commit)))
end

function merge_metadata!(metadata::AbstractDict, override::AbstractDict; path::AbstractString="")
    for (key, value) in pairs(override)
        key_string = String(key)
        key_path = isempty(path) ? key_string : string(path, ".", key_string)

        if !haskey(metadata, key_string)
            metadata[key_string] = value
        elseif metadata[key_string] isa AbstractDict && value isa AbstractDict
            merge_metadata!(metadata[key_string], value; path=key_path)
        elseif metadata[key_string] != value
            error("Conflicting metadata value at $(key_path): existing=$(repr(metadata[key_string])), new=$(repr(value)).")
        end
    end
    return metadata
end

function parse_object_env(name::AbstractString)
    raw = strip(get(ENV, name, ""))
    isempty(raw) && return Dict{String,Any}()
    value = JSON.parse(raw; dicttype=Dict{String,Any})
    value isa AbstractDict || error("$(name) must contain a JSON object.")
    Dict{String,Any}(String(key) => item for (key, item) in pairs(value))
end

function validate_object_keys(value::AbstractDict, name::AbstractString, allowed)
    allowed_set = Set(String.(allowed))
    unknown = sort!(String[key for key in keys(value) if String(key) ∉ allowed_set])
    isempty(unknown) || error("Unsupported $(name) field(s): $(join(unknown, ", ")).")
    value
end

function object_field(value::AbstractDict, key::AbstractString, name::AbstractString)
    field = get(value, key, nothing)
    field === nothing && return Dict{String,Any}()
    field isa AbstractDict || error("$(name).$(key) must be a JSON object.")
    Dict{String,Any}(String(k) => item for (k, item) in pairs(field))
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

function make_source_context()
    is_git = is_git_repository()
    branch = detect_branch(is_git)
    tags = detect_tags(is_git)
    commit = detect_commit(is_git)
    code_date = detect_code_date(is_git)
    (is_dirty, diff_hash) = detect_dirty_state(is_git)
    label = detect_code_state_label(commit)
    (; is_git, branch, tags, commit, code_date, is_dirty, diff_hash, label)
end

function make_code_state(source, measured_at::AbstractString)
    override = validate_object_keys(parse_object_env("BENCH_CODE_STATE"), "BENCH_CODE_STATE", ("id", "label", "code_date", "identity", "metadata"))

    source_identity = Dict{String,Any}(
        "kind" => source.is_git || !isempty(source.commit) ? "git" : "working_tree",
    )
    !isempty(source.commit) && (source_identity["revision"] = source.commit)
    !isempty(source.diff_hash) && (source_identity["diff_digest"] = source.diff_hash)
    identity = Dict{String,Any}("source" => source_identity)
    merge_metadata!(identity, object_field(override, "identity", "BENCH_CODE_STATE"))

    metadata = Dict{String,Any}("source" => Dict{String,Any}("dirty" => source.is_dirty))
    merge_metadata!(metadata, object_field(override, "metadata", "BENCH_CODE_STATE"))

    id = haskey(override, "id") ? normalize_code_state_id(String(override["id"])) : make_code_state_id(identity, measured_at)
    label = haskey(override, "label") ? String(override["label"]) : source.label
    code_date = haskey(override, "code_date") ? String(override["code_date"]) : source.code_date
    (; id, label, code_date, identity=canonical_json(identity), metadata=canonical_json(metadata))
end

function make_environment()
    override = validate_object_keys(parse_object_env("BENCH_ENVIRONMENT"), "BENCH_ENVIRONMENT", ("label", "identity", "metadata"))
    cpu_model = detect_cpu_model()
    os_release = detect_os_release()
    kernel_version = detect_kernel_version()
    nvidia_gpu = detect_nvidia_gpu()

    os_identity = Dict{String,Any}("name" => os_release.name)
    !isempty(os_release.version) && (os_identity["version"] = os_release.version)
    kernel_identity = Dict{String,Any}("name" => lowercase(string(Sys.KERNEL)))
    !isempty(kernel_version) && (kernel_identity["version"] = kernel_version)
    runtime_identity = Dict{String,Any}("name" => "Julia", "version" => string(VERSION))

    hardware_identity = Dict{String,Any}(
        "cpu" => Dict{String,Any}(
            "model" => cpu_model,
            "logical_threads" => Sys.CPU_THREADS,
        ),
    )
    !isempty(nvidia_gpu.gpus) && (hardware_identity["gpu"] = nvidia_gpu.gpus)

    execution_identity = Dict{String,Any}(
        "processes" => 1,
        "threads" => Threads.nthreads(),
    )
    detected_gpu_count = sum(Int(gpu["count"]) for gpu in nvidia_gpu.gpus; init=0)
    visible_gpus = visible_gpu_count(detected_gpu_count)
    visible_gpus === nothing || (execution_identity["gpu_devices"] = Dict{String,Any}("visible" => visible_gpus))

    identity = Dict{String,Any}(
        "runtime" => runtime_identity,
        "platform" => Dict{String,Any}(
            "os" => os_identity,
            "kernel" => kernel_identity,
            "architecture" => string(Sys.ARCH),
        ),
        "hardware" => hardware_identity,
        "execution" => execution_identity,
    )
    gpu_runtime = detect_gpu_runtime(nvidia_gpu.driver_version)
    !isempty(gpu_runtime) && (identity["gpu_runtime"] = gpu_runtime)

    # hardware.gpu, hardware.tpu, and hardware.npu are optional identity fields.
    # TPU, NPU, and non-NVIDIA GPU details can be supplied through BENCH_ENVIRONMENT.identity.
    merge_metadata!(identity, object_field(override, "identity", "BENCH_ENVIRONMENT"))

    metadata = object_field(override, "metadata", "BENCH_ENVIRONMENT")

    identity_json = canonical_json(identity)
    id = string("env-", bytes2hex(sha256(codeunits(identity_json))))
    label = haskey(override, "label") ? String(override["label"]) : string(cpu_model, " / Julia ", VERSION, " / ", Threads.nthreads(), " threads")
    (; id, label, identity=identity_json, metadata=canonical_json(metadata))
end

function make_run_context(source, code_state, environment, measured_at::AbstractString)
    override = validate_object_keys(parse_object_env("BENCH_RUN"), "BENCH_RUN", ("notes", "metadata"))
    source_metadata = Dict{String,Any}()
    !isempty(source.branch) && (source_metadata["branch"] = source.branch)
    !isempty(source.tags) && (source_metadata["tags"] = source.tags)
    metadata = Dict{String,Any}(
        "benchmark" => Dict{String,Any}(
            "framework" => Dict{String,Any}(
                "name" => "BenchmarkTools.jl",
                "version" => string(Base.pkgversion(BenchmarkTools)),
            ),
        ),
        "host" => Dict{String,Any}(
            "hostname" => gethostname(),
        ),
        "writer" => Dict{String,Any}(
            "name" => "BenchLedger Julia template",
            "version" => Benchledger_Schema_Version,
        ),
    )
    gpu_interface = detect_gpu_interface()
    !isempty(gpu_interface) && (metadata["gpu"] = Dict{String,Any}("interface" => gpu_interface))
    !isempty(source_metadata) && (metadata["source"] = source_metadata)
    merge_metadata!(metadata, object_field(override, "metadata", "BENCH_RUN"))
    return (
        id=string(uuid4()),
        code_state_id=code_state.id,
        environment_id=environment.id,
        measured_at,
        notes=haskey(override, "notes") ? String(override["notes"]) : "",
        metadata=canonical_json(metadata),
    )
end

function create_latest_view_v5!(db)
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
            code_state_identity,
            code_state_metadata,
            environment_identity,
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
                runs.id AS run_id,
                runs.code_state_id,
                runs.environment_id,
                code_states.label AS code_label,
                environments.label AS environment_label,
                code_states.code_date,
                runs.measured_at,
                runs.notes,
                code_states.identity AS code_state_identity,
                code_states.metadata AS code_state_metadata,
                environments.identity AS environment_identity,
                environments.metadata AS environment_metadata,
                runs.metadata AS run_metadata,
                results.benchmark_path,
                results.benchmark_id,
                results.benchmark_label,
                results.metric_name,
                results.statistic,
                results.unit,
                results.value,
                results.better,
                ROW_NUMBER() OVER (
                    PARTITION BY runs.code_state_id, runs.environment_id,
                        results.benchmark_id, results.metric_name, results.statistic
                    ORDER BY runs.measured_at DESC, runs.id DESC
                ) AS rn
            FROM benchmark_results AS results
            JOIN benchmark_runs AS runs ON runs.id = results.run_id
            JOIN benchmark_code_states AS code_states ON code_states.id = runs.code_state_id
            JOIN benchmark_environments AS environments ON environments.id = runs.environment_id
        )
        WHERE rn = 1
        """)
end

function create_v5_indexes!(db)
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_code_states_code_date_index ON benchmark_code_states (code_date)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_measured_at_index ON benchmark_runs (measured_at)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_code_state_id_index ON benchmark_runs (code_state_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_environment_id_index ON benchmark_runs (environment_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_latest_partition_index ON benchmark_runs (code_state_id, environment_id, measured_at, id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_metric_lookup_index ON benchmark_results (benchmark_id, metric_name, statistic)")
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
            id TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            code_date TEXT NOT NULL,
            identity TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(identity)),
            metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)))
        """)
    SQLite.execute(db,
        """
        CREATE TABLE IF NOT EXISTS benchmark_environments (
            id TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            identity TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(identity)),
            metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)))
        """)
    SQLite.execute(db,
        """
        CREATE TABLE IF NOT EXISTS benchmark_runs (
            id TEXT PRIMARY KEY,
            code_state_id TEXT NOT NULL,
            environment_id TEXT NOT NULL,
            measured_at TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)),
            FOREIGN KEY (code_state_id) REFERENCES benchmark_code_states(id) ON DELETE RESTRICT,
            FOREIGN KEY (environment_id) REFERENCES benchmark_environments(id) ON DELETE RESTRICT)
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
            FOREIGN KEY (run_id) REFERENCES benchmark_runs(id) ON DELETE CASCADE)
        """)
    create_latest_view_v5!(db)
    create_v5_indexes!(db)
end

function make_metadata!(db, context)
    metadata = merge((schema_version=Benchledger_Schema_Version,),
        Benchledger_Metadata_Defaults,
        (updated_at=context.measured_at,)
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

function read_schema_version(db::SQLite.DB, path::AbstractString)
    metadata_table_found = DBInterface.execute(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'benchledger_metadata' LIMIT 1") do result
        iterate(result) !== nothing
    end
    metadata_table_found || error("Unsupported BenchLedger database in $(path): missing benchledger_metadata.")

    # Avoid collect(...) here: SQLite.jl can materialize this single-column result as missing.
    # Materialize the scalar inside the callback before the statement is closed.
    schema_version = DBInterface.execute(db, "SELECT value FROM benchledger_metadata WHERE key = 'schema_version' LIMIT 1") do result
        row_iter = iterate(result)
        row_iter === nothing ? nothing : String(row_iter[1].value)
    end
    schema_version === nothing && error("Unsupported BenchLedger database in $(path): missing benchledger_metadata.schema_version.")
    schema_version
end

function validate_schema_version!(db::SQLite.DB, path::AbstractString)
    schema_version = read_schema_version(db, path)
    schema_version == Benchledger_Schema_Version || error("Unsupported BenchLedger schema version in $(path): $(schema_version). Expected $(Benchledger_Schema_Version).")

    validate_table_columns(db, path, "benchmark_code_states", ("id", "label", "code_date", "identity", "metadata"))
    validate_table_columns(db, path, "benchmark_environments", ("id", "label", "identity", "metadata"))
    validate_table_columns(db, path, "benchmark_runs", ("id", "code_state_id", "environment_id", "measured_at", "notes", "metadata"))
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

metric_rows(benchmark_path::Vector{String}, value) = error("Unsupported benchmark leaf at $(join(benchmark_path, " / ")): $(typeof(value)). Provide a BenchmarkTools.Trial or normalize custom results into BenchmarkMetricRow rows.")

metric_rows(rows::Vector{BenchmarkMetricRow}) = rows
metric_rows(rows::AbstractVector{<:BenchmarkMetricRow}) = BenchmarkMetricRow[row for row in rows]
metric_rows(rows::AbstractVector{<:NamedTuple}) = [metric_row(row) for row in rows]
metric_rows(results::Tuple{<:AbstractVector{<:NamedTuple},<:BenchmarkGroup}) =
    vcat(metric_rows(results[1]), metric_rows(results[2]))

function metric_rows(results::BenchmarkGroup, prefix::Vector{String}=String[])
    rows = BenchmarkMetricRow[]
    for (name, value) in pairs(results)
        path = [prefix; String(name)]
        append!(rows, value isa BenchmarkGroup ? metric_rows(value, path) : metric_rows(path, value))
    end
    return rows
end

function benchmark_id(path::Vector{String})
    encoded = IOBuffer()
    for segment in path
        write(encoded, string(sizeof(segment), ":"))
        write(encoded, segment)
    end
    return bytes2hex(sha1(take!(encoded)))
end

required_metric_field(row::NamedTuple, field::Symbol) =
    hasproperty(row, field) ? getproperty(row, field) : error("Missing required metric field: $(field).")

function metric_row(row::NamedTuple)
    benchmark_path = if hasproperty(row, :benchmark_path)
        value = getproperty(row, :benchmark_path)
        value isa AbstractVector || error("benchmark_path must be a vector of strings.")
        String[String(segment) for segment in value]
    else
        error("Missing required metric field: benchmark_path.")
    end
    benchmark_id_value = hasproperty(row, :benchmark_id) ? String(getproperty(row, :benchmark_id)) : benchmark_id(benchmark_path)
    benchmark_label_value = hasproperty(row, :benchmark_label) ? String(getproperty(row, :benchmark_label)) : join(benchmark_path, " / ")
    return BenchmarkMetricRow(
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
    return rows
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

function persist_labeled_entity!(db::SQLite.DB, table::AbstractString, id_value::AbstractString, identity::AbstractString, metadata::AbstractString, label::AbstractString; code_date::Union{Nothing,AbstractString}=nothing)
    code_date === nothing ? DBInterface.execute(db, "INSERT INTO $(table) (id, label, identity, metadata) VALUES (?, ?, ?, ?) ON CONFLICT (id) DO NOTHING", (id_value, label, identity, metadata)) :
    DBInterface.execute(db, "INSERT INTO $(table) (id, label, code_date, identity, metadata) VALUES (?, ?, ?, ?, ?) ON CONFLICT (id) DO NOTHING", (id_value, label, code_date, identity, metadata))

    row = DBInterface.execute(db, code_date === nothing ? "SELECT label, identity, metadata FROM $(table) WHERE id = ? LIMIT 1" : "SELECT label, code_date, identity, metadata FROM $(table) WHERE id = ? LIMIT 1", (id_value,)) do result
        row_iter = iterate(result)
        row_iter === nothing && return nothing
        value = row_iter[1]
        code_date === nothing ? (label=String(value.label), identity=String(value.identity), metadata=String(value.metadata)) :
        (label=String(value.label), code_date=String(value.code_date), identity=String(value.identity), metadata=String(value.metadata))
    end
    row === nothing && error("Failed to persist $(table) $(id_value).")
    code_date === nothing || row.code_date == code_date || error("Conflicting code_date for id=$(id_value) in $(table).")
    row.identity == identity || error("Conflicting identity for id=$(id_value) in $(table).")

    # Identity is immutable. Metadata is descriptive/extensible, so merge new values
    # into the stored object instead of making metadata part of entity identity.
    merged_metadata = JSON.parse(row.metadata; dicttype=Dict{String,Any})
    merge_metadata!(merged_metadata, JSON.parse(metadata; dicttype=Dict{String,Any}))
    merged_metadata_json = canonical_json(merged_metadata)
    if row.label != label || row.metadata != merged_metadata_json
        DBInterface.execute(db, "UPDATE $(table) SET label = ?, metadata = ? WHERE id = ?", (label, merged_metadata_json, id_value))
    end
end

function insert_run!(db::SQLite.DB, context)
    DBInterface.execute(db, "INSERT INTO benchmark_runs (id, code_state_id, environment_id, measured_at, notes, metadata) VALUES (?, ?, ?, ?, ?, ?)",
        (context.id, context.code_state_id, context.environment_id, context.measured_at, context.notes, context.metadata,))
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
        INSERT INTO benchmark_results (benchmark_id, run_id, benchmark_path, benchmark_label,
            metric_name, statistic, unit, value, better)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
    SQLite.execute(db, "BEGIN IMMEDIATE TRANSACTION")
    try
        persist_labeled_entity!(db, "benchmark_code_states", code_state.id, code_state.identity, code_state.metadata, code_state.label; code_date=code_state.code_date)
        persist_labeled_entity!(db, "benchmark_environments", environment.id, environment.identity, environment.metadata, environment.label)
        insert_run!(db, context)
        count = insert_metric_rows!(stmt, validate_metric_rows(rows), context.id)
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
source = make_source_context()
code_state = make_code_state(source, measured_at)
environment = make_environment()
context = make_run_context(source, code_state, environment, measured_at)
db = open_database(Results_DB_Path, context)
count = persist_metric_rows!(db, metric_rows(results), code_state, environment, context)
close(db)

println("Wrote $count benchmark rows to $(Results_DB_Path)")
