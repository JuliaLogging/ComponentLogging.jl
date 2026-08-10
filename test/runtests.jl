using ComponentLogging
using Logging
using Test

module ForwardLoggerTest
using ComponentLogging
using Logging

const buf = IOBuffer()
const logger = ComponentLogger(Dict(:__default__ => 0, :core => 1000); sink=PlainLogger(stream=buf))
@forward_logger logger

function macro_side_effects()
    values = Int[]
    @clog :core 1000 push!(values, 1) push!(values, 2) nothing
    @clog :core -2000 push!(values, 3) nothing
    return values
end

function macro_source_line()
    expected_line = (@__LINE__) + 1
    @clog :__default__ 0 "forwarded metadata"
    return expected_line
end
end

module ForwardLoggerFieldTest
using ComponentLogging
using Logging

const buf = IOBuffer()
const state = Ref((logger=ComponentLogger(Dict(:__default__ => 0); sink=PlainLogger(stream=buf)),))
@forward_logger state[].logger

emit(level=0) = @clog :field level "field logger"
end

module ForwardLoggerConsumer
using Logging
using ..ForwardLoggerTest: @clog

emit() = @clog :__default__ 0 "consumer"
end

function direct_macro_side_effects(logger)
    values = Int[]
    @clog logger :core 1000 push!(values, 1) push!(values, 2) nothing
    @clog logger :core -2000 push!(values, 3) nothing
    return values
end

function direct_macro_hygiene(logger)
    _lg = :outer_logger
    _grp = :outer_group
    _lvl = :outer_level
    _id = :outer_id
    _msgs = :outer_messages
    @clog logger :core 1000 "hygiene"
    return (_lg, _grp, _lvl, _id, _msgs)
end

function direct_macro_source_line(logger)
    expected_line = (@__LINE__) + 1
    @clog logger :core 1000 "direct metadata"
    return expected_line
end

@testset "ComponentLogging" begin
    buf = IOBuffer()
    sink = ConsoleLogger(buf, -2000)
    logger = ComponentLogger(Dict((:core,) => 1000); sink)
    clearbuf!() = (take!(buf); nothing)

    @testset "enable logic" begin
        @test clogenabled(logger, :__default__, 0)
        @test !clogenabled(logger, :__default__, -2000)
        @test clogenabled(logger, :core, 1000)
        @test !clogenabled(logger, :core, 0)
        @test !clogenabled(logger, :core)
        @test get_log_level(logger, :core) === Warn
        @test get_log_level(logger, (:core, :child)) === Warn
        @test get_log_level(logger, :other) === Info
    end

    @testset "function API" begin
        @test_throws MethodError clog(logger, 0, "missing group")
        @test_throws MethodError clogenabled(logger, 0)

        clearbuf!()
        clog(logger, :core, 1000, "hello warn")
        @test !isempty(String(take!(buf)))

        clearbuf!()
        clog(logger, :core, -2000, "no debug")
        @test isempty(String(take!(buf)))

        clearbuf!()
        clog(logger, :__default__, 0, "info default")
        @test !isempty(String(take!(buf)))
    end

    @testset "@clog lazy evaluation" begin
        counter = Ref(0)
        clearbuf!()
        @clog logger :core -2000 begin
            counter[] += 1
            "computed"
        end
        @test counter[] == 0
        @test isempty(String(take!(buf)))

        clearbuf!()
        @clog logger :core 2000 begin
            counter[] += 1
            "computed"
        end
        @test counter[] == 1
        @test !isempty(String(take!(buf)))
    end

    @testset "explicit logging macros" begin
        clearbuf!()
        group = (:core,)
        level = 1000
        @clog logger group level "dynamic group and level"
        @test occursin("dynamic group and level", String(take!(buf)))

        clearbuf!()
        @clog logger :core 2000 "explicit macro"
        @test occursin("explicit macro", String(take!(buf)))

        @test direct_macro_side_effects(logger) == [1, 2]
        @test direct_macro_hygiene(logger) == (
            :outer_logger,
            :outer_group,
            :outer_level,
            :outer_id,
            :outer_messages,
        )
        @test occursin("hygiene", String(take!(buf)))

        clearbuf!()
        @cdebug logger :core "debug shorthand"
        @cinfo logger :__default__ "info shorthand"
        @cwarn logger :core "warn shorthand"
        @cerror logger :core "error shorthand"
        shorthand_output = String(take!(buf))
        @test !occursin("debug shorthand", shorthand_output)
        @test occursin("info shorthand", shorthand_output)
        @test occursin("warn shorthand", shorthand_output)
        @test occursin("error shorthand", shorthand_output)

        clearbuf!()
        source_line = direct_macro_source_line(logger)
        source_output = String(take!(buf))
        @test occursin("direct metadata", source_output)
        @test occursin("runtests.jl:$source_line", source_output)

        @test_throws ErrorException macroexpand(@__MODULE__, :(@clog logger :core 0))
        expansion = sprint(show, macroexpand(@__MODULE__, :(@clog logger :core 0 "expanded")))
        @test !occursin("get_logger", expansion)
    end

    @testset "rule snapshots" begin
        local logger = ComponentLogger(Dict{Symbol,LogLevel}(); sink)
        @test Logging.min_enabled_level(logger) === Info
        @test (@atomic :acquire logger.state).min_level === Info

        set_log_level!(logger, :foo, -2000)
        set_log_level!(logger, :bar, -2000)
        @test Logging.min_enabled_level(logger) === LogLevel(-2000)
        @test (@atomic :acquire logger.state).min_level === LogLevel(-2000)

        set_log_level!(logger, :foo, 2000)
        @test Logging.min_enabled_level(logger) === LogLevel(-2000)
        set_log_level!(logger, :bar, 2000)
        @test Logging.min_enabled_level(logger) === Info

        local logger = ComponentLogger(Dict(:__default__ => 0, :a => -2000); sink)
        oldstate = @atomic :acquire logger.state
        oldrules = oldstate.rules
        set_log_level!(logger, :a, 2000)
        newstate = @atomic :acquire logger.state

        @test newstate !== oldstate
        @test newstate.rules !== oldrules
        @test oldrules[(:a,)] === LogLevel(-2000)
        @test newstate.rules[(:a,)] === Error
        @test oldstate.min_level === LogLevel(-2000)
        @test newstate.min_level === Info
    end

    @testset "set_log_level!" begin
        local logger = ComponentLogger(Dict(:__default__ => 0, :sw => 0); sink)
        @test clogenabled(logger, :sw)
        set_log_level!(logger, :sw, false)
        @test !clogenabled(logger, :sw)
        set_log_level!(logger, :sw, true)
        @test clogenabled(logger, :sw)

        logger = ComponentLogger(Dict(:__default__ => 0, :a => 1000, :b => 2000); sink)
        oldstate = @atomic :acquire logger.state
        oldrules = oldstate.rules
        result = set_log_level!(
            logger,
            :a, -2000,
            :b, false,
            (:c, :d), 0,
            :e, true,
        )
        newstate = @atomic :acquire logger.state

        @test result === logger
        @test newstate !== oldstate
        @test newstate.rules !== oldrules
        @test oldrules[(:a,)] === Warn
        @test oldrules[(:b,)] === Error
        @test newstate.rules[(:a,)] === LogLevel(-2000)
        @test newstate.rules[(:b,)] === LogLevel(1)
        @test newstate.rules[(:c, :d)] === Info
        @test newstate.rules[(:e,)] === Info
        @test Logging.min_enabled_level(logger) === LogLevel(-2000)
        @test clogenabled(logger, :a, -2000)
        @test !clogenabled(logger, :b)
        @test clogenabled(logger, (:c, :d))
        @test clogenabled(logger, :e)

        logger = ComponentLogger(Dict(:__default__ => 0, :a => 1000); sink)
        oldstate = @atomic :acquire logger.state
        @test_throws ArgumentError set_log_level!(logger, :a, -2000, :b)
        @test (@atomic :acquire logger.state) === oldstate
        @test clogenabled(logger, :a, 1000)
        @test !clogenabled(logger, :a, -2000)
    end

    @testset "concurrent rule access" begin
        local logger = ComponentLogger(Dict{Symbol,LogLevel}(); sink)
        groups = [Symbol("group", string(i)) for i in 1:32]

        @sync for group in groups
            Threads.@spawn set_log_level!(logger, group, -2000)
        end
        @test Logging.min_enabled_level(logger) === LogLevel(-2000)
        @test all(group -> clogenabled(logger, group, -2000), groups)

        @sync for group in groups
            Threads.@spawn set_log_level!(logger, group, 2000)
        end
        @test Logging.min_enabled_level(logger) === Info
        @test all(group -> !clogenabled(logger, group, -2000), groups)

        logger = ComponentLogger(Dict(:__default__ => 0, :a => -2000); sink)
        nreaders = max(2, Threads.nthreads())
        niter = 20_000
        writer = Threads.@spawn begin
            for i in 1:niter
                set_log_level!(logger, :a, isodd(i) ? -2000 : 2000)
            end
        end
        readers = map(1:nreaders) do _
            Threads.@spawn begin
                for _ in 1:niter
                    state = @atomic :acquire logger.state
                    state.min_level == minimum(values(state.rules)) || return false
                end
                return true
            end
        end
        fetch(writer)
        @test all(fetch, readers)

        logger = ComponentLogger(Dict(:__default__ => 0, :a => -2000, (:a, :b) => 1000); sink)
        writer = Threads.@spawn begin
            for i in 1:niter
                set_log_level!(logger, (:a, :b), isodd(i) ? -2000 : 2000)
            end
        end
        readers = map(1:nreaders) do _
            Threads.@spawn begin
                for _ in 1:niter
                    clogenabled(logger, (:a, :b), 0) isa Bool || return false
                    clogenabled(logger, :a, -2000) isa Bool || return false
                end
                return true
            end
        end
        fetch(writer)
        @test all(fetch, readers)
    end

    @testset "@forward_logger" begin
        take!(ForwardLoggerTest.buf)
        ForwardLoggerTest.clog(:__default__, 0, "hello default")
        @test occursin("hello default", String(take!(ForwardLoggerTest.buf)))

        ForwardLoggerTest.clog(:core, 0, "blocked")
        @test isempty(String(take!(ForwardLoggerTest.buf)))

        @test ForwardLoggerTest.get_log_level(:core) === Warn
        ForwardLoggerTest.set_log_level!(:core, 0)
        @test ForwardLoggerTest.clogenabled(:core, 0)
        @test ForwardLoggerTest.get_log_level(:core) === Info
        set_log_level!(ForwardLoggerTest.logger, :core, 1000)

        @test ForwardLoggerTest.macro_side_effects() == [1, 2]
        @test isempty(String(take!(ForwardLoggerTest.buf)))

        source_line = ForwardLoggerTest.macro_source_line()
        source_output = String(take!(ForwardLoggerTest.buf))
        @test occursin("forwarded metadata", source_output)
        @test occursin("runtests.jl :$source_line", source_output)

        ForwardLoggerConsumer.emit()
        @test occursin("consumer", String(take!(ForwardLoggerTest.buf)))

        expansion = sprint(show, macroexpand(ForwardLoggerTest, :(@clog :core 1000 "expanded")))
        @test occursin("ForwardLoggerTest.logger", expansion)
        @test !occursin("get_logger", expansion)

        take!(ForwardLoggerFieldTest.buf)
        ForwardLoggerFieldTest.emit()
        @test occursin("field logger", String(take!(ForwardLoggerFieldTest.buf)))

        field_buf = IOBuffer()
        ForwardLoggerFieldTest.state[] = (
            logger=ComponentLogger(Dict(:__default__ => 2000); sink=PlainLogger(stream=field_buf)),
        )
        ForwardLoggerFieldTest.emit()
        @test isempty(String(take!(field_buf)))
    end
end

@testset "PlainLogger + ComponentLogger" begin
    pbuf = IOBuffer()
    plogger = PlainLogger(stream=pbuf)
    clogger = ComponentLogger(sink=plogger)

    clog(clogger, :__default__, 0, "plain info")
    @test !isempty(String(take!(pbuf)))

    clog(clogger, :__default__, 0, "with kw"; a=1, b="x")
    out = String(take!(pbuf))
    @test occursin("a = 1", out)
    @test occursin("b = x", out)

    pbuf2 = IOBuffer()
    plogger2 = PlainLogger(stream=pbuf2)
    clogger2 = ComponentLogger(sink=plogger2)
    @clog clogger2 :core 1000 "warn here"
    out2 = String(take!(pbuf2))
    @test occursin("warn here", out2)
    @test occursin("runtests.jl", out2)

    plogger3 = PlainLogger()
    clogger3 = ComponentLogger(sink=plogger3)
    w = Pipe()
    redirect_stderr(w)
    try
        clog(clogger3, :__default__, 1000, "fallback to stderr")
        flush(stderr)
    finally
        redirect_stderr(stdout)
    end
    close(w.in)
    @test occursin("fallback to stderr", read(w, String))
end
