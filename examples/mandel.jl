# Core algorithm from JuliaLang/Microbenchmarks (julia/perf.jl):
# https://github.com/JuliaLang/Microbenchmarks/blob/master/julia/perf.jl
#
# mandel() AND mandelperf() are both verbatim now -- real(), imag(), ^,
# Complex, Float ranges, and a real 2-clause comprehension all exist in Tsubaki.
# The only difference left from the original is the @test/@timeit macro
# harness, swapped for plain Tsubaki code, same as the other three benchmarks
# (Tsubaki has no macros at all).

function mandel(z)
    c = z
    maxiter = 80
    for n in 1:maxiter
        if real(z) * real(z) + imag(z) * imag(z) > 4
            return n - 1
        end
        z = z^2 + c
    end
    return maxiter
end

mandelperf() = [mandel(complex(r, i)) for i = -1.0:0.1:1.0, r = -2.0:0.1:0.5]

result = sum(mandelperf())
println("sum(mandelperf()) = ", result, "  [expect 14791]")

t0 = time()
mandelperf()
t1 = time()
println("elapsed: ", t1 - t0, " s")
