# fs.files: every file below a directory, sorted, as path + "/" + relative.
root = host("env.get", "HOST_TEST_DIR", "")
host("fs.mkdirp", root * "/t/sub/deeper")
host("fs.mkdirp", root * "/t/empty")
host("fs.write", root * "/t/b.txt", "b")
host("fs.write", root * "/t/a.txt", "a")
host("fs.write", root * "/t/sub/c.ex", "c")
host("fs.write", root * "/t/sub/deeper/d.ex", "d")

for f in host("fs.files", root * "/t")
    println(replace(f, root => ""))
end

try
    host("fs.files", root * "/t/nope")
catch e
    println("missing dir is an error: yes")
end
