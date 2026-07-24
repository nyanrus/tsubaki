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
println(result)
