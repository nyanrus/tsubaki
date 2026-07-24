# Core algorithm from JuliaLang/Microbenchmarks (julia/perf.jl), with the
# Ref()-based volatile-store workaround dropped (it's an old escape-analysis
# trick, not part of the actual algorithm, and Tsubaki has no Ref/[] deref).

function pisum()
    s = 0.0
    for j in 1:500
        s = 0.0
        for k in 1:10000
            s += 1.0 / (k * k)
        end
    end
    return s
end

result = pisum()
println("pisum() = ", result, "  [expect ~1.6449340668...]")

t0 = time()
pisum()
t1 = time()
println("elapsed: ", t1 - t0, " s")
