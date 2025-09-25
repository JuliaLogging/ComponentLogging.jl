struct PlainLogger <: AbstractLogger
    io::IO
    lock::ReentrantLock
    minlevel::LogLevel
end

PlainLogger(io::IO, minlevel::LogLevel=Info) = PlainLogger(io, ReentrantLock(), minlevel)
PlainLogger(minlevel::LogLevel=Info) = PlainLogger(Base.CoreLogging.closed_stream, ReentrantLock(), minlevel)

Logging.min_enabled_level(l::PlainLogger) = l.minlevel
Logging.shouldlog(l::PlainLogger, level, _module, group, id) = level >= l.minlevel

function Logging.handle_message(l::PlainLogger, level::LogLevel, message, _module, group, id, file, line; kwargs...)
    stream::IO = l.io
    if !(isopen(stream)::Bool)
        stream = stderr
    end

    buf = IOBuffer()
    iob = IOContext(buf, stream)

    color = level >= Error ? :red : level >= Warn ? :yellow : level == Debug ? :green : :normal
    pretty(x) = begin
        if x isa AbstractArray{T,2} where {T} || x isa AbstractArray{T,3} where {T}
            str = sprint(show, MIME"text/plain"(), x)
            printstyled(iob, str; color)
        else
            printstyled(iob, x; color)
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
        print(iob, "\n ")
        printstyled(iob, k, " = "; color)
        pretty(v)
    end

    if level >= Warn && file !== nothing
        println(iob)
        printstyled(iob, "@ ", Base.basename(String(file)); color)
        if line !== nothing
            printstyled(iob, ":", line; color)
        end
    end
    println(iob)

    bytes = take!(buf)
    lock(l.lock) do
        write(stream, bytes)
    end
end