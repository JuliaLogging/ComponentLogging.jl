@kwdef struct PlainLogger <: AbstractLogger
    stream::IO = Base.CoreLogging.closed_stream
    lock::ReentrantLock = ReentrantLock()
    min_level::LogLevel = Info
end

Logging.min_enabled_level(logger::PlainLogger) = logger.min_level
Logging.shouldlog(::PlainLogger, level, _module, group, id) = true

function render_plain(iob, x::AbstractArray{T, N}) where {T, N}
    if N >= 2
        show(iob, MIME"text/plain"(), x)
    else
        print(iob, x)
    end
end

render_plain(iob, x) = print(iob, x)

function Logging.handle_message(l::PlainLogger, level::LogLevel, message::Union{Tuple, AbstractString}, _module, group, id, file, line; kwargs...)::Nothing
    @nospecialize kwargs

    stream::IO = l.stream
    if !(isopen(stream)::Bool)
        stream = stderr
    end

    buf = IOBuffer()
    iob = IOContext(buf, stream)

    if message isa Tuple
        for m in message
            render_plain(iob, m)
        end
    else
        render_plain(iob, message)
    end
    for (k, v) in kwargs
        print(iob, "\n ", k, " = ")
        render_plain(iob, v)
    end

    if _module !== nothing || file !== nothing
        meta = IOBuffer()
        print(meta, "\n@ ")
        _module !== nothing && print(meta, string(_module), " ")
        if file !== nothing
            print(meta, Base.basename(String(file)), " ")
            line !== nothing && print(meta, ":", line)
        end
        printstyled(iob, String(take!(meta)); color=:light_black)
    end
    println(iob)

    bytes = take!(buf)
    lock(l.lock) do
        write(stream, bytes)
    end
    nothing
end
