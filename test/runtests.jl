using ComponentLogging
using Logging
using Test

module ForwardLoggerTest
using ComponentLogging
using Logging
const buf = IOBuffer()
const logger_ref = Ref(ComponentLogger(Dict(:__default__ => Info, :core => Warn); sink=ConsoleLogger(buf, Debug)))
@forward_logger logger_ref
end

module ForwardLoggerTest2
using ComponentLogging
using Logging
const buf = IOBuffer()
const logger_ref = Ref(ComponentLogger(Dict(:__default__ => Info, :core => Info); sink=ConsoleLogger(buf, Debug)))
@forward_logger logger_ref
end

@testset "ComponentLogging.jl" begin
    buf = IOBuffer()
    rules = Dict((:core,) => Warn)
    sink = ConsoleLogger(buf, Debug)
    logger = ComponentLogger(rules; sink)
    set_module_logger(@__MODULE__, logger)

    # Helper to clear buffer
    clearbuf!() = (take!(buf); nothing)

    @testset "enable logic" begin
        @test clogenabled(logger, :__default__, Info) == true
        @test clogenabled(logger, :__default__, Debug) == false
        @test clogenabled(logger, :core, Warn) == true
        @test clogenabled(logger, :core, Info) == false
        @test clogenabled(logger, :core) == false
        @test (@clogenabled :core Warn) == true
        @test (@clogenabled :core Debug) == false
    end

    @testset "function API requires group" begin
        @test_throws MethodError clog(logger, Info, "missing group")
        @test_throws MethodError clogenabled(logger, Info)
    end

    @testset "clog emits when enabled" begin
        clearbuf!()
        # Enabled for :core at Warn
        clog(logger, :core, Warn, "hello warn")
        data = String(take!(buf))
        @test !isempty(data)

        clearbuf!()
        # Disabled at Debug for :core
        clog(logger, :core, Debug, "no debug")
        data2 = String(take!(buf))
        @test isempty(data2)

        clearbuf!()
        # Default group at Info is enabled
        clog(logger, :__default__, Info, "info default")
        @test !isempty(String(take!(buf)))
    end

    @testset "clogf lazy evaluation" begin
        counter = Ref(0)
        clearbuf!()
        # Disabled -> f() should not run
        clogf(logger, :core, Debug) do
            counter[] += 1
            "computed"
        end
        @test counter[] == 0
        @test isempty(String(take!(buf)))

        clearbuf!()
        # Enabled -> f() should run exactly once and emit
        clogf(logger, :core, Error) do
            counter[] += 1
            "computed"
        end
        @test counter[] == 1
        @test !isempty(String(take!(buf)))

        clearbuf!()
        # Enabled -> f() should run exactly once and emit
        @clogf :core Error () -> begin
            counter[] += 1
            "computed"
        end
        @test counter[] == 2
        @test !isempty(String(take!(buf)))
    end

    @testset "set_log_level! updates min_level cache" begin
        # Construct a standalone logger and exercise both lowering and raising the cache
        local logger = ComponentLogger(Dict{Symbol,LogLevel}(); sink)
        @test Logging.min_enabled_level(logger) === Info
        state = @atomic :acquire logger.state
        @test state.min_level === Info

        ComponentLogging.set_log_level!(logger, :foo, Debug)
        ComponentLogging.set_log_level!(logger, :bar, Debug)
        @test Logging.min_enabled_level(logger) === Debug
        state = @atomic :acquire logger.state
        @test state.min_level === Debug

        ComponentLogging.set_log_level!(logger, :foo, Error)
        @test Logging.min_enabled_level(logger) === Debug
        state = @atomic :acquire logger.state
        @test state.min_level === Debug

        ComponentLogging.set_log_level!(logger, :bar, Error)
        @test Logging.min_enabled_level(logger) === Info
        state = @atomic :acquire logger.state
        @test state.min_level === Info
    end

    @testset "concurrent rule updates" begin
        local logger = ComponentLogger(Dict{Symbol,LogLevel}(); sink)
        groups = [Symbol("group", string(i)) for i in 1:32]

        @sync for group in groups
            Threads.@spawn ComponentLogging.set_log_level!(logger, group, Debug)
        end
        @test Logging.min_enabled_level(logger) === Debug
        @test all(group -> clogenabled(logger, group, Debug), groups)

        @sync for group in groups
            Threads.@spawn ComponentLogging.set_log_level!(logger, group, Error)
        end
        @test Logging.min_enabled_level(logger) === Info
        @test all(group -> !clogenabled(logger, group, Debug), groups)
    end

    @testset "copy-on-write snapshots" begin
        local logger = ComponentLogger(Dict(:__default__ => Info, :a => Debug); sink)
        oldstate = @atomic :acquire logger.state
        oldrules = oldstate.rules

        ComponentLogging.set_log_level!(logger, :a, Error)
        newstate = @atomic :acquire logger.state

        @test newstate !== oldstate
        @test newstate.rules !== oldrules
        @test oldrules[(:a,)] === Debug
        @test newstate.rules[(:a,)] === Error
        @test oldstate.min_level === Debug
        @test newstate.min_level === Info
    end

    @testset "concurrent readers see consistent snapshots" begin
        local logger = ComponentLogger(Dict(:__default__ => Info, :a => Debug); sink)
        nreaders = max(2, Threads.nthreads())
        niter = 20_000

        writer = Threads.@spawn begin
            for i in 1:niter
                ComponentLogging.set_log_level!(logger, :a, isodd(i) ? Debug : Error)
            end
            nothing
        end

        readers = map(1:nreaders) do _
            Threads.@spawn begin
                ok = true
                for _ in 1:niter
                    state = @atomic :acquire logger.state
                    if state.min_level != minimum(values(state.rules))
                        ok = false
                        break
                    end
                end
                ok
            end
        end

        fetch(writer)
        @test all(fetch, readers)
    end

    @testset "concurrent logging and rule updates" begin
        local logger = ComponentLogger(Dict(:__default__ => Info, :a => Debug, (:a, :b) => Warn); sink)
        nreaders = max(2, Threads.nthreads())
        niter = 20_000

        writer = Threads.@spawn begin
            for i in 1:niter
                ComponentLogging.set_log_level!(logger, (:a, :b), isodd(i) ? Debug : Error)
            end
            nothing
        end

        readers = map(1:nreaders) do _
            Threads.@spawn begin
                ok = true
                for _ in 1:niter
                    ok &= clogenabled(logger, (:a, :b), Info) isa Bool
                    ok &= clogenabled(logger, :a, Debug) isa Bool
                end
                ok
            end
        end

        fetch(writer)
        @test all(fetch, readers)
    end

    @testset "set_log_level! Bool switch" begin
        local logger = ComponentLogger(Dict(:__default__ => Info, :sw => Info); sink)
        @test clogenabled(logger, :sw) == true
        ComponentLogging.set_log_level!(logger, :sw, false)
        @test clogenabled(logger, :sw) == false
        ComponentLogging.set_log_level!(logger, :sw, true)
        @test clogenabled(logger, :sw) == true
    end

    @testset "@clog macro literal group" begin
        clearbuf!()
        @clog :core Error "macro works"
        @test !isempty(String(take!(buf)))
    end

    @testset "@clog macro no group" begin
        clearbuf!()
        @clog Info "macro works (no group)"
        @test !isempty(String(take!(buf)))
    end

    @testset "@bind_logger binds module logger" begin
        old = ComponentLogging.get_logger(@__MODULE__)
        buf2 = IOBuffer()
        sink2 = ConsoleLogger(buf2, Debug)
        rules2 = Dict(:__default__ => Info, :core => Warn)

        lg = @bind_logger sink=sink2 rules=rules2
        @test lg isa ComponentLogger
        @test ComponentLogging.get_logger(@__MODULE__) === lg

        @clog :core Warn "bind_logger works"
        @test occursin("bind_logger works", String(take!(buf2)))

        ComponentLogging.set_module_logger(@__MODULE__, old)
    end

    @testset "@forward_logger generates forwarding methods" begin
        take!(ForwardLoggerTest.buf)
        take!(ForwardLoggerTest2.buf)

        ForwardLoggerTest.clog(:__default__, 0, "hello default")
        @test occursin("hello default", String(take!(ForwardLoggerTest.buf)))

        ForwardLoggerTest.clog(:core, 0, "blocked")
        @test isempty(String(take!(ForwardLoggerTest.buf)))

        ForwardLoggerTest.clogf(:core, 2000) do
            "allowed"
        end
        @test occursin("allowed", String(take!(ForwardLoggerTest.buf)))

        ForwardLoggerTest.set_log_level(:core, 0)
        @test ForwardLoggerTest.clogenabled(:core, 0) == true

        ForwardLoggerTest2.clog(:core, 0, "independent")
        @test occursin("independent", String(take!(ForwardLoggerTest2.buf)))
    end
end;

@testset "PlainLogger + ComponentLogger" begin
    # 1) Basic logging into an IOBuffer via PlainLogger sink
    pbuf = IOBuffer()
    plogger = PlainLogger(stream=pbuf, min_level=Debug)
    clogger = ComponentLogger(sink=plogger)
    set_module_logger(@__MODULE__, clogger)

    # ensure info is emitted to pbuf
    clog(clogger, :__default__, Info, "plain info")
    @test !isempty(String(take!(pbuf)))

    # kwargs appear
    clog(clogger, :__default__, Info, "with kw"; a=1, b="x")
    out = String(take!(pbuf))
    @test occursin("a = 1", out)
    @test occursin("b = x", out)

    # 2) Warn and location: using macro to ensure file/line is passed
    pbuf2 = IOBuffer()
    plogger2 = PlainLogger(stream=pbuf2, min_level=Debug)
    clogger2 = ComponentLogger(sink=plogger2)
    set_module_logger(@__MODULE__, clogger2)
    @clog :core Warn "warn here"
    out2 = String(take!(pbuf2))
    @test occursin("warn here", out2)
    @test occursin("runtests.jl", out2)  # basename present

    # 3) closed-stream fallback to stderr (use Pipe on Windows)
    plogger3 = PlainLogger(min_level=Info)
    clogger3 = ComponentLogger(sink=plogger3)
    set_module_logger(@__MODULE__, clogger3)

    w = Pipe()
    redirect_stderr(w)
    try
        clog(clogger3, :__default__, Warn, "fallback to stderr")
        flush(stderr)
    finally
        redirect_stderr(stdout)
    end
    close(w.in)
    data = read(w, String)
    @test occursin("fallback to stderr", data)
end;
