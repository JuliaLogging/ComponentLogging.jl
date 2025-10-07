using ComponentLogging
using Documenter

DocMeta.setdocmeta!(ComponentLogging, :DocTestSetup, :(using ComponentLogging); recursive=true)

#! format: off
makedocs(;
    modules  = [ComponentLogging],
    authors  = "karei <abcdvvvv@gmail.com>",
    sitename = "ComponentLogging.jl",
    format   = Documenter.HTML(;
        canonical = "https://julialogging.github.io/ComponentLogging.jl",
        edit_link = "master",
        assets    = String[],
    ),
    pages    = [
        "Home" => "index.md",
        "API"  => [
            "Common Types" => "common_types.md",
            "Functions"    => "functions.md",
            "Macros"       => "macros.md",]
    ],
)

deploydocs(;
    repo="github.com/JuliaLogging/ComponentLogging.jl",
    devbranch="master",
)
