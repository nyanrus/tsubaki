# julia: yes
# The numeric tower: exact Rationals, Complex, and the fixed-width integers
# with their wrapping arithmetic and checked conversions.

# ---- Rational: exact between Rationals and Ints, Float-promoting otherwise
half = 1 // 2
third = 1 // 3
println(half, " ", third, " ", half + third, " ", half - third)
println(half * third, " ", half / third)
println(2 // 4, " ", -3 // 9, " ", 6 // 3)
println(numerator(3 // 9), " ", denominator(3 // 9))
println(half + 1, " ", half * 4, " ", 1 - half)
println(half + 0.25, " ", half == 0.5)
println(half < third, " ", half > third, " ", 2 // 4 == 1 // 2)
println(abs(-3 // 4))

# ---- Complex
z = complex(1.0, 2.0)
w = complex(3.0, -1.0)
println(z, " ", w)
println(real(z), " ", imag(z))
println(z + w, " ", z - w, " ", z * w)
println(z^2)
println(abs(complex(3.0, 4.0)))

# ---- fixed-width integers: same-type arithmetic wraps, conversion is checked
a = Int8(100)
b = Int8(100)
println(a, " + ", b, " = ", a + b, "  (wraps)")
println(Int8(-128) - Int8(1))
println(UInt8(255) + UInt8(1))
println(Int16(300) * Int16(200))

# ---- integer and float arithmetic edges
println(div(7, 2), " ", 7 ÷ 2, " ", div(-7, 2), " ", fld(-7, 2), " ", cld(7, 2))
println(abs(-3), " ", abs(-3.5), " ", sign(-2), " ", sign(0))
println(floor(2.7), " ", ceil(2.1), " ", round(2.5), " ", round(3.5))
println(sqrt(16.0), " ", exp(0.0), " ", log(1.0))
println(min(1, 2.5), " ", max(1, 2.5))
