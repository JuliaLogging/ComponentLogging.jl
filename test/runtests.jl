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
        local logger = ComponentLogger(Dict(); sink)
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
