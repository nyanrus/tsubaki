# julia: yes
# SparseMatrixCSC, built from COO/triplets the way real Julia's own
# `sparse(I, J, V, m, n)` takes them. Read out by answers, not display --
# Tsubaki summarizes a sparse matrix in one line where real Julia prints a
# grid. `using SparseArrays` is a no-op here (it is built in) and is what
# lets the identical file run under real Julia.
using SparseArrays
using LinearAlgebra

r6(x) = round(x * 1000000.0) / 1000000.0

rows = [1, 2, 3, 1]
cols = [1, 2, 3, 3]
vals = [4.0, 5.0, 6.0, 1.0]
S = sparse(rows, cols, vals, 3, 3)

println("size = ", size(S), ", nnz = ", nnz(S))

b = [1.0, 1.0, 1.0]
y = S * b
println("S*b = ", y[1], " ", y[2], " ", y[3])

x = S \ b
println("S\\b = ", r6(x[1]), " ", r6(x[2]), " ", r6(x[3]))

back = S * x
println("S*(S\\b) = ", r6(back[1]), " ", r6(back[2]), " ", r6(back[3]))

# an all-zero sparse matrix
Z = spzeros(2, 4)
println("spzeros: size = ", size(Z), ", nnz = ", nnz(Z))

# dense -> sparse drops exact zeros, and densifying gets the values back
D = [1.0 0.0; 0.0 2.0]
SD = sparse(D)
println("sparse(dense): nnz = ", nnz(SD))
back2 = Matrix(SD)
println("Matrix(sparse(D)) = ", back2[1, 1], " ", back2[1, 2], " ", back2[2, 1], " ", back2[2, 2])

# a tridiagonal-shaped system, checked the only way that really settles it:
# feed the solution back through and see whether it reproduces the right side
tri_rows = [1, 1, 2, 2, 2, 3, 3, 3, 4, 4]
tri_cols = [1, 2, 1, 2, 3, 2, 3, 4, 3, 4]
tri_vals = [4.0, -1.0, -1.0, 4.0, -1.0, -1.0, 4.0, -1.0, -1.0, 4.0]
T = sparse(tri_rows, tri_cols, tri_vals, 4, 4)

function worst_residual(A, b)
    got = A * (A \ b)
    worst = 0.0
    for i in 1:length(b)
        d = abs(got[i] - b[i])
        if d > worst
            worst = d
        end
    end
    return worst
end

rhs = ones(4)
println("tridiagonal 4x4: nnz = ", nnz(T), ", worst residual < 1e-9: ", worst_residual(T, rhs) < 1.0e-9)
