# julia: yes
# The four algorithm bodies from JuliaLang/Microbenchmarks (julia/perf.jl),
# checked for their ANSWERS only -- no timing, so this is deterministic and
# the identical file runs under real Julia to prove the answers agree.
# The timings live in examples/, where they belong.

fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)
println("fib(20) = ", fib(20))

function pisum()
    sum = 0.0
    for j = 1:500
        sum = 0.0
        for k = 1:10000
            sum += 1.0 / (k * k)
        end
    end
    return sum
end
println("pisum() = ", pisum())

function qsort!(a, lo, hi)
    i = lo
    j = hi
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
                i += 1
                j -= 1
            end
        end
        if lo < j
            qsort!(a, lo, j)
        end
        lo = i
        j = hi
    end
    return a
end

function sortperf(n)
    v = zeros(n)
    for i in 1:n
        v[i] = (i * 7919) % n
    end
    qsort!(v, 1, n)
    return v
end

function is_sorted(v)
    for i in 2:length(v)
        if v[i - 1] > v[i]
            return false
        end
    end
    return true
end
sorted = sortperf(5000)
println("is_sorted(sortperf(5000)) = ", is_sorted(sorted))
println("first ", sorted[1], " last ", sorted[5000])

function mandel(z)
    c = z
    maxiter = 80
    for n in 1:maxiter
        if abs(z) > 2
            return n - 1
        end
        z = z^2 + c
    end
    return maxiter
end

function mandelperf()
    total = 0
    for r in -20:5
        for i in -10:10
            total += mandel(complex(r * 0.1, i * 0.1))
        end
    end
    return total
end
println("sum(mandelperf()) = ", mandelperf())
