url = host("env.get", "HOST_TEST_URL", "")
ok = host("http.post_json", url * "/ok", "secret-token", Dict("emojis" => [Dict("shortcode" => "a")], "dry_run" => true))
println("ok: ", ok["status"], " ", ok["body"]["imported"], " ", ok["body"]["results"][1]["status"])

refused = host("http.post_json", url * "/refuse", "", Dict("x" => 1))
println("refused: ", refused["status"], " ", refused["body"]["error"])

text = host("http.post_json", url * "/text", "", Dict())
println("text: ", text["status"], " ", text["body"])

try
    host("http.post_json", "http://127.0.0.1:1/unreachable", "", Dict())
catch e
    println("unreachable is an error: yes")
end
