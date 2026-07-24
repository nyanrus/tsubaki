function greet(name; greeting = "Hello", punctuation = "!")
    println(greeting, ", ", name, punctuation)
end
greet("shiro")
greet("shiro"; greeting = "yo")
greet("shiro"; greeting = "yo", punctuation = "?")
