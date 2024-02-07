import Pkg
Pkg.activate(temp=true)
Pkg.add("PackageCompiler")
using PackageCompiler
create_app(
    "", "build/", 
    precompile_statements_file="temnanocrystals_precompile.jl",
    include_lazy_artifacts=true,
    filter_stdlibs=false,
    force=true
)
