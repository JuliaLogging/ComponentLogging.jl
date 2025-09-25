struct PlainLogger <: AbstractLogger
    io::IO
    minlevel::LogLevel
end

Logging.min_enabled_level(l::PlainLogger) = l.minlevel
Logging.shouldlog(l::PlainLogger, level, _module, group, id) = level >= l.minlevel

function Logging.handle_message(l::PlainLogger, level::LogLevel, message, _module, group, id, file, line; kwargs...)
    io = stdout
    color = level >= Error ? :red : level >= Warn ? :yellow : level == Debug ? :green : :normal
    pretty(x) = begin
        if x isa AbstractArray{T,2} where {T} || x isa AbstractArray{T,3} where {T}
            str = sprint(show, MIME"text/plain"(), x)
            printstyled(io, str; color)
        else
            printstyled(io, x; color)
        end
    end

    if message isa Tuple
        for m in message
            pretty(m)
        end
    else
        pretty(message)
    end
    for (k, v) in kwargs
        print(io, "\n ")
        printstyled(io, k, " = "; color)
        pretty(v)
    end

    if level >= Warn && file !== nothing
        println(io)
        printstyled(io, "@ ", Base.basename(String(file)); color)
        if line !== nothing
            printstyled(io, ":", line; color)
        end
    end
    println(io)
end