# every refusal is an ordinary error the program can catch
function attempt(f)
    try
        f()
        println("no error")
    catch e
        println("caught: ", e)
    end
end

attempt(() -> host("no.such.capability"))
attempt(() -> host("fs.read", "/definitely/not/here/x.txt"))
attempt(() -> host("fs.read", 42))
attempt(() -> host("fs.write", "/tmp/x"))
attempt(() -> host("json.parse", "{not json"))
attempt(() -> host("exit", "three"))
println("still running")
