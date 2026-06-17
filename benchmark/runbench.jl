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

const Benchledger_Schema_Version = "3"

iso_utc_now() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"

struct BenchmarkMetricRow
    run_id::String
    path::Vector{String}
    benchmark_id::String
    benchmark_label::String
    metric_name::String
    statistic::String
    unit::String
    value::Float64
    better::String
end

function detect_branch()
    branch = get(ENV, "BENCH_BRANCH", "")
    !isempty(branch) && return branch

    branch = get(ENV, "GITHUB_REF_TYPE", "") == "branch" ? get(ENV, "GITHUB_REF_NAME", "") : ""
    !isempty(branch) && return branch

    branch = readchomp(`git -C $Target_Package_Path branch --show-current`)
    !isempty(branch) && return branch
    return ""
end

function detect_tag()
    get(ENV, "GITHUB_REF_TYPE", "") == "tag" && return get(ENV, "GITHUB_REF_NAME", "")
    tags = readchomp(`git -C $Target_Package_Path tag --points-at HEAD`)
    return isempty(tags) ? tags : split(tags, '\n'; keepempty=false) |> first
end

function detect_commit()
    commit = get(ENV, "GITHUB_SHA", "")
    isempty(commit) ? readchomp(`git -C $Target_Package_Path rev-parse HEAD`) : commit
end

function detect_code_date()
    code_date = get(ENV, "BENCH_DATE", "")
    isempty(code_date) ? iso_utc_now() : code_date
end

function detect_dirty_state()
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

function detect_machine_id()
    readchomp(`hostname`)
end

function detect_cpu_model()
    buf = IOBuffer()
    Sys.cpu_summary(buf)
    CPU = rstrip(first(split(String(take!(buf)), '\n'; keepempty=false)), [':', ' '])
end

function detect_code_state_id(commit::AbstractString, diff_hash::AbstractString)
    base = isempty(commit) ? "local" : commit
    isempty(diff_hash) ? base : string(base, "+", diff_hash)
end

function make_context()
    branch = detect_branch()
    tag = detect_tag()
    commit = detect_commit()
    code_date = detect_code_date()
    measured_at = iso_utc_now()
    (is_dirty, diff_hash) = detect_dirty_state()
    code_state_id = detect_code_state_id(commit, diff_hash)
    label = first(commit, min(7, ncodeunits(commit)))
    run_id = string(uuid4())

    return (; run_id, branch, tag, code_state_id, label, commit, code_date, measured_at,
        machine_id=detect_machine_id(),
        cpu_model=detect_cpu_model(),
        cpu_threads=Sys.CPU_THREADS,
        arch=string(Sys.ARCH),
        os=lowercase(string(Sys.KERNEL)),
        julia_version=string(VERSION),
        is_dirty,
        notes=get(ENV, "BENCH_NOTES", ""))
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
CREATE TABLE IF NOT EXISTS benchmark_runs (
    run_id TEXT PRIMARY KEY,
    branch TEXT NOT NULL,
    tag TEXT NOT NULL,
    code_state_id TEXT NOT NULL,
    label TEXT NOT NULL,
    "commit" TEXT NOT NULL,
    code_date TEXT NOT NULL,
    measured_at TEXT NOT NULL,
    machine_id TEXT NOT NULL,
    cpu_model TEXT NOT NULL,
    cpu_threads INTEGER NOT NULL,
    arch TEXT NOT NULL,
    os TEXT NOT NULL,
    julia_version TEXT NOT NULL,
    is_dirty INTEGER NOT NULL,
    notes TEXT NOT NULL)
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
    better TEXT NOT NULL,
    PRIMARY KEY (run_id, benchmark_id, metric_name, statistic),
    FOREIGN KEY (run_id) REFERENCES benchmark_runs(run_id) ON DELETE CASCADE)
""")
    SQLite.execute(db,
        """
CREATE VIEW IF NOT EXISTS benchmark_results_latest AS
SELECT
    run_id,
    branch,
    tag,
    code_state_id,
    label,
    "commit",
    code_date,
    measured_at,
    machine_id,
    cpu_model,
    cpu_threads,
    arch,
    os,
    julia_version,
    is_dirty,
    notes,
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
        runs.branch AS branch,
        runs.tag AS tag,
        runs.code_state_id AS code_state_id,
        runs.label AS label,
        runs."commit" AS "commit",
        runs.code_date AS code_date,
        runs.measured_at AS measured_at,
        runs.machine_id AS machine_id,
        runs.cpu_model AS cpu_model,
        runs.cpu_threads AS cpu_threads,
        runs.arch AS arch,
        runs.os AS os,
        runs.julia_version AS julia_version,
        runs.is_dirty AS is_dirty,
        runs.notes AS notes,
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
                runs.machine_id,
                results.benchmark_id,
                results.metric_name,
                results.statistic
            ORDER BY runs.measured_at DESC, results.run_id DESC
        ) AS rn
    FROM benchmark_results AS results
    JOIN benchmark_runs AS runs USING (run_id)
)
WHERE rn = 1
""")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_code_date_index ON benchmark_runs (code_date)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_measured_at_index ON benchmark_runs (measured_at)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_branch_tag_index ON benchmark_runs (branch, tag)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_machine_id_index ON benchmark_runs (machine_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_runs_latest_partition_index ON benchmark_runs (code_state_id, machine_id, measured_at, run_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_benchmark_id_index ON benchmark_results (benchmark_id)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_metric_lookup_index ON benchmark_results (benchmark_id, metric_name, statistic)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_run_id_index ON benchmark_results (run_id)")
end

function make_metadata!(db, context)
    metadata = (
        schema_version=Benchledger_Schema_Version,
        name=Benchledger_Metadata_Defaults.name,
        description=Benchledger_Metadata_Defaults.description,
        project_url=Benchledger_Metadata_Defaults.project_url,
        logo_url=Benchledger_Metadata_Defaults.logo_url,
        created_at=context.measured_at,
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
end

function validate_schema_version!(db::SQLite.DB, path::AbstractString)
    schema_rows = collect(DBInterface.execute(db, "SELECT value FROM benchledger_metadata WHERE key = 'schema_version'"))
    if isempty(schema_rows)
        error("Unsupported BenchLedger database in $(path): missing benchledger_metadata.schema_version.")
    end
    schema_version = String(first(schema_rows).value)
    schema_version == Benchledger_Schema_Version || error("Unsupported BenchLedger schema version in $(path): $(schema_version). Expected $(Benchledger_Schema_Version).")

    result_columns = Set{String}()
    for row in DBInterface.execute(db, "PRAGMA table_info(benchmark_results)")
        push!(result_columns, String(row.name))
    end
    required_columns = (
        "run_id",
        "benchmark_id",
        "benchmark_path",
        "benchmark_label",
        "metric_name",
        "statistic",
        "unit",
        "value",
        "better",
    )
    for column in required_columns
        column in result_columns || error("Unsupported benchmark_results layout in $(path): missing $(column).")
    end
end

function open_database(path::AbstractString, context)
    mkpath(dirname(path))
    is_new_db = !isfile(path)
    db = SQLite.DB(path)
    SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA synchronous=NORMAL")
    init_database!(db)
    if is_new_db
        make_metadata!(db, context)
    else
        validate_schema_version!(db, path)
    end
    db
end

function metric_rows(context, path::Vector{String}, trial::BenchmarkTools.Trial)
    stats = median(trial)
    best = minimum(trial)
    benchmark_id_value = benchmark_id(path)
    benchmark_label_value = join(path, " / ")
    [
        BenchmarkMetricRow(context.run_id, path, benchmark_id_value, benchmark_label_value, "time", "median", "ns", Float64(stats.time), "lower"),
        BenchmarkMetricRow(context.run_id, path, benchmark_id_value, benchmark_label_value, "time", "min", "ns", Float64(best.time), "lower"),
        BenchmarkMetricRow(context.run_id, path, benchmark_id_value, benchmark_label_value, "memory", "min", "bytes", Float64(best.memory), "lower"),
        BenchmarkMetricRow(context.run_id, path, benchmark_id_value, benchmark_label_value, "allocs", "min", "count", Float64(best.allocs), "lower"),
    ]
end

function insert_results!(stmt::SQLite.Stmt, results::BenchmarkGroup, context, prefix::Vector{String})
    count = 0
    for (name, value) in pairs(results)
        path = [prefix; String(name)]
        if value isa BenchmarkGroup
            count += insert_results!(stmt, value, context, path)
        else
            for row in metric_rows(context, path, value)
                SQLite.execute(stmt, benchmark_row(row))
                count += 1
            end
        end
    end
    count
end

function benchmark_id(path::Vector{String})
    encoded = IOBuffer()
    for segment in path
        write(encoded, string(sizeof(segment), ":"))
        write(encoded, segment)
    end
    bytes2hex(sha1(take!(encoded)))
end

function benchmark_row(row::BenchmarkMetricRow)
    (
        row.benchmark_id,
        row.run_id,
        JSON.json(row.path),
        row.benchmark_label,
        row.metric_name,
        row.statistic,
        row.unit,
        row.value,
        row.better,
    )
end

function insert_run!(db::SQLite.DB, context)
    DBInterface.execute(db, """
INSERT INTO benchmark_runs (
    run_id,
    branch,
    tag,
    code_state_id,
    label,
    "commit",
    code_date,
    measured_at,
    machine_id,
    cpu_model,
    cpu_threads,
    arch,
    os,
    julia_version,
    is_dirty,
    notes
)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""", (
    context.run_id,
    context.branch,
    context.tag,
    context.code_state_id,
    context.label,
    context.commit,
    context.code_date,
    context.measured_at,
    context.machine_id,
    context.cpu_model,
    Int(context.cpu_threads),
    context.arch,
    context.os,
    context.julia_version,
    Int(context.is_dirty),
    context.notes,
))
end

function touch_metadata!(db::SQLite.DB, measured_at::AbstractString)
    DBInterface.execute(db, """
INSERT INTO benchledger_metadata (key, value)
VALUES ('updated_at', ?)
ON CONFLICT (key) DO UPDATE SET value = excluded.value
""", (measured_at,))
end

function persist_results!(db::SQLite.DB, results::BenchmarkGroup, context)
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
        insert_run!(db, context)
        count = insert_results!(stmt, results, context, String[])
        touch_metadata!(db, context.measured_at)
        DBInterface.close!(stmt)
        SQLite.execute(db, "COMMIT")
        return count
    catch err
        DBInterface.close!(stmt)
        SQLite.execute(db, "ROLLBACK")
        rethrow(err)
    end
end

context = make_context()
db = open_database(Results_DB_Path, context)
count = persist_results!(db, results, context)
close(db)
publish_pages_db!()

println("Wrote $count benchmark rows to $(Results_DB_Path)")
