# julia: yes
# LinearAlgebra, checked by its ANSWERS rather than its display: Tsubaki
# prints a Matrix on one line where real Julia prints an aligned grid, so
# every result here is read out element by element. Anything coming back from
# a decomposition is rounded to 6 places first -- faer and LAPACK are both
# correct and need not agree in the last bits (see ROADMAP.md).

# LinearAlgebra is built in here, so this line is a no-op for Tsubaki -- it
# is what lets the identical file run under real Julia too.
using LinearAlgebra

r6(x) = round(x * 1000000.0) / 1000000.0

A = [4.0 1.0; 2.0 3.0]
B = [1.0 0.0; 1.0 2.0]
v = [1.0, 2.0]

println("A[1,1] = ", A[1, 1], ", A[2,1] = ", A[2, 1], ", size = ", size(A))

C = A * B
println("A*B = ", C[1, 1], " ", C[1, 2], " ", C[2, 1], " ", C[2, 2])

Av = A * v
println("A*v = ", Av[1], " ", Av[2])

T = transpose(A)
println("A' = ", T[1, 1], " ", T[1, 2], " ", T[2, 1], " ", T[2, 2])

println("det(A) = ", det(A), ", tr(A) = ", tr(A), ", rank(A) = ", rank(A))
println("dot(v, v) = ", dot(v, v), ", norm(v) = ", r6(norm(v)))

x = A \ v
println("A\\v = ", r6(x[1]), " ", r6(x[2]))
check = A * x
println("A*(A\\v) = ", r6(check[1]), " ", r6(check[2]))

Ai = inv(A)
println("inv(A) = ", r6(Ai[1, 1]), " ", r6(Ai[1, 2]), " ", r6(Ai[2, 1]), " ", r6(Ai[2, 2]))

# a scaled identity absorbs into ordinary matrix arithmetic
S = A + 2I
println("A + 2I = ", S[1, 1], " ", S[1, 2], " ", S[2, 1], " ", S[2, 2])

# zeros/ones, and a rectangular product with its dimension check
Z = zeros(2, 3)
O = ones(3, 2)
P = Z * O
println("size(zeros(2,3)*ones(3,2)) = ", size(P), ", P[1,1] = ", P[1, 1])

# a symmetric matrix's eigenvalues are real and come back ascending
Sym = [2.0 1.0; 1.0 2.0]
ev = eigvals(Sym)
println("eigvals([2 1; 1 2]) = ", r6(ev[1]), " ", r6(ev[2]))

# singular values are canonical: descending, sign-free
sv = svd([3.0 0.0; 0.0 4.0])
println("svd singular values = ", r6(sv.S[1]), " ", r6(sv.S[2]))

# an LU factorization reconstructs its input
F = lu(A)
println("lu: L[2,1] = ", r6(F.L[2, 1]), ", U[1,1] = ", r6(F.U[1, 1]))

# cholesky of a positive-definite matrix
ch = cholesky([4.0 2.0; 2.0 3.0])
println("cholesky: L[1,1] = ", r6(ch.L[1, 1]), ", L[2,1] = ", r6(ch.L[2, 1]))

# a QR factorization's R is upper-triangular
qrf = qr([1.0 2.0; 3.0 4.0])
println("qr: R[2,1] = ", r6(qrf.R[2, 1]))
