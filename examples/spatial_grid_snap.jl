# Uniform-grid spatial index over a (xs, ys) point set, for "snap to nearest
# node within radius" queries -- e.g. an editor snapping a click to the
# nearest of ~100k road nodes. Pure Tsubaki, no engine support needed: the
# grid's cell->points mapping is just a flat Array of Arrays (a Dict would
# also work now, and would be slower), indexed by `gy*nx+gx+1`. snap() only scans the 3x3 neighborhood
# of cells around the query point, not every point in the set -- that's the
# whole reason to build the grid instead of a linear scan.

mutable struct SpatialGrid
  cell_size::Float
  min_x::Float
  min_y::Float
  nx::Int
  ny::Int
  buckets::Array
end

# clamps to the grid's own bounds -- a query outside the point set's bounding
# box still lands in the nearest edge cell, rather than indexing out of range.
function cell_coords(grid::SpatialGrid, x, y)
  gx = Int(floor((x - grid.min_x) / grid.cell_size))
  gy = Int(floor((y - grid.min_y) / grid.cell_size))
  if gx < 0
    gx = 0
  end
  if gx > grid.nx - 1
    gx = grid.nx - 1
  end
  if gy < 0
    gy = 0
  end
  if gy > grid.ny - 1
    gy = grid.ny - 1
  end
  return gx, gy
end

function build_grid(xs::Vector, ys::Vector, cell_size::Float)
  n = length(xs)
  min_x = xs[1]
  max_x = xs[1]
  min_y = ys[1]
  max_y = ys[1]
  for i in 1:n
    if xs[i] < min_x
      min_x = xs[i]
    end
    if xs[i] > max_x
      max_x = xs[i]
    end
    if ys[i] < min_y
      min_y = ys[i]
    end
    if ys[i] > max_y
      max_y = ys[i]
    end
  end
  nx = Int(floor((max_x - min_x) / cell_size)) + 1
  ny = Int(floor((max_y - min_y) / cell_size)) + 1
  # Array{Array}, not Array{Vector}: a plain `[]` is an empty Array (of
  # anything) now, not an empty numeric Vector -- and these buckets hold
  # point INDICES, so an Array is what they were always going to be.
  buckets = Array{Array}(undef, nx * ny)
  for i in 1:(nx * ny)
    buckets[i] = []
  end
  grid = SpatialGrid(cell_size, min_x, min_y, nx, ny, buckets)
  for i in 1:n
    gx, gy = cell_coords(grid, xs[i], ys[i])
    idx = gy * grid.nx + gx + 1
    push!(grid.buckets[idx], i)
  end
  return grid
end

# nearest point index within radius, or -1 if none.
function snap(grid::SpatialGrid, xs::Vector, ys::Vector, qx, qy, radius)
  gx, gy = cell_coords(grid, qx, qy)
  best = -1
  best_d2 = radius * radius
  for dy in -1:1
    cy = gy + dy
    if cy >= 0 && cy <= grid.ny - 1
      for dx in -1:1
        cx = gx + dx
        if cx >= 0 && cx <= grid.nx - 1
          bucket = grid.buckets[cy * grid.nx + cx + 1]
          for k in 1:length(bucket)
            i = Int(bucket[k])
            ddx = xs[i] - qx
            ddy = ys[i] - qy
            d2 = ddx * ddx + ddy * ddy
            if d2 < best_d2
              best_d2 = d2
              best = i
            end
          end
        end
      end
    end
  end
  return best
end

# --- correctness, on a handful of known points ---
println("-- correctness --")
xs = [0.0, 1.0, 5.0, 5.1, 9.9]
ys = [0.0, 1.0, 5.0, 5.1, 9.9]
g = build_grid(xs, ys, 1.0)
println(snap(g, xs, ys, 0.1, 0.1, 2.0))      # 1
println(snap(g, xs, ys, 9.8, 9.8, 2.0))      # 5
println(snap(g, xs, ys, 3.0, 3.0, 0.5))      # -1 (nothing within radius)

# --- benchmark at road-node scale (~105k points) ---
println("-- benchmark (105000 points) --")
n = 105000
bxs = rand(n)
bys = rand(n)
t0 = time()
bg = build_grid(bxs, bys, 0.01) # ~100x100 cells over the unit square
t1 = time()
println("build: ", t1 - t0, "s for ", n, " points")

nq = 10000
t2 = time()
for q in 1:nq
  qx = rand()
  qy = rand()
  snap(bg, bxs, bys, qx, qy, 0.02)
end
t3 = time()
total = t3 - t2
println("query: ", total, "s for ", nq, " queries, ", total / nq * 1000.0, "ms/query avg")
