# Core algorithm verbatim from JuliaLang/Microbenchmarks (julia/perf.jl):
# https://github.com/JuliaLang/Microbenchmarks/blob/master/julia/perf.jl
# Only the @test/@timeit macro harness is replaced (Tsubaki has no macros).

fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)

result = fib(20)
println("fib(20) = ", result, "  [expect 6765]")

t0 = time()
fib(20)
t1 = time()
println("elapsed: ", t1 - t0, " s")
