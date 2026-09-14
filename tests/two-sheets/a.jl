# 一枚目。lib(std)の役。global と型と method を置く。
# こちらの一組は、本物の Julia でもそのまま走る。
shared = 40

struct Point
    x::Int
    y::Int
end

function describe(p::Point)
    return "point"
end

function twice(x::Int)
    return x + x
end

# 既定のある引数 -- Param.default は `1 + irep`
function add(a::Int, b::Int = 2)
    return a + b
end

# keyword の既定 -- Kwparam.default は生の irep。この非対称が踏みどころ
function tagged(x::Int; label::String = "n")
    return label * "=" * string(x)
end

# 一枚目も印字する -- 二枚目の出力に、これが混じらないこと
println("lib loaded")
