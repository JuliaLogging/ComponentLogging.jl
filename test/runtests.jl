using ComponentLogging
using Logging
using Test

@testset "ComponentLogging.jl" begin
    buf = IOBuffer()
    rules = Dict((:core,) => Warn)
    sink = ConsoleLogger(buf, Debug)
    logger = ComponentLogger(rules; sink)
    set_module_logger(@__MODULE__, logger)

    # Helper to clear buffer
    clearbuf!() = (take!(buf); nothing)

    @testset "enable logic" begin
        @test clogenabled(logger, Info) == true
        @test clogenabled(logger, Debug) == false
        @test clogenabled(logger, :core, Warn) == true
        @test clogenabled(logger, :core, Info) == false
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
        clog(logger, Info, "info default")
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

    @testset "@clog macro literal group" begin
        clearbuf!()
        @clog :core Error "macro works"
        @test !isempty(String(take!(buf)))
    end
end;

@testset "PlainLogger + ComponentLogger" begin
    # 1) Basic logging into an IOBuffer via PlainLogger sink
    pbuf = IOBuffer()
    plogger = PlainLogger(pbuf, Debug)
    clogger = ComponentLogger(sink=plogger)
    set_module_logger(@__MODULE__, clogger)

    # ensure info is emitted to pbuf
    clog(clogger, Info, "plain info")
    @test !isempty(String(take!(pbuf)))

    # kwargs appear
    clog(clogger, Info, "with kw"; a=1, b="x")
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
        clog(clogger3, Warn, "fallback to stderr")
        flush(stderr)
    finally
        redirect_stderr(stdout)
    end
    close(w.in)
    data = read(w, String)
    @test occursin("fallback to stderr", data)
end;
