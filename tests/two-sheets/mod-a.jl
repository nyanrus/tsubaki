# 一枚目。lib(std)の役。module を置く。
#
# Tsubaki の裸の `using M` は「同じプログラムの中の module」を指す -- 本物の
# Julia は同じファイルの module には `using .M` と点を要る(そして Tsubaki は
# まだ点つきを読めない)。意図して違うところなので、この一組は Julia とは
# 比べない。
module Greet
    greeting = "hello"

    function say(name::String)
        return greeting * ", " * name
    end

    function shout(name::String)
        return say(name) * "!"
    end
end

# 一枚目も印字する -- 二枚目の出力に、これが混じらないこと
println("lib loaded")
