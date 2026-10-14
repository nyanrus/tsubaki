# fs / env / json capabilities. HOST_TEST_DIR is set by the test.
root = host("env.get", "HOST_TEST_DIR", "")
println("default: ", host("env.get", "HOST_NO_SUCH_VAR", "fallback"))
println("absent without default: ", host("env.get", "HOST_NO_SUCH_VAR") === nothing)

host("fs.mkdirp", root * "/out/deep")
host("fs.write", root * "/out/a.txt", "hello \"quoted\"\nline two")
println("exists: ", host("fs.exists", root * "/out/a.txt"), " ", host("fs.exists", root * "/out/nope"))
println("read: ", host("fs.read", root * "/out/a.txt"))

host("fs.copy", root * "/out/a.txt", root * "/out/deep/b.txt")
println("copied: ", host("fs.read", root * "/out/deep/b.txt") == host("fs.read", root * "/out/a.txt"))

host("fs.mkdirp", root * "/out/zeta")
host("fs.mkdirp", root * "/out/alpha")
println("dirs: ", host("fs.dirs", root * "/out"))

parsed = host("json.parse", "{\"a\": [1, 2, {\"b\": \"x\"}], \"n\": null}")
println("parsed: ", parsed["a"][3]["b"], " ", length(parsed["a"]), " ", parsed["n"] === nothing)
println("stringified: ", host("json.stringify", Dict("k" => [1, "two"])))

host("fs.rmrf", root * "/out")
println("after rmrf: ", host("fs.exists", root * "/out"))
host("fs.rmrf", root * "/out")      # absent is fine
println("done")
