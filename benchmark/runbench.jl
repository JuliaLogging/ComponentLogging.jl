import Pkg
Pkg.activate(@__DIR__)
const Target_Package_Path = abspath(get(ENV, "BENCH_TARGET_PATH", joinpath(@__DIR__, "..")))
if haskey(ENV, "BENCH_TARGET_PATH")
    Pkg.develop(path=Target_Package_Path)
    Pkg.instantiate()
end

using BenchmarkTools, Dates, SHA
using DBInterface, SQLite

include(joinpath(@__DIR__, "benchmarks.jl"))

const Bench_DB_In_Current_Branch = lowercase(get(ENV, "BENCH_DB_IN_CURRENT_BRANCH", "false")) in ("true", "1", "yes")
const Pages_Branch = "gh-pages"
const Pages_Worktree = abspath(joinpath(tempdir(), "benchledger-pages"))
const Pages_DB_Path = joinpath(Pages_Worktree, "benchledger", "data", "benchledger.sqlite")

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
        run(`git -C $Pages_Worktree add benchledger/data/benchledger.sqlite`)
        if success(`git -C $Pages_Worktree diff --cached --quiet`)
            println("No benchmark database changes.")
        else
            run(`git -C $Pages_Worktree commit -m "Update benchmark database"`)
            run(`git -C $Pages_Worktree push origin HEAD:$Pages_Branch`)
        end
    end
end

const Benchledger_Schema_Version = "1"
const Benchledger_Metadata_Defaults = (
    name="ComponentLogging.jl",
    description="Benchmark history for ComponentLogging.jl",
    project_url="https://github.com/JuliaLogging/ComponentLogging.jl",
    logo_url="",
    notes="",
)

iso_utc_now() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"

function detect_branch()
    get(ENV, "GITHUB_REF_TYPE", "") == "branch" && return get(ENV, "GITHUB_REF_NAME", "")
    branch = readchomp(`git -C $Target_Package_Path branch --show-current`)
    return isempty(branch) ? "master" : branch
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

function detect_date()
    date = get(ENV, "BENCH_DATE", "")
    isempty(date) ? iso_utc_now() : date
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
    date = detect_date()
    (is_dirty, diff_hash) = detect_dirty_state()
    code_state_id = detect_code_state_id(commit, diff_hash)
    label = first(commit, min(7, ncodeunits(commit)))

    return (; branch, tag, code_state_id, label, commit, date,
        metric_kind="runtime",
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
CREATE TABLE IF NOT EXISTS benchmark_results (
    branch TEXT NOT NULL,
    tag TEXT NOT NULL,
    code_state_id TEXT NOT NULL,
    label TEXT NOT NULL,
    "commit" TEXT NOT NULL,
    date TEXT NOT NULL,
    benchmark_key TEXT NOT NULL,
    metric_kind TEXT NOT NULL,
    time_ns_median REAL NOT NULL,
    time_ns_min REAL NOT NULL,
    memory_bytes_min INTEGER NOT NULL,
    allocs_min INTEGER NOT NULL,
    machine_id TEXT NOT NULL,
    cpu_model TEXT NOT NULL,
    cpu_threads INTEGER NOT NULL,
    arch TEXT NOT NULL,
    os TEXT NOT NULL,
    julia_version TEXT NOT NULL,
    is_dirty INTEGER NOT NULL,
    notes TEXT NOT NULL,
    PRIMARY KEY (code_state_id, machine_id, benchmark_key, metric_kind))
""")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_date_index ON benchmark_results (date)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_branch_tag_index ON benchmark_results (branch, tag)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_benchmark_key_index ON benchmark_results (benchmark_key)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS benchmark_results_machine_id_index ON benchmark_results (machine_id)")
end

function make_metadata!(db, context)
    metadata = (
        schema_version=Benchledger_Schema_Version,
        name=Benchledger_Metadata_Defaults.name,
        description=Benchledger_Metadata_Defaults.description,
        project_url=Benchledger_Metadata_Defaults.project_url,
        logo_url=Benchledger_Metadata_Defaults.logo_url,
        created_at=context.date,
        updated_at=context.date,
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

function open_database(path::AbstractString, context)
    mkpath(dirname(path))
    is_new_db = !isfile(path)
    db = SQLite.DB(path)
    SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA synchronous=NORMAL")
    init_database!(db)
    is_new_db && make_metadata!(db, context)
    db
end

function insert_results!(stmt::SQLite.Stmt, results::BenchmarkGroup, context, prefix::Vector{String})
    count = 0
    for (name, value) in pairs(results)
        path = [prefix; String(name)]
        if value isa BenchmarkGroup
            count += insert_results!(stmt, value, context, path)
        else
            SQLite.execute(stmt, benchmark_row(context, join(path, "/"), value))
            count += 1
        end
    end
    count
end

function benchmark_row(context, benchmark_key::AbstractString, trial::BenchmarkTools.Trial)
    stats = median(trial)
    best = minimum(trial)
    (
        context.branch,
        context.tag,
        context.code_state_id,
        context.label,
        context.commit,
        context.date,
        benchmark_key,
        context.metric_kind,
        Float64(stats.time),
        Float64(best.time),
        Int(best.memory),
        Int(best.allocs),
        context.machine_id,
        context.cpu_model,
        Int(context.cpu_threads),
        context.arch,
        context.os,
        context.julia_version,
        Int(context.is_dirty),
        context.notes,
    )
end

function insert_results!(db::SQLite.DB, results::BenchmarkGroup, context)
    stmt = SQLite.Stmt(db,
        """
INSERT INTO benchmark_results (
    branch,
    tag,
    code_state_id,
    label,
    "commit",
    date,
    benchmark_key,
    metric_kind,
    time_ns_median,
    time_ns_min,
    memory_bytes_min,
    allocs_min,
    machine_id,
    cpu_model,
    cpu_threads,
    arch,
    os,
    julia_version,
    is_dirty,
    notes
)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (code_state_id, machine_id, benchmark_key, metric_kind) DO UPDATE SET
    branch = excluded.branch,
    tag = excluded.tag,
    label = excluded.label,
    "commit" = excluded."commit",
    date = excluded.date,
    time_ns_median = excluded.time_ns_median,
    time_ns_min = excluded.time_ns_min,
    memory_bytes_min = excluded.memory_bytes_min,
    allocs_min = excluded.allocs_min,
    cpu_model = excluded.cpu_model,
    cpu_threads = excluded.cpu_threads,
    arch = excluded.arch,
    os = excluded.os,
    julia_version = excluded.julia_version,
    is_dirty = excluded.is_dirty,
    notes = excluded.notes
""")
    SQLite.execute(db, "BEGIN IMMEDIATE TRANSACTION")
    count = insert_results!(stmt, results, context, String[])
    DBInterface.close!(stmt)
    SQLite.execute(db, "COMMIT")
    count
end

context = make_context()
db = open_database(Results_DB_Path, context)
count = insert_results!(db, results, context)
close(db)
publish_pages_db!()

println("Wrote $count benchmark rows to $(Results_DB_Path)")
