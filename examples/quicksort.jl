# Core algorithm verbatim from JuliaLang/Microbenchmarks (julia/perf.jl):
# https://github.com/JuliaLang/Microbenchmarks/blob/master/julia/perf.jl
# Only the @test/@timeit macro harness is replaced (Tsubaki has no macros),
# and issorted is written out longhand (not yet a builtin).

function qsort!(a, lo, hi)
    i, j = lo, hi
    while i < hi
        pivot = a[(lo + hi) >>> 1]
        while i <= j
            while a[i] < pivot
                i += 1
            end
            while a[j] > pivot
                j -= 1
            end
            if i <= j
                a[i], a[j] = a[j], a[i]
                i, j = i + 1, j - 1
            end
        end
        if lo < j
            qsort!(a, lo, j)
        end
        lo, j = i, hi
    end
    return a
end

function is_sorted(a)
    ok = true
    for i in 1:(length(a) - 1)
        if a[i] > a[i + 1]
            ok = false
        end
    end
    return ok
end

sortperf(n) = qsort!(rand(n), 1, n)

result = sortperf(5000)
println("is_sorted(sortperf(5000)) = ", is_sorted(result))

t0 = time()
sortperf(5000)
t1 = time()
println("elapsed: ", t1 - t0, " s")
