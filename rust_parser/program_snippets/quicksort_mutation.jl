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

a = [5.0, 3.0, 8.0, 1.0, 9.0, 2.0, 7.0, 4.0, 6.0, 0.0]
sorted = qsort!(a, 1, length(a))
println(sorted)
println(is_sorted(sorted))
