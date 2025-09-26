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

#──────────────────────────────────────────────────────────────────────────────────────────
# Create logger
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

#──────────────────────────────────────────────────────────────────────────────────────────
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

#──────────────────────────────────────────────────────────────────────────────────────────
# Lightweight forwarding
@inline _clogf_call(lg, group, lvl, f) = CL.clogf(f, lg, group, lvl)
@inline _clogf_call_default(lg, lvl, f) = CL.clogf(f, lg, DEFAULT, lvl)

#──────────────────────────────────────────────────────────────────────────────────────────
const SUITE = BenchmarkGroup()

# 1) Filtered path (min=Error, sending Info) - Decision and routing cost
SUITE["filtered"]                  = BenchmarkGroup()
SUITE["filtered"]["clog/default"]  = @benchmarkable CL.clog($LG_FILTERED, $DEFAULT, Info, $MSG_STR)
SUITE["filtered"]["clog/symbol"]   = @benchmarkable CL.clog($LG_FILTERED, :opti, Info, $MSG_STR)
SUITE["filtered"]["clog/tuple2"]   = @benchmarkable CL.clog($LG_FILTERED, $TUP2, Info, $MSG_STR)
SUITE["filtered"]["clog/tuple8"]   = @benchmarkable CL.clog($LG_FILTERED, $TUP8, Info, $MSG_STR)
SUITE["filtered"]["clogf/default"] = @benchmarkable _clogf_call_default($LG_FILTERED, Info, $HEAVY_1)     # HEAVY_1 should not execute
SUITE["filtered"]["clogf/symbol"]  = @benchmarkable _clogf_call($LG_FILTERED, :opti, Info, $HEAVY_1)
SUITE["filtered"]["clogf/tuple2"]  = @benchmarkable _clogf_call($LG_FILTERED, $TUP2, Info, $HEAVY_1)
SUITE["filtered"]["clogf/tuple8"]  = @benchmarkable _clogf_call($LG_FILTERED, $TUP8, Info, $HEAVY_1)

# 2) Allowed path (min=Info, sending Info) - Decision + assembly + call
SUITE["enabled"] = BenchmarkGroup()
# 2.1 Single string
SUITE["enabled"]["clog/default/str"] = @benchmarkable CL.clog($LG_ENABLED, $DEFAULT, Info, $MSG_STR)
SUITE["enabled"]["clog/symbol/str"]  = @benchmarkable CL.clog($LG_ENABLED, :opti, Info, $MSG_STR)
SUITE["enabled"]["clog/tuple2/str"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP2, Info, $MSG_STR)
SUITE["enabled"]["clog/tuple8/str"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP8, Info, $MSG_STR)
# 2.2 Multiple arguments/mixed types
SUITE["enabled"]["clog/default/tuple"] = @benchmarkable CL.clog($LG_ENABLED, $DEFAULT, Info, $MSG_TUP...)
SUITE["enabled"]["clog/tuple2/tuple"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP2, Info, $MSG_TUP...)
SUITE["enabled"]["clog/tuple8/tuple"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP8, Info, $MSG_TUP...)
# 2.3 clogf: Only execute heavy work when allowed
SUITE["enabled"]["clogf/default/heavy"] = @benchmarkable _clogf_call_default($LG_ENABLED, Info, $HEAVY_1)
SUITE["enabled"]["clogf/tuple2/heavy"]  = @benchmarkable _clogf_call($LG_ENABLED, $TUP2, Info, $HEAVY_1)
SUITE["enabled"]["clogf/tuple8/heavy"]  = @benchmarkable _clogf_call($LG_ENABLED, $TUP8, Info, $HEAVY_1)
# 2.4 clogf: Allowed but chose not to output (returns nothing)
SUITE["enabled"]["clogf/default/nolog"] = @benchmarkable _clogf_call_default($LG_ENABLED, Info, $HEAVY_1_NOLOG)

# 3) Micro comparison: Explicit logger vs implicit
# SUITE["enabled"]["clog/implicit"] = @benchmarkable CL.clog(:opti, Info, $MSG_STR)

#──────────────────────────────────────────────────────────────────────────────────────────
# Run & Display
tune!(SUITE; seconds=2.0)
results = run(SUITE; verbose=true)

println("\n" * "─"^24 * " SUMMARY (ns/op，allocs) " * "─"^25)
function _summarize!(grp, prefix="")
    for (k, v) in grp
        if v isa BenchmarkGroup
            _summarize!(v, isempty(prefix) ? string(k) : string(prefix, "/", k))
        else
            t = minimum(v).time
            a = minimum(v).allocs
            b = minimum(v).memory
            println(rpad(prefix == "" ? string(k) : string(prefix, "/", k), 30),
                lpad(@sprintf("%8.2f", t / 1.0), 12), " ns   ",
                lpad(a, 6), " allocs   ",
                lpad(@sprintf("%.2f KiB", b / 1024), 10))
        end
    end
end
_summarize!(results)
println("─"^74)

#=
===== SUMMARY (ns/op，allocs) =====
filtered/clog/tuple2                  3.50 ns        0 allocs     0.00 KiB    
filtered/clogf/symbol                 2.80 ns        0 allocs     0.00 KiB    
filtered/clogf/tuple8                 2.60 ns        0 allocs     0.00 KiB    
filtered/clog/default                 2.80 ns        0 allocs     0.00 KiB    
filtered/clogf/default                2.80 ns        0 allocs     0.00 KiB    
filtered/clogf/tuple2                 3.70 ns        0 allocs     0.00 KiB    
filtered/clog/symbol                  2.40 ns        0 allocs     0.00 KiB    
filtered/clog/tuple8                  2.40 ns        0 allocs     0.00 KiB    
enabled/clogf/default/nolog          14.03 ns        0 allocs     0.00 KiB    
enabled/clog/default/str             15.53 ns        0 allocs     0.00 KiB    
enabled/clogf/tuple2/heavy          419.10 ns        6 allocs     0.60 KiB    
enabled/clog/tuple2/str              24.80 ns        0 allocs     0.00 KiB    
enabled/clog/tuple8/tuple           188.63 ns        0 allocs     0.00 KiB    
enabled/clogf/tuple8/heavy          591.57 ns        6 allocs     0.60 KiB    
enabled/clog/symbol/str              13.73 ns        0 allocs     0.00 KiB    
enabled/clog/default/tuple           15.53 ns        0 allocs     0.00 KiB    
enabled/clog/tuple2/tuple            24.80 ns        0 allocs     0.00 KiB    
enabled/clogf/default/heavy         403.02 ns        6 allocs     0.60 KiB    
enabled/clog/tuple8/str             191.80 ns        0 allocs     0.00 KiB    
====================================
=#
