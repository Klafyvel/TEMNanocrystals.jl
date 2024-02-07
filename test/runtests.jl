using TEMNanocrystals
using Test
using Aqua

@testset "TEMNanocrystals.jl" begin
    @testset "Code quality (Aqua.jl)" begin
        Aqua.test_all(TEMNanocrystals, ambiguities = false)
    end
    # Write your tests here.
end
