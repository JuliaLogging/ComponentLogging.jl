using BenchmarkTools, Logging, Printf

# Null sink (avoid I/O)
struct NullSinkLogger <: AbstractLogger
    minlevel::LogLevel
end
Logging.min_enabled_level(l::NullSinkLogger) = l.minlevel
Logging.shouldlog(::NullSinkLogger, args...) = true
Logging.handle_message(::NullSinkLogger, args...; kwargs...) = nothing
Logging.catch_exceptions(::NullSinkLogger) = false

import ComponentLogging as CL
const RK = CL.RuleKey
const DEFAULT = try (CL.Default_Sym,) catch; (CL.DEFAULT_SYM,) end

## Create logger
# Explicitly add rules for: default group, :opti, (:a,:b), and (:a,:b,:c,:d,:e,:f,:g,:h)
const TUP2 = (:a, :b)
const TUP8 = (:a, :b, :c, :d, :e, :f, :g, :h)

function make_logger(minlvl::Integer)
    rules = Dict{RK,LogLevel}(
        DEFAULT => minlvl,
        (:opti,) => minlvl,
        TUP2 => minlvl,
        TUP8 => minlvl,
    )
    return CL.ComponentLogger(rules; sink=NullSinkLogger(Debug))
end

const LG_ENABLED  = make_logger(0)     # Allow level 0
const LG_FILTERED = make_logger(2000)  # Filter out level 0

## Benchmark messages
const MSG_STR = "x"
const MSG_TUP = ("x", 123, :sym)   # Multiple arguments/mixed types
## Suite
const Suite = BenchmarkGroup()

# 1) Filtered path (min=2000, sending 0) - Decision and routing cost
Suite["filtered"]                  = BenchmarkGroup()
Suite["filtered"]["clog/default"]  = @benchmarkable CL.clog($LG_FILTERED, $DEFAULT, 0, $MSG_STR)
Suite["filtered"]["clog/symbol"]   = @benchmarkable CL.clog($LG_FILTERED, :opti, 0, $MSG_STR)
Suite["filtered"]["clog/tuple2"]   = @benchmarkable CL.clog($LG_FILTERED, $TUP2, 0, $MSG_STR)
Suite["filtered"]["clog/tuple8"]   = @benchmarkable CL.clog($LG_FILTERED, $TUP8, 0, $MSG_STR)

# 2) Allowed path (min=0, sending 0) - Decision + assembly + call
Suite["enabled"] = BenchmarkGroup()
# 2.1 Single string
Suite["enabled"]["clog/default/str"] = @benchmarkable CL.clog($LG_ENABLED, $DEFAULT, 0, $MSG_STR)
Suite["enabled"]["clog/symbol/str"]  = @benchmarkable CL.clog($LG_ENABLED, :opti, 0, $MSG_STR)
Suite["enabled"]["clog/tuple2/str"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP2, 0, $MSG_STR)
Suite["enabled"]["clog/tuple8/str"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP8, 0, $MSG_STR)
# 2.2 Multiple arguments/mixed types
Suite["enabled"]["clog/default/tuple"] = @benchmarkable CL.clog($LG_ENABLED, $DEFAULT, 0, $MSG_TUP...)
Suite["enabled"]["clog/tuple2/tuple"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP2, 0, $MSG_TUP...)
Suite["enabled"]["clog/tuple8/tuple"]  = @benchmarkable CL.clog($LG_ENABLED, $TUP8, 0, $MSG_TUP...)
# 3) Explicit macro path
Suite["enabled"]["@clog"] = @benchmarkable CL.@clog $LG_ENABLED :opti 0 $MSG_STR
Suite["filtered"]["@clog"] = @benchmarkable CL.@clog $LG_FILTERED :opti 0 $MSG_STR

## Run & Display
tune!(Suite; seconds=2.0)
results = run(Suite; verbose=true)

if get(ENV, "CI", "false") != "true"
    println("\n" * "─"^24 * " SUMMARY (ns/op，allocs) " * "─"^25)
    function _summarize!(results, prefix="")
        for (k, v) in results
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
end

#=
===== SUMMARY (ns/op，allocs) =====
filtered/clog/tuple2                  3.50 ns        0 allocs     0.00 KiB
filtered/clog/default                 2.80 ns        0 allocs     0.00 KiB
filtered/clog/symbol                  2.40 ns        0 allocs     0.00 KiB
filtered/clog/tuple8                  2.40 ns        0 allocs     0.00 KiB
enabled/clog/default/str             15.53 ns        0 allocs     0.00 KiB
enabled/clog/tuple2/str              24.80 ns        0 allocs     0.00 KiB
enabled/clog/tuple8/tuple           188.63 ns        0 allocs     0.00 KiB
enabled/clog/symbol/str              13.73 ns        0 allocs     0.00 KiB
enabled/clog/default/tuple           15.53 ns        0 allocs     0.00 KiB
enabled/clog/tuple2/tuple            24.80 ns        0 allocs     0.00 KiB
enabled/clog/tuple8/str             191.80 ns        0 allocs     0.00 KiB
====================================
=#
