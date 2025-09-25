using ComponentLogging
using Documenter

DocMeta.setdocmeta!(ComponentLogging, :DocTestSetup, :(using ComponentLogging); recursive=true)

makedocs(;
    modules=[ComponentLogging],
    authors="karei <abcdvvvv@gmail.com>",
    sitename="ComponentLogging.jl",
    format=Documenter.HTML(;
        canonical="https://abcdvvvv.github.io/ComponentLogging.jl",
        edit_link="master",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/abcdvvvv/ComponentLogging.jl",
    devbranch="master",
)
