import Pkg
Pkg.activate(@__DIR__)
const Target_Package_Path = abspath(get(ENV, "BENCH_TARGET_PATH", joinpath(@__DIR__, "..")))
Pkg.develop(path=Target_Package_Path)
Pkg.instantiate()

using BenchmarkTools, Dates, SHA, JSON, UUIDs, LinearAlgebra
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

const Results_DB_Path = let path=strip(get(ENV, "BENCH_DB_PATH", ""))
    isempty(path) && error("BENCH_DB_PATH must be set to the SQLite database file to update.")
    abspath(path)
end

const Benchledger_Schema_Version = "6"

iso_utc_now() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"

struct BenchmarkMetricRow
    benchmark_key::Vector{String}
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

const Probe_Schema_Version = 2

function format_memory_bytes(bytes::Integer)
    gib = Float64(bytes) / 1024^3
    isinteger(gib) ? string(Int(gib), " GiB") : string(round(gib; digits=1), " GiB")
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

function blas_implementation_name(library::AbstractString)
    name = lowercase(String(library))
    occursin("openblas", name) && return "openblas"
    occursin("mkl", name) && return "mkl"
    (occursin("accelerate", name) || occursin("veclib", name)) && return "accelerate"
    occursin("blis", name) && return "blis"
    occursin("flexiblas", name) && return "flexiblas"
    occursin("atlas", name) && return "atlas"
    "unknown"
end

function detect_blas()
    config_text = try
        sprint(show, MIME"text/plain"(), LinearAlgebra.BLAS.get_config())
    catch
        ""
    end

    libraries = Dict{String,Any}[]
    seen = Set{Tuple{String,String}}()
    for match in eachmatch(r"\[\s*(ILP64|LP64)\s*\]\s+([^\r\n]+)", config_text)
        interface = lowercase(String(match.captures[1]))
        implementation = blas_implementation_name(strip(String(match.captures[2])))
        key = (implementation, interface)
        key in seen && continue
        push!(seen, key)
        push!(libraries, Dict{String,Any}(
            "implementation" => implementation,
            "interface" => interface,
        ))
    end

    if isempty(libraries)
        push!(libraries, Dict{String,Any}(
            "implementation" => blas_implementation_name(config_text),
        ))
    else
        sort!(libraries; by=library -> (
            String(library["implementation"]),
            String(get(library, "interface", "")),
        ))
    end

    blas = Dict{String,Any}("libraries" => libraries)
    threads = try
        LinearAlgebra.BLAS.get_num_threads()
    catch
        nothing
    end
    threads isa Integer && threads > 0 && (blas["threads"] = Int(threads))
    blas
end

function probe_binary_name()
    Sys.iswindows() ? "benchledger-probe.exe" : "benchledger-probe"
end

function resolve_probe_path()
    explicit = strip(get(ENV, "BENCH_PROBE_PATH", ""))
    if !isempty(explicit)
        path = abspath(explicit)
        isfile(path) || error("BENCH_PROBE_PATH does not point to a file: $(path).")
        return path
    end

    adjacent = joinpath(@__DIR__, probe_binary_name())
    isfile(adjacent) && return adjacent

    path_entry = Sys.which("benchledger-probe")
    path_entry === nothing || return String(path_entry)
    error("benchledger-probe was not found. Set BENCH_PROBE_PATH, place $(probe_binary_name()) beside runbench.jl, or add it to PATH.")
end

function require_probe_object(value, field::AbstractString)
    value isa AbstractDict || error("Invalid benchledger-probe output: $(field) must be a JSON object.")
    Dict{String,Any}(String(key) => item for (key, item) in pairs(value))
end

function require_probe_string(value, field::AbstractString)
    value isa AbstractString && !isempty(value) || error("Invalid benchledger-probe output: $(field) must be a nonempty string.")
    String(value)
end

function collect_probe()
    path = resolve_probe_path()
    stdout_buffer = IOBuffer()
    stderr_buffer = IOBuffer()
    process = try
        run(pipeline(ignorestatus(Cmd([path])), stdout=stdout_buffer, stderr=stderr_buffer))
    catch err
        error("Failed to start benchledger-probe at $(path): $(sprint(showerror, err)).")
    end

    stdout_text = String(take!(stdout_buffer))
    stderr_text = strip(String(take!(stderr_buffer)))
    if !success(process)
        detail = isempty(stderr_text) ? "no diagnostic output" : stderr_text
        error("benchledger-probe failed with exit code $(process.exitcode): $(detail).")
    end
    isempty(strip(stdout_text)) && error("benchledger-probe returned empty output.")

    document = try
        JSON.parse(stdout_text; dicttype=Dict{String,Any})
    catch err
        error("benchledger-probe returned invalid JSON: $(sprint(showerror, err)).")
    end
    document = require_probe_object(document, "root")
    schema_version = get(document, "schema_version", nothing)
    schema_version == Probe_Schema_Version ||
        error(string("Unsupported benchledger-probe schema version: ",
        repr(schema_version), ". Expected ", Probe_Schema_Version, "."))

    hardware = require_probe_object(get(document, "hardware", nothing), "hardware")
    require_probe_string(get(hardware, "architecture", nothing), "hardware.architecture")
    cpu = require_probe_object(get(hardware, "cpu", nothing), "hardware.cpu")
    require_probe_string(get(cpu, "model", nothing), "hardware.cpu.model")

    software = require_probe_object(get(document, "software", nothing), "software")
    platform = require_probe_object(get(software, "platform", nothing), "software.platform")
    kernel = require_probe_object(get(platform, "kernel", nothing), "software.platform.kernel")
    isempty(kernel) && error("Invalid benchledger-probe output: software.platform.kernel must not be empty.")

    diagnostics = require_probe_object(get(document, "diagnostics", nothing), "diagnostics")
    collector = require_probe_object(get(document, "collector", nothing), "collector")
    require_probe_string(get(collector, "name", nothing), "collector.name") == "fastfetch" ||
        error("Invalid benchledger-probe output: collector.name must be fastfetch.")

    Dict{String,Any}(
        "hardware" => hardware,
        "software" => software,
        "diagnostics" => diagnostics,
        "collector" => collector,
    )
end

function detect_gpu_interface()
    interfaces = (
        (:CUDA, "CUDA.jl", "CUDA"),
        (:AMDGPU, "AMDGPU.jl", "ROCm"),
        (:Metal, "Metal.jl", "Metal"),
        (:oneAPI, "oneAPI.jl", "oneAPI"),
    )
    for (module_name, display_name, backend) in interfaces
        _module = loaded_module_by_name(module_name)
        _module === nothing && continue
        identity = Dict{String,Any}("name" => display_name)
        version = module_version_string(_module)
        !isempty(version) && (identity["version"] = version)
        return (; module_name, _module, identity, backend)
    end
    nothing
end

function detect_gpu_runtime(interface)
    interface === nothing && return Dict{String,Any}()
    runtime = Dict{String,Any}("backend" => interface.backend)
    if interface.module_name == :CUDA
        runtime_version = module_call_version(interface._module, :runtime_version)
        runtime_info = Dict{String,Any}("name" => "CUDA")
        !isempty(runtime_version) && (runtime_info["version"] = runtime_version)
        runtime["runtime"] = runtime_info
    elseif interface.module_name == :AMDGPU
        runtime_version = module_call_version(interface._module, :runtime_version)
        runtime_info = Dict{String,Any}("name" => "ROCm")
        !isempty(runtime_version) && (runtime_info["version"] = runtime_version)
        runtime["runtime"] = runtime_info
    end
    runtime
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

function hardware_environment_label(identity::AbstractDict)
    cpu = get(identity, "cpu", Dict{String,Any}())
    cpu_model = cpu isa AbstractDict ? String(get(cpu, "model", "hardware")) : "hardware"
    parts = String[cpu_model]

    memory = get(identity, "memory", nothing)
    if memory isa AbstractDict
        bytes = get(memory, "total_bytes", nothing)
        bytes isa Integer && bytes > 0 && push!(parts, format_memory_bytes(bytes))
    end

    gpus = get(identity, "gpu", Any[])
    if gpus isa AbstractVector
        for gpu in gpus
            gpu isa AbstractDict || continue
            count = get(gpu, "count", 1)
            model = String(get(gpu, "model", "GPU"))
            count_value = count isa Integer && count > 0 ? Int(count) : 1
            push!(parts, count_value == 1 ? model : string(count_value, "× ", model))
        end
    end
    join(parts, " / ")
end

function software_environment_label(identity::AbstractDict)
    runtime = get(identity, "runtime", Dict{String,Any}())
    runtime_name = runtime isa AbstractDict ? String(get(runtime, "name", "runtime")) : "runtime"
    runtime_version = runtime isa AbstractDict ? String(get(runtime, "version", "")) : ""
    runtime_label = isempty(runtime_version) ? runtime_name : string(runtime_name, " ", runtime_version)

    platform = get(identity, "platform", Dict{String,Any}())
    os = platform isa AbstractDict ? get(platform, "os", Dict{String,Any}()) : Dict{String,Any}()
    os_name = os isa AbstractDict ? String(get(os, "name", "platform")) : "platform"
    os_version = os isa AbstractDict ? String(get(os, "version", "")) : ""
    os_label = isempty(os_version) ? os_name : string(os_name, " ", os_version)

    execution = get(identity, "execution", Dict{String,Any}())
    threads = execution isa AbstractDict ? get(execution, "threads", nothing) : nothing
    thread_label = threads isa Integer ? string(Int(threads), " threads") : ""
    join(filter(!isempty, (runtime_label, os_label, thread_label)), " / ")
end

function make_hardware_environment(probe::AbstractDict)
    override = validate_object_keys(parse_object_env("BENCH_HARDWARE_ENVIRONMENT"), "BENCH_HARDWARE_ENVIRONMENT", ("label", "identity", "metadata"))
    identity = deepcopy(require_probe_object(get(probe, "hardware", nothing), "hardware"))
    merge_metadata!(identity, object_field(override, "identity", "BENCH_HARDWARE_ENVIRONMENT"))
    metadata = object_field(override, "metadata", "BENCH_HARDWARE_ENVIRONMENT")

    identity_json = canonical_json(identity)
    id = string("hardware-", bytes2hex(sha256(codeunits(identity_json))))
    label = haskey(override, "label") ? String(override["label"]) : hardware_environment_label(identity)
    (; id, label, identity=identity_json, metadata=canonical_json(metadata))
end

function make_software_environment(probe::AbstractDict)
    override = validate_object_keys(parse_object_env("BENCH_SOFTWARE_ENVIRONMENT"), "BENCH_SOFTWARE_ENVIRONMENT", ("label", "identity", "metadata"))
    identity = deepcopy(require_probe_object(get(probe, "software", nothing), "software"))
    identity["runtime"] = Dict{String,Any}("name" => "Julia", "version" => string(VERSION))

    execution = Dict{String,Any}("processes" => 1, "threads" => Threads.nthreads())
    interface = detect_gpu_interface()
    if interface !== nothing
        identity["gpu"] = Dict{String,Any}("interface" => interface.identity)
        gpu_runtime = detect_gpu_runtime(interface)
        !isempty(gpu_runtime) && (identity["gpu_runtime"] = gpu_runtime)
    end
    identity["execution"] = execution
    identity["math_libraries"] = Dict{String,Any}("blas" => detect_blas())

    framework = Dict{String,Any}("name" => "BenchmarkTools.jl")
    framework_version = module_version_string(BenchmarkTools)
    !isempty(framework_version) && (framework["version"] = framework_version)
    identity["benchmark"] = Dict{String,Any}("framework" => framework)

    # A language-specific writer may provide a language-neutral dependency snapshot,
    # for example identity.dependencies = {kind, format, digest}.
    merge_metadata!(identity, object_field(override, "identity", "BENCH_SOFTWARE_ENVIRONMENT"))
    metadata = object_field(override, "metadata", "BENCH_SOFTWARE_ENVIRONMENT")

    identity_json = canonical_json(identity)
    id = string("software-", bytes2hex(sha256(codeunits(identity_json))))
    label = haskey(override, "label") ? String(override["label"]) : software_environment_label(identity)
    (; id, label, identity=identity_json, metadata=canonical_json(metadata))
end

function make_run_context(source, code_state, hardware_environment, software_environment, measured_at::AbstractString, probe::AbstractDict)
    override = validate_object_keys(parse_object_env("BENCH_RUN"), "BENCH_RUN", ("notes", "metadata"))
    source_metadata = Dict{String,Any}()
    !isempty(source.branch) && (source_metadata["branch"] = source.branch)
    !isempty(source.tags) && (source_metadata["tags"] = source.tags)

    metadata = Dict{String,Any}(
        "host" => Dict{String,Any}("hostname" => gethostname()),
        "probe" => Dict{String,Any}(
            "collector" => deepcopy(require_probe_object(get(probe, "collector", nothing), "collector")),
            "diagnostics" => deepcopy(require_probe_object(get(probe, "diagnostics", nothing), "diagnostics")),
        ),
        "writer" => Dict{String,Any}(
            "name" => "BenchLedger Julia template",
            "schema_version" => parse(Int, Benchledger_Schema_Version),
        ),
    )
    !isempty(source_metadata) && (metadata["source"] = source_metadata)
    merge_metadata!(metadata, object_field(override, "metadata", "BENCH_RUN"))

    if haskey(override, "notes")
        notes = String(override["notes"])
        !isempty(notes) && merge_metadata!(metadata, Dict{String,Any}("notes" => notes))
    end

    (
        id=string(uuid4()),
        code_state_id=code_state.id,
        hardware_environment_id=hardware_environment.id,
        software_environment_id=software_environment.id,
        measured_at,
        metadata=canonical_json(metadata),
    )
end

function create_v6_indexes!(db)
    # The browser reads a complete snapshot; these indexes are retained for direct SQLite consumers.
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS code_states_code_date_index ON code_states (code_date)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS runs_measured_at_index ON runs (measured_at)")
    # runs_configuration_index already covers code_state_id as its leftmost prefix.
    SQLite.execute(db, "DROP INDEX IF EXISTS runs_code_state_id_index")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS runs_hardware_environment_id_index ON runs (hardware_environment_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS runs_software_environment_id_index ON runs (software_environment_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS runs_configuration_index ON runs (code_state_id, hardware_environment_id, software_environment_id, measured_at, id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_metric_lookup_index ON benchmark_results (benchmark_key, metric_name, statistic)")
end

function create_v6_tables!(db)
    SQLite.execute(db,
        """
        CREATE TABLE IF NOT EXISTS benchledger_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL)
        """)
    SQLite.execute(db,
        """
        CREATE TABLE IF NOT EXISTS code_states (
            id TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            code_date TEXT NOT NULL,
            identity TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(identity)),
            metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)))
        """)
    SQLite.execute(db,
        """
        CREATE TABLE IF NOT EXISTS hardware_environments (
            id TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            identity TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(identity)),
            metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)))
        """)
    SQLite.execute(db,
        """
        CREATE TABLE IF NOT EXISTS software_environments (
            id TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            identity TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(identity)),
            metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)))
        """)
    SQLite.execute(db,
        """
        CREATE TABLE IF NOT EXISTS runs (
            id TEXT PRIMARY KEY,
            code_state_id TEXT NOT NULL,
            hardware_environment_id TEXT NOT NULL,
            software_environment_id TEXT NOT NULL,
            measured_at TEXT NOT NULL,
            metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata)),
            FOREIGN KEY (code_state_id) REFERENCES code_states(id) ON DELETE RESTRICT,
            FOREIGN KEY (hardware_environment_id) REFERENCES hardware_environments(id) ON DELETE RESTRICT,
            FOREIGN KEY (software_environment_id) REFERENCES software_environments(id) ON DELETE RESTRICT)
        """)
    SQLite.execute(db,
        """
        CREATE TABLE IF NOT EXISTS benchmark_results (
            run_id TEXT NOT NULL,
            benchmark_key TEXT NOT NULL CHECK (
                CASE WHEN json_valid(benchmark_key)
                    THEN json_type(benchmark_key) = 'array' AND json_array_length(benchmark_key) > 0
                    ELSE 0
                END),
            metric_name TEXT NOT NULL,
            statistic TEXT NOT NULL,
            unit TEXT NOT NULL,
            value REAL NOT NULL,
            better TEXT NOT NULL CHECK (better IN ('lower', 'higher', 'neutral')),
            PRIMARY KEY (run_id, benchmark_key, metric_name, statistic),
            FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE)
        """)
end

function init_database!(db)
    create_v6_tables!(db)
    create_v6_indexes!(db)
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

    validate_table_columns(db, path, "code_states", ("id", "label", "code_date", "identity", "metadata"))
    validate_table_columns(db, path, "hardware_environments", ("id", "label", "identity", "metadata"))
    validate_table_columns(db, path, "software_environments", ("id", "label", "identity", "metadata"))
    validate_table_columns(db, path, "runs", ("id", "code_state_id", "hardware_environment_id", "software_environment_id", "measured_at", "metadata"))
    validate_table_columns(db, path, "benchmark_results", ("run_id", "benchmark_key", "metric_name", "statistic", "unit", "value", "better"))
end

function database_has_user_tables(db::SQLite.DB)
    DBInterface.execute(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' LIMIT 1") do result
        iterate(result) !== nothing
    end
end

function open_database(path::AbstractString)
    mkpath(dirname(path))
    db = SQLite.DB(path)
    try
        SQLite.execute(db, "PRAGMA foreign_keys=ON")
        SQLite.execute(db, "PRAGMA journal_mode=WAL")
        SQLite.execute(db, "PRAGMA synchronous=NORMAL")
        database_has_user_tables(db) && validate_schema_version!(db, path)
        return db
    catch
        close(db)
        rethrow()
    end
end

function metric_rows(benchmark_key::Vector{String}, trial::BenchmarkTools.Trial)
    stats = median(trial)
    best = minimum(trial)
    [
        BenchmarkMetricRow(benchmark_key, "time", "median", "ns", Float64(stats.time), "lower"),
        BenchmarkMetricRow(benchmark_key, "time", "min", "ns", Float64(best.time), "lower"),
        BenchmarkMetricRow(benchmark_key, "memory", "min", "bytes", Float64(best.memory), "lower"),
        BenchmarkMetricRow(benchmark_key, "allocs", "min", "count", Float64(best.allocs), "lower"),
    ]
end

metric_rows(benchmark_key::Vector{String}, value) = error("Unsupported benchmark leaf at $(join(benchmark_key, " / ")): $(typeof(value)). Provide a BenchmarkTools.Trial or normalize custom results into BenchmarkMetricRow rows.")

metric_rows(rows::Vector{BenchmarkMetricRow}) = rows
metric_rows(rows::AbstractVector{<:BenchmarkMetricRow}) = BenchmarkMetricRow[row for row in rows]
metric_rows(rows::AbstractVector{<:NamedTuple}) = [metric_row(row) for row in rows]
metric_rows(results::Tuple{<:AbstractVector{<:NamedTuple},<:BenchmarkGroup}) =
    vcat(metric_rows(results[1]), metric_rows(results[2]))

function metric_rows(results::BenchmarkGroup, prefix::Vector{String}=String[])
    rows = BenchmarkMetricRow[]
    for (name, value) in pairs(results)
        benchmark_key = [prefix; String(name)]
        append!(rows, value isa BenchmarkGroup ? metric_rows(value, benchmark_key) : metric_rows(benchmark_key, value))
    end
    rows
end

required_metric_field(row::NamedTuple, field::Symbol) =
    hasproperty(row, field) ? getproperty(row, field) : error("Missing required metric field: $(field).")

function metric_row(row::NamedTuple)
    value = required_metric_field(row, :benchmark_key)
    value isa AbstractVector || error("benchmark_key must be a vector of strings.")
    benchmark_key = String[String(segment) for segment in value]
    BenchmarkMetricRow(
        benchmark_key,
        String(required_metric_field(row, :metric_name)),
        String(required_metric_field(row, :statistic)),
        String(required_metric_field(row, :unit)),
        Float64(required_metric_field(row, :value)),
        String(required_metric_field(row, :better)),
    )
end

function validate_benchmark_key(benchmark_key::AbstractVector{<:AbstractString})
    isempty(benchmark_key) && error("benchmark_key must contain at least one string segment.")
    for (index, segment) in pairs(benchmark_key)
        isempty(segment) && error("benchmark_key segment $(index) must not be empty.")
    end
    benchmark_key
end

function validate_metric_rows(rows::AbstractVector{<:BenchmarkMetricRow})
    seen = Set{Tuple{String,String,String}}()
    for row in rows
        validate_benchmark_key(row.benchmark_key)
        isempty(row.metric_name) && error("metric_name must not be empty.")
        isempty(row.statistic) && error("statistic must not be empty.")
        isempty(row.unit) && error("unit must not be empty.")
        benchmark_name = join(row.benchmark_key, " / ")
        isfinite(row.value) || error("Metric value must be finite for $(benchmark_name) / $(row.metric_name) / $(row.statistic).")
        row.better in ("lower", "higher", "neutral") || error("Unsupported better value for $(benchmark_name): $(row.better). Expected lower, higher, or neutral.")
        key = (canonical_json(row.benchmark_key), row.metric_name, row.statistic)
        key in seen && error("Duplicate metric row in the same run for benchmark_key=$(key[1]), metric_name=$(row.metric_name), statistic=$(row.statistic).")
        push!(seen, key)
    end
    rows
end

benchmark_result_row(run_id::AbstractString, row::BenchmarkMetricRow) =
    (run_id, canonical_json(row.benchmark_key), row.metric_name, row.statistic, row.unit, row.value, row.better)

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
    DBInterface.execute(db, "INSERT INTO runs (id, code_state_id, hardware_environment_id, software_environment_id, measured_at, metadata) VALUES (?, ?, ?, ?, ?, ?)",
        (context.id, context.code_state_id, context.hardware_environment_id, context.software_environment_id, context.measured_at, context.metadata))
end

function insert_metric_rows!(stmt::SQLite.Stmt, rows::AbstractVector{<:BenchmarkMetricRow}, run_id::AbstractString)
    for row in rows
        SQLite.execute(stmt, benchmark_result_row(run_id, row))
    end
    length(rows)
end

function persist_metric_rows!(db::SQLite.DB, rows::AbstractVector{<:BenchmarkMetricRow}, code_state, hardware_environment, software_environment, context)
    validated_rows = validate_metric_rows(rows)
    SQLite.execute(db, "BEGIN IMMEDIATE TRANSACTION")
    try
        init_database!(db)
        make_metadata!(db, context)
        persist_labeled_entity!(db, "code_states", code_state.id, code_state.identity, code_state.metadata, code_state.label; code_date=code_state.code_date)
        persist_labeled_entity!(db, "hardware_environments", hardware_environment.id, hardware_environment.identity, hardware_environment.metadata, hardware_environment.label)
        persist_labeled_entity!(db, "software_environments", software_environment.id, software_environment.identity, software_environment.metadata, software_environment.label)
        insert_run!(db, context)
        stmt = SQLite.Stmt(db, "INSERT INTO benchmark_results (run_id, benchmark_key, metric_name, statistic, unit, value, better) VALUES (?, ?, ?, ?, ?, ?, ?)")
        count = try
            insert_metric_rows!(stmt, validated_rows, context.id)
        finally
            DBInterface.close!(stmt)
        end
        SQLite.execute(db, "COMMIT")
        return count
    catch err
        try
            SQLite.execute(db, "ROLLBACK")
        catch
        end
        rethrow(err)
    end
end

measured_at = iso_utc_now()
source = make_source_context()
code_state = make_code_state(source, measured_at)
probe = collect_probe()
hardware_environment = make_hardware_environment(probe)
software_environment = make_software_environment(probe)
context = make_run_context(source, code_state, hardware_environment, software_environment, measured_at, probe)
db = open_database(Results_DB_Path)
count = persist_metric_rows!(db, metric_rows(results), code_state, hardware_environment, software_environment, context)
SQLite.execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")
SQLite.execute(db, "PRAGMA journal_mode=DELETE")
close(db)

println("Wrote $count benchmark rows to $(Results_DB_Path)")
