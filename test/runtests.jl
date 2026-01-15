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

    @testset "set_log_level! affects min" begin
        # Construct a standalone logger and adjust levels
        local logger = ComponentLogger(Dict{Nothing,Nothing}(); sink)
        @test Logging.min_enabled_level(logger) === Info
        ComponentLogging.set_log_level!(logger, (:foo,), Debug)
        @test Logging.min_enabled_level(logger) === Debug
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

        ForwardLoggerTest.set_log_level!(:core, 0)
        @test ForwardLoggerTest.clogenabled(:core, 0) == true

        oldmin = ForwardLoggerTest.logger_ref[].min
        ForwardLoggerTest.with_min_level(2000) do
            @test ForwardLoggerTest.logger_ref[].min == LogLevel(2000)
        end
        @test ForwardLoggerTest.logger_ref[].min == oldmin

        ForwardLoggerTest2.clog(:core, 0, "independent")
        @test occursin("independent", String(take!(ForwardLoggerTest2.buf)))
    end
end;

@testset "PlainLogger + ComponentLogger" begin
    # 1) Basic logging into an IOBuffer via PlainLogger sink
    pbuf = IOBuffer()
    plogger = PlainLogger(pbuf, Debug)
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
    plogger2 = PlainLogger(pbuf2, Debug)
    clogger2 = ComponentLogger(sink=plogger2)
    set_module_logger(@__MODULE__, clogger2)
    @clog :core Warn "warn here"
    out2 = String(take!(pbuf2))
    @test occursin("warn here", out2)
    @test occursin("runtests.jl", out2)  # basename present

    # 3) closed-stream fallback to stderr (use Pipe on Windows)
    plogger3 = PlainLogger(Info)
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
