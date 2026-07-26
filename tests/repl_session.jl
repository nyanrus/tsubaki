# Not a program -- a REPL SESSION. tools/test.py feeds any test whose name
# starts with `repl` to `--repl` on stdin instead of running it as a file, so
# the golden here is a whole transcript, prompts included.
#
# What it is here to hold down: state carries from one prompt to the next, a
# declaration spanning several lines is not evaluated until it is finished,
# a trailing `;` keeps the value quiet, and NOTHING is fatal -- after each
# error the prompt comes back with everything still defined.
1 + 1
x = 21
x * 2
sqrt(2.0)
"interpolating $x"
function square(n)
    return n * n
end
square(7)
struct Point
    x
    y
end
p = Point(3, 4)
p.x + p.y
square(3);
undefined_name
square(1, 2, 3)
[1.0, 2.0][9]
square(x)
if x > 10
    println("x is big")
else
    println("x is small")
end
for i in 1:3
    println("  tick ", i)
end
v = [10.0, 20.0, 30.0]
v[end]
length(v)
