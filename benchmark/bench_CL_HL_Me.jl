using BenchmarkTools, Logging, Printf

# Null sink (avoid I/O)
struct NullSinkLogger <: AbstractLogger
    minlevel::LogLevel
end
Logging.min_enabled_level(l::NullSinkLogger) = l.minlevel
Logging.shouldlog(::NullSinkLogger, args...) = true
Logging.handle_message(::NullSinkLogger, args...; kwargs...) = nothing
Logging.catch_exceptions(::NullSinkLogger) = false

#──────────────────────────────────────────────────────────────────────────────────────────
import ComponentLogging as CL
const RK = CL.RuleKey
const DEFAULT = (CL.DEFAULT_SYM,)

# Explicitly add rules for: default group, :opti, (:a,:b), and (:a,:b,:c,:d,:e,:f,:g,:h)
const TUP2 = (:a, :b)
const TUP8 = (:a, :b, :c, :d, :e, :f, :g, :h)

function make_logger(minlvl::LogLevel)
    rules = Dict{RK,LogLevel}(
        DEFAULT => minlvl,
        (:opti,) => minlvl,
        TUP2 => minlvl,
        TUP8 => minlvl,
    )
    return CL.ComponentLogger(rules; sink=NullSinkLogger(Debug))
end

const LG_ENABLED  = make_logger(Info)   # Allow Info level
const LG_FILTERED = make_logger(Error)  # Filter out Info level

# Benchmark messages/closures
const MSG_STR = "x"
const MSG_TUP = ("x", 123, :sym)   # Multiple arguments/mixed types
const HEAVY_1 = () -> begin
    s = 0.0
    @inbounds for i = 1:200
        s = muladd(s, 1.0001, i)
    end
    "x $(s)"
end
const HEAVY_1_NOLOG = () -> begin
    s = 0.0
    @inbounds for i = 1:200
        s = muladd(s, 1.0001, i)
    end
    nothing
end

# Lightweight forwarding
@inline _clogf_call(lg, group, lvl, f) = CL.clogf(f, lg, group, lvl)
@inline _clogf_call_default(lg, lvl, f) = CL.clogf(f, lg, DEFAULT, lvl)

const SUITE = BenchmarkGroup()

# ① Filtered path (min=Error, emit Info) — align across packages
SUITE["filtered"] = BenchmarkGroup()
# ComponentLogging
SUITE["filtered"]["cl/default"] = @benchmarkable CL.clog($LG_FILTERED, $DEFAULT, Info, $MSG_STR)
SUITE["filtered"]["cl/opti"]    = @benchmarkable CL.clog($LG_FILTERED, :opti, Info, $MSG_STR)
SUITE["filtered"]["cl/tuple2"]  = @benchmarkable CL.clog($LG_FILTERED, $TUP2, Info, $MSG_STR)
SUITE["filtered"]["cl/tuple8"]  = @benchmarkable CL.clog($LG_FILTERED, $TUP8, Info, $MSG_STR)

# ② Enabled path (min=Info, emit Info) — align across packages
SUITE["enabled"] = BenchmarkGroup()
# ComponentLogging
SUITE["enabled"]["cl/default/str"] = @benchmarkable CL.clog($LG_ENABLED, $DEFAULT, Info, $MSG_STR)
SUITE["enabled"]["cl/opti/str"]    = @benchmarkable CL.clog($LG_ENABLED, :opti, Info, $MSG_STR)
SUITE["enabled"]["cl/tuple2/str"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP2, Info, $MSG_STR)
SUITE["enabled"]["cl/tuple8/str"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP8, Info, $MSG_STR)

# (Note) We intentionally remove ComponentLogging-only features (lazy closures, tuple payloads)
# from the aligned comparison, since Memento/HierarchicalLogging do not offer direct analogues.

#──────────────────────────────────────────────────────────────────────────────────────────
# Memento.jl (optional) — add comparable filtered/enabled microbenches
# NOTE:
# - We keep emissions minimal (use short strings) to reduce I/O bias.
# - If Memento is not available in the env, these tests are skipped.
# - Level mapping helper uses strings expected by Memento ("debug"/"info"/"warn"/"error").
# - For stricter apples-to-apples I/O control you can attach a file/IOBuffer handler
#   to specific child loggers (see Memento docs: push!(getlogger("MyPkg"), DefaultHandler("file.log"))).
#   Ref: https://invenia.github.io/Memento.jl/latest/faq/config-recipes/
using Memento
# Map Base.LogLevel → Memento level strings
memento_level_str(lvl::LogLevel) = lvl <= Debug ? "debug" : lvl <= Info ? "info" : lvl <= Warn ? "warn" : "error"

# Configure root + a few named child loggers to a uniform minimum level
function _memento_config!(lvl::LogLevel)
    # Set levels
    Memento.config!(memento_level_str(lvl))             # root (attaches a default console handler)
    # Replace handlers with NullHandler and stop propagation so nothing reaches console
    local names = ("root", "opti", "a.b", "a.b.c.d.e.f.g.h")
    for name in names
        lg = Memento.getlogger(name)
        Memento.setlevel!(lg, memento_level_str(lvl))
        empty!(Memento.gethandlers(lg))          # 清空现有 handlers（包括 root 的默认 console handler）
        Memento.setpropagating!(lg, false)       # 关闭向上冒泡
    end
    return nothing
end

# filtered path (min=Error, sending Info)
_memento_config!(Error)
SUITE["filtered"]["memento/root"] = @benchmarkable Memento.info(Memento.getlogger("root"), $MSG_STR)
SUITE["filtered"]["memento/opti"] = @benchmarkable Memento.info(Memento.getlogger("opti"), $MSG_STR)
SUITE["filtered"]["memento/a.b"] = @benchmarkable Memento.info(Memento.getlogger("a.b"), $MSG_STR)
SUITE["filtered"]["memento/a.b..8"] = @benchmarkable Memento.info(Memento.getlogger("a.b.c.d.e.f.g.h"), $MSG_STR)

# enabled path (min=Info, sending Info)
_memento_config!(Info)
SUITE["enabled"]["memento/root/str"] = @benchmarkable Memento.info(Memento.getlogger("root"), $MSG_STR)
SUITE["enabled"]["memento/opti/str"] = @benchmarkable Memento.info(Memento.getlogger("opti"), $MSG_STR)
SUITE["enabled"]["memento/a.b/str"] = @benchmarkable Memento.info(Memento.getlogger("a.b"), $MSG_STR)
SUITE["enabled"]["memento/a.b..8/str"] = @benchmarkable Memento.info(Memento.getlogger("a.b.c.d.e.f.g.h"), $MSG_STR)

#──────────────────────────────────────────────────────────────────────────────────────────
# HierarchicalLogging.jl (optional) — stdlib-compatible hierarchical control
# Design:
# - Use a NullSink-like root sink to avoid I/O cost.
# - Route by `_module=...` metadata using artificial nested modules to mimic
#   :opti, tuple2, tuple8 depths.
# Ref: https://github.com/curtd/HierarchicalLogging.jl (README example uses `_module=`)
using HierarchicalLogging

# Define a small module tree to serve as hierarchical keys
module _HLKeys
module default end
module opti end
module a
module b
module c
module d
module e
module f
module g
module h end
end
end
end
end
end
end
end
end # _HLKeys

# Helpers to build loggers with given thresholds for selected nodes
function _hier_make_logger(min_default::LogLevel; nodes::AbstractVector{<:Tuple{Module,LogLevel}}=Tuple{Module,LogLevel}[])
    root = HierarchicalLogging.HierarchicalLogger(NullSinkLogger(Debug))
    # set per-node minimums (recursively for children)
    for (node, lvl) in nodes
        HierarchicalLogging.min_enabled_level!(root, node, lvl)
    end
    # Optionally also set a "default" node’s level to approximate CL default group
    HierarchicalLogging.min_enabled_level!(root, _HLKeys.default, min_default)
    global_logger(root) # it is global_logger, don't modify
    return root
end

# filtered path (default/opti/tuple2/tuple8 all set to Error; we emit Info)
_hier_make_logger(Error; nodes=[
    (_HLKeys.opti, Error),
    (_HLKeys.a.b, Error),
    (_HLKeys.a.b.c.d.e.f.g.h, Error),
])
SUITE["filtered"]["hier/default"] = @benchmarkable @info $MSG_STR _module = _HLKeys.default _file = nothing _line = 1
SUITE["filtered"]["hier/opti"]    = @benchmarkable @info $MSG_STR _module = _HLKeys.opti _file = nothing _line = 1
SUITE["filtered"]["hier/tuple2"]  = @benchmarkable @info $MSG_STR _module = _HLKeys.a.b _file = nothing _line = 1
SUITE["filtered"]["hier/tuple8"]  = @benchmarkable @info $MSG_STR _module = _HLKeys.a.b.c.d.e.f.g.h _file = nothing _line = 1

# enabled path (levels at Info)
_hier_make_logger(Info; nodes=[
    (_HLKeys.opti, Info),
    (_HLKeys.a.b, Info),
    (_HLKeys.a.b.c.d.e.f.g.h, Info),
])
SUITE["enabled"]["hier/default/str"] = @benchmarkable @info $MSG_STR _module = _HLKeys.default _file = nothing _line = 1
SUITE["enabled"]["hier/opti/str"]    = @benchmarkable @info $MSG_STR _module = _HLKeys.opti _file = nothing _line = 1
SUITE["enabled"]["hier/tuple2/str"]  = @benchmarkable @info $MSG_STR _module = _HLKeys.a.b _file = nothing _line = 1
SUITE["enabled"]["hier/tuple8/str"]  = @benchmarkable @info $MSG_STR _module = _HLKeys.a.b.c.d.e.f.g.h _file = nothing _line = 1

#──────────────────────────────────────────────────────────────────────────────────────────
# Run & Display — tune, run, and print a Markdown table comparing all systems

tune!(SUITE; seconds=2.0)
results = run(SUITE; verbose=true)

# Collect rows (system, path, key, time, allocs, memory)
function _collect_rows(results::BenchmarkGroup)
    rows = Vector{NamedTuple}()
    for (path, grp) in results
        @assert grp isa BenchmarkGroup
        for (name, bench) in grp
            if bench isa BenchmarkGroup
                # not expected in this layout
                continue
            end
            # name like "cl/tuple2/str" or "memento/opti"
            parts  = split(String(name), '/')
            system = parts[1]
            key    = join(parts[2:end], '/')
            trial  = minimum(bench)
            push!(rows, (; system, path=String(path), key, time=trial.time, allocs=trial.allocs, memory=trial.memory))
        end
    end
    rows
end

function print_markdown_table(results::BenchmarkGroup)
    rows = _collect_rows(results)
    # sort for stable presentation
    sort!(rows, by=r -> (r.system, r.path, r.key))
    println()
    println("| system | path | key | time (ns) | allocs | memory (B) |")
    println("|:--|:--|:--|--:|--:|--:|")
    for r in rows
        @printf "| %s | %s | %s | %d | %d | %d |
" r.system r.path r.key r.time r.allocs r.memory
    end
end

print_markdown_table(results)
