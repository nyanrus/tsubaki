(* Tsubaki: a toy Julia-like language, OCaml-hosted, aimed at wasm_of_ocaml (WasmGC).
   A generalized struct-based type system (any `struct`/`abstract type`
   declaration creates a real runtime type, not a hardcoded OCaml variant), and an
   actual lexer + recursive-descent parser + evaluator for a minimal Julia-like
   surface syntax, wired into a single multiple-dispatch engine. See README.md
   for what's actually supported and what isn't. *)

(* ============================= entry point ============================= *)

(* `node ... main.bc.wasm.js path/to/file.jl` runs that file; with no argument,
   falls back to the embedded demo below. Paths are resolved the same way
   `node`'s own relative-path handling would -- relative to wherever the
   process was launched from. *)
let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  content

(* CurveBridge always runs (it just registers f/add and exports two JS
   globals) -- forced to actually link post file-split via this explicit
   call (see CurveBridge.init's own comment for why a call was needed at
   all: an unreferenced module's top-level effects were silently dropped
   from the compiled wasm/js output, verified directly). But the CLI
   file-loading/demo-fallback below assumes a Node process (Sys.argv,
   host_matvec wired up by preload.js) and has no business running when
   this module is instead loaded as a browser library (e.g. from
   museum.atfedi.de). Node is the only real caller of that CLI surface, so
   gate the whole thing on it actually being Node. *)
let () = CurveBridge.init ()
let () = GpuBridge.init ()
let () = WebglBridge.init ()
let () = PhysicsBridge.init ()
let () = AudioBridge.init ()
let () = Ecs.init ()
let () = ParallelBridge.init ()

(* the browser path (`is_node = false`): unlike CurveBridge (a self-
   contained toy that only ever registers f/add), a real Tsubaki PROGRAM
   needs actual source text -- there's no Sys.argv/file to read in a
   browser, so the host page sets `globalThis.tsubakiSource` before this
   script loads (see web/demo.html). Runs it once: this registers the
   program's own functions/structs and executes its top-level statements,
   including any `on_frame(...)` call (see GpuBridge) that arms the
   per-frame callback `tsubakiRunFrame` (also GpuBridge) later re-enters
   from the host page's own `requestAnimationFrame` loop. *)
(* Eval.run, but an error is REPORTED rather than left to OCaml's own
   top-level handler -- which printed `Fatal error: exception Failure("...")`
   and, for a parse error, the raw constructor name of an internal exception.
   The message inside was often perfectly good (Parser's own errors carry
   line and column); it was just wearing an OCaml uncaught-exception coat.
   Only the CLI path uses this: in a browser, an exception surfacing in the
   console with its stack is the more useful thing. *)
(* an uncaught runtime error, reported WITH the place it happened: the
   statement's own file and line (Runtime.current_position, kept current by
   the SLine markers -- see Ast), then the chain of calls that led there,
   innermost first. Before this, a runtime error named only what failed
   ("no method matching describe(String)") and left finding it to the reader.
   A CAUGHT error is untouched -- `catch e` still sees the same bare value
   real Julia's own does, with no position glued onto its message. *)
let report_runtime_error msg =
  (* nothing unwinds the position or the frames on the way out of a raised
     error (see Eval's tree_walk_impl), so they are still sitting exactly
     where it happened *)
  let where = Runtime.position_of !Runtime.current_file !Runtime.current_line in
  print_endline (if where = "" then "tsubaki: " ^ msg else Printf.sprintf "tsubaki: %s\n  at %s" msg where);
  match Runtime.frames_snapshot () with
  | [] -> ()
  | frames ->
    print_endline "  in:";
    List.iter (fun (name, line) -> print_endline (Printf.sprintf "    %s, called from line %d" name line)) frames

let run_or_report src =
  match Eval.run src with
  | () -> ()
  | exception Parser.Parse_error msg ->
    print_endline ("tsubaki: " ^ msg);
    exit 1
  | exception Runtime.JuliaError v ->
    report_runtime_error (Runtime.show v);
    exit 1
  | exception Failure msg ->
    report_runtime_error msg;
    exit 1

let rec main () =
  let open Js_of_ocaml in
  let is_node =
    Js.to_bool (Js.Unsafe.js_expr "!!(globalThis.process && globalThis.process.versions && globalThis.process.versions.node)")
  in
  if not is_node then (
    let has_source = Js.to_bool (Js.Unsafe.js_expr "typeof globalThis.tsubakiSource === 'string'") in
    (* the host page also tells us where that source came from, so `include`
       can resolve a sibling file against it (see Eval's include) *)
    let has_path = Js.to_bool (Js.Unsafe.js_expr "typeof globalThis.tsubakiSourcePath === 'string'") in
    if has_path then (
      let p = Js.to_string (Js.Unsafe.js_expr "globalThis.tsubakiSourcePath") in
      Runtime.current_file_dir := Filename.dirname p;
      (* so a runtime error in a browser-hosted program names its own file
         too, the same way it does under the CLI *)
      Runtime.current_file := p);
    if has_source then Eval.run (Js.to_string (Js.Unsafe.js_expr "globalThis.tsubakiSource")))
  else (
  (* the CLI, parsed as flags-in-any-order rather than by matching Sys.argv's
     exact shape. `main.bc.wasm.js foo.jl --frames 600` used to match NO shape
     at all and fall silently through to the embedded demo below -- the demo
     runs, prints happily, and the file you asked for never runs at all. A
     mis-typed CLI must say so, not do something else convincingly. *)
  let usage = "usage: tsubaki [--repl | [--frames N] path/to/file.jl]" in
  let die msg =
    print_endline ("tsubaki: " ^ msg);
    print_endline usage;
    exit 1
  in
  let frames = ref None in
  let path = ref None in
  let repl = ref false in
  let rec parse = function
    | [] -> ()
    | "--repl" :: rest ->
      repl := true;
      parse rest
    | "--frames" :: n_str :: rest ->
      (match int_of_string_opt n_str with
      | Some n when n >= 0 -> frames := Some n
      | _ -> die (Printf.sprintf "--frames wants a frame count, got %s" n_str));
      parse rest
    | [ "--frames" ] -> die "--frames wants a frame count"
    | arg :: _ when String.length arg > 0 && arg.[0] = '-' -> die ("unknown option " ^ arg)
    | arg :: rest ->
      if !path <> None then die ("more than one script given (" ^ Option.get !path ^ " and " ^ arg ^ ")");
      path := Some arg;
      parse rest
  in
  parse (List.tl (Array.to_list Sys.argv));
  if !repl then (
    if !path <> None then die "--repl takes no script (it reads from the prompt)";
    if !frames <> None then die "--repl and --frames are different things to do";
    Repl.run ())
  else
  match !path with
  | None ->
    if !frames <> None then die "--frames needs a script to run";
    demo ()
  | Some path -> (
    match read_file path with
    | exception Sys_error msg ->
      print_endline ("error: " ^ msg);
      exit 1
    | src -> (
      Runtime.current_file_dir := Filename.dirname path;
      Runtime.current_file := path;
      run_or_report src;
      match !frames with
      | None ->
        (* a worker runs the very same script -- that is how it comes to know the
           same structs and the same systems, already compiled -- and then, instead
           of exiting, waits for the jobs main sends it. The script's own setup is
           skipped on its side by `if !is_worker()`, so the world is built once,
           on main, and the workers attach to it. See parallelBridge.ml. *)
        if ParallelBridge.is_worker () then ParallelBridge.serve ()
      | Some n ->
        (* headless mode: the file has already run once above (registering its
           on_frame(...) callback, if any, the same way the browser path's
           top-level Eval.run does); now drive GpuBridge.run_frame directly N
           times -- no requestAnimationFrame/JS host loop needed. preload.js
           stubs the draw/input/audio host_* calls a frame body might make.

           A frame that RAISES stops the run, with a non-zero exit code. The
           browser keeps going after a bad frame (see run_frame's own comment);
           here there's no one watching the console, and a frame that died
           halfway leaves a world its own program never meant to reach -- so
           every frame after it is measuring fiction. Better to stop at the
           first one and say which. *)
        let ok = ref true in
        let i = ref 1 in
        while !ok && !i <= n do
          (* fixed 1/60s dt in headless mode -- matches bouncing_balls' own
             hardcoded step and needs no host clock *)
          ok := GpuBridge.run_frame (1.0 /. 60.0);
          incr i
        done;
        if not !ok then (
          print_endline
            (Printf.sprintf "tsubaki: stopped at frame %d of %d -- the frame above raised, and the rest of that frame's body never ran"
               (!i - 1) n);
          exit 1))))

and demo () =
  print_endline "=== Tsubaki: parsed source, generalized struct types ===";
  print_endline "";
  Eval.run
    {|
abstract type Entity end

struct Vec2
    x
    y
end

mutable struct Player <: Entity
    pos
    vel
    radius
end

mutable struct Enemy <: Entity
    pos
    vel
    radius
end

mutable struct Wall <: Entity
    pos
    vel
    radius
end

function update!(e::Entity, dt)
    e.pos = Vec2(e.pos.x + e.vel.x * dt, e.pos.y + e.vel.y * dt)
end

function update!(w::Wall, dt)
    w
end

function dist(a::Entity, b::Entity)
    dx = a.pos.x - b.pos.x
    dy = a.pos.y - b.pos.y
    sqrt(dx * dx + dy * dy)
end

function collide!(a::Player, b::Enemy)
    if dist(a, b) < a.radius + b.radius
        println("  ! collide!(Player,Enemy): player hit")
    end
end

player = Player(Vec2(1.0, 5.0), Vec2(2.0, 0.0), 0.5)
enemy = Enemy(Vec2(9.0, 5.0), Vec2(-2.0, 0.0), 0.5)
wall = Wall(Vec2(0.0, 0.0), Vec2(0.0, 0.0), 0.0)

for tick in 1:3
    println("tick", tick)
    update!(player, 1.0)
    update!(enemy, 1.0)
    update!(wall, 1.0)
    collide!(player, enemy)
    println("  player: ", player)
    println("  enemy:  ", enemy)
end

r = rotate(Vec2(1.0, 0.0), pi / 2.0)
println("rotate((1,0), 90deg) = ", r, "  [Vec2 struct, via Rust/faer FFI]")

v = [1.0, 2.0]
v = push!(v, 3.0)
v = push!(v, 4.0)
println("push!'d vector: ", v)

s = "hello" + ", " + "Tsubaki"
println(s)

println("")
println("-- Union types --")
function describe(x::Union{Int,Float})
    println("  a number: ", x)
end
describe(3)
describe(3.5)

println("")
println("-- closures (real lexical capture, not just globals) --")
add1 = x -> x + 1
println("  add1(41) = ", add1(41))

function make_adder(n)
    return x -> x + n
end
add5 = make_adder(5)
println("  make_adder(5)(10) = ", add5(10))

println("")
println("-- try/catch/error: user errors and built-in MethodErrors both catchable --")
function safe_div(a, b)
    if b == 0
        error("division by zero")
    end
    a / b
end
try
    safe_div(1, 0)
catch e
    println("  caught: ", e)
end
try
    describe("not a number")
catch e
    println("  caught: ", e)
end

println("")
println("-- comprehension --")
squares = [x * x for x in 1:5]
println("  [x*x for x in 1:5] = ", squares)

println("")
println("-- float ranges (a:b and a:step:b, not just Int) --")
println("  [x for x in -1.0:0.5:1.0] = ", [x for x in -1.0:0.5:1.0])
println("  [x for x in 0.0:1.0]      = ", [x for x in 0.0:1.0], "  [default step 1.0]")

println("")
println("-- 2D comprehension: two for-clauses build a real Matrix --")
grid = [i + r for i = 1:3, r = 10:10:30]
println("  [i+r for i=1:3, r=10:10:30] = ", grid)

println("")
println("-- keyword arguments --")
function greet(name; greeting = "Hello", punctuation = "!")
    println("  ", greeting, ", ", name, punctuation)
end
greet("shiro")
greet("shiro"; greeting = "yo")
greet("shiro"; greeting = "yo", punctuation = "?")

println("")
println("-- parametric types: struct Box{T} --")
struct Box{T}
    value::T
end
bi = Box(5)
bf = Box(3.5)
println("  typeof(Box(5))   -> ", bi)
println("  typeof(Box(3.5)) -> ", bf)

function describe_box(b::Box)
    println("  some box holding: ", b.value)
end
function describe_box(b::Box{Int})
    println("  an Int box specifically, value*2 = ", b.value * 2)
end
describe_box(bi)
describe_box(bf)

println("")
println("-- inner constructors, new/new{T}, and a self-referential struct --")
struct PositiveBox
    value
    function PositiveBox(value)
        if value < 0
            error("PositiveBox: value must be non-negative")
        end
        new(value)
    end
end
println("  PositiveBox(5) = ", PositiveBox(5))
try
    PositiveBox(-1)
catch e
    println("  PositiveBox(-1) caught: ", e)
end

mutable struct Node{T}
    val::T
    next::Node{T}
    function Node{T}(val) where T
        # new(...) can take FEWER args than there are fields -- exactly
        # what makes a self-referential struct constructible at all: `next`
        # can't be given a value before this very node exists yet
        n = new{T}(val)
        n.next = n
        return n
    end
end
n = Node(42)
println("  n.val = ", n.val, ", n.next.val = ", n.next.val, "  [self-referential]")

println("")
println("-- multi-parameter parametric types: struct Pair{K,V} --")
struct Pair{K, V}
    key::K
    value::V
end
p1 = Pair(1, "one")
p2 = Pair("x", 3.5)
println("  Pair(1, \"one\")  -> ", p1, "  typeof = ", typeof(p1))
println("  Pair(\"x\", 3.5)  -> ", p2, "  typeof = ", typeof(p2))

function describe_pair(p::Pair)
    println("  some pair: ", p.key, " => ", p.value)
end
function describe_pair(p::Pair{Int, String})
    println("  an (Int,String) pair specifically: ", p.key, " => ", p.value)
end
describe_pair(p1)
describe_pair(p2)

println("")
println("-- && / || (short-circuit) --")
function in_range(x, lo, hi)
    x >= lo && x <= hi
end
println("  in_range(5, 1, 10) = ", in_range(5, 1, 10))
println("  in_range(50, 1, 10) = ", in_range(50, 1, 10))

function called(tag)
    println("    (evaluated: ", tag, ")")
    true
end
println("  false && called(\"right of &&\"):")
r1 = false && called("right of &&")
println("  -> ", r1, "   [right side must NOT have printed]")
println("  true || called(\"right of ||\"):")
r2 = true || called("right of ||")
println("  -> ", r2, "   [right side must NOT have printed]")

println("")
println("-- vector indexing v[i] (1-indexed) --")
vi = [10.0, 20.0, 30.0]
println("  vi[1] = ", vi[1], ", vi[3] = ", vi[3], ", length(vi) = ", length(vi))
vi[2] = 99.0
println("  after vi[2] = 99.0: ", vi)

println("")
println("-- string interpolation --")
name = "shiro"
count = 3
println("hello $name, count is $count")

println("")
println("-- multiple return values / destructuring --")
function minmax(a, b)
    if a < b
        return a, b
    end
    return b, a
end
lo, hi = minmax(9, 3)
println("  minmax(9,3) -> lo=", lo, " hi=", hi)
t = minmax(1, 2)
println("  as a single Tuple value: ", t)

println("")
println("-- named function declared inside another now closes over it too --")
function make_counter_demo()
    n = 0
    function bump()
        n = n + 1
        println("  bump() -> n is now ", n)
    end
    bump()
    bump()
    bump()
end
make_counter_demo()

println("")
println("-- end (in indexing), ternary, compound assignment, step ranges --")
vv = [10.0, 20.0, 30.0, 40.0]
println("  vv[end] = ", vv[end], ", vv[end-1] = ", vv[end - 1])

x = 7
label = x % 2 == 0 ? "even" : "odd"
println("  7 is ", label)

acc = 10
acc += 5
acc *= 2
println("  10, += 5, *= 2 -> ", acc)

evens = [i for i in 0:2:10]
println("  [i for i in 0:2:10] = ", evens)

countdown = [i for i in 10:-2:0]
println("  [i for i in 10:-2:0] = ", countdown)

println("")
println("-- redefining a function replaces it, no longer piles up ambiguous copies --")
function greet_v(x)
    println("  v1: hello ", x)
end
greet_v("a")
function greet_v(x)
    println("  v2: hi ", x)
end
greet_v("b")

println("")
println("-- Matrix literal (real Julia's whitespace syntax now), straight into the Rust/faer FFI boundary --")
A = [1.0 2.0; 3.0 4.0]
y = A * [1.0, 1.0]
println("  [1 2; 3 4] * [1,1] = ", y, "  [expect [3,7]]")

println("")
println("-- \$(expr) string interpolation --")
a = 3
b = 4
println("a=$a b=$b a+b=$(a + b) a*b squared=$((a * b) * (a * b))")

println("")
println("-- struct field type enforcement --")
mutable struct Point
    x::Float
    y::Float
end
p = Point(1.0, 2.0)
println("  Point(1.0, 2.0) = ", p)
try
    bad = Point(1.0, "not a float")
catch e
    println("  caught: ", e)
end

println("")
println("-- struct field type enforcement on assignment too, not just construction --")
p.x = 9.0
println("  p.x = 9.0 -> ", p)
try
    p.y = "nope"
catch e
    println("  caught: ", e)
end

println("")
println("-- vector slicing v[a:b] --")
sv = [10.0, 20.0, 30.0, 40.0, 50.0]
println("  sv[2:4] = ", sv[2:4])
println("  sv[2:end] = ", sv[2:end])

println("")
println("-- multi-statement anonymous function: function (args) ... end --")
classify = function (x)
    if x < 0
        return "negative"
    end
    "non-negative"
end
println("  classify(-3) = ", classify(-3))
println("  classify(3) = ", classify(3))

println("")
println("-- isa / typeof --")
println("  typeof(3) = ", typeof(3))
println("  typeof(3.5) = ", typeof(3.5))
println("  typeof(p) = ", typeof(p))
println("  isa(3, Int) = ", isa(3, Int))
println("  isa(3, Float) = ", isa(3, Float))
println("  isa(3, Number) = ", isa(3, Number))
println("  isa(p, Point) = ", isa(p, Point))

println("")
println("-- Array: a Vector that can hold structs (or anything), not just numbers --")
struct Named
    label
    value
end
items = [Named("a", 1.0), Named("b", 2.0)]
println("  typeof(items) = ", typeof(items))
println("  items[1] = ", items[1])
items = push!(items, Named("c", 3.0))
println("  after push!: length = ", length(items))
total = 0.0
for it in items
    total = total + it.value
end
println("  sum of .value = ", total)
items[2] = Named("B", 99.0)
println("  items[2:3] = ", items[2:3])

println("")
println("-- parametric Array{T}: dispatch on what an Array actually holds --")
println("  typeof(items) = ", typeof(items), "  [not just \"Array\" -- homogeneous, so it's tagged by element type]")
function greetAll(a::Array)
    println("  some array of ", length(a), " things")
end
function greetAll(a::Array{Named})
    println("  an array of Named specifically, ", length(a), " of them")
end
greetAll(items)
greetAll([1, "mixed", true])
println("  isa(items, Array) = ", isa(items, Array), "  [Array{Named} <: Array, same trick as Box{Int} <: Box]")

println("")
println("-- Array{T}() : a real declared, enforced element type (not just inferred) --")
roster = Array{Named}()
println("  typeof(Array{Named}()) = ", typeof(roster), "  length = ", length(roster), "  [declared even while empty]")
roster = push!(roster, Named("a", 1.0))
println("  after push!(Named(...)): ", roster)
try
    push!(roster, 5.0)
catch e
    println("  caught (expected, 5.0 isn't a Named): ", e)
end

println("")
println("-- covariant subtyping: Array{Player} <: Array{Entity}, Pair{Int,String} <: Pair{Number,Any} --")
abstract type Being end
struct Human <: Being
    name
end
humans = [Human("a"), Human("b")]
function census(a::Array{Being})
    println("  a census of Beings: ", length(a))
end
census(humans)

function describe_numeric_pair(p::Pair{Number, Any})
    println("  a Pair keyed by a Number: ", p.key, " => ", p.value)
end
describe_numeric_pair(Pair(1, "one"))
describe_numeric_pair(Pair(3.5, "three and a half"))
println("-- comprehension can build an Array now, not just a numeric Vector --")
named_squares = [Named(i, i * i) for i in 1:4]
println("  typeof(named_squares) = ", typeof(named_squares))
println("  named_squares = ", named_squares)
still_numeric = [i * i for i in 1:4]
println("  typeof([i*i for i in 1:4]) = ", typeof(still_numeric), "  [unchanged: still Vector]")

println("")
println("-- modules: module/using namespace functions AND struct/type names now --")
module Shapes
    struct Circle
        r
    end
    function area(c::Circle)
        return pi * c.r * c.r
    end
    function ring_area(outer, inner)
        return area(Circle(outer)) - area(Circle(inner))
    end
end
try
    area(Circle(1.0))
catch e
    println("  bare Circle/area both fail before `using Shapes` now -- caught: ", e)
end
println("  Shapes.Circle(1.0) / Shapes.area(...) work right away via qualified access:")
c1 = Shapes.Circle(1.0)
println("    Shapes.area(c1) = ", Shapes.area(c1))
using Shapes
c2 = Circle(2.0)
println("  after `using Shapes`, bare Circle/area work too -- same tag either way:")
println("    typeof(c1) = ", typeof(c1), ", typeof(c2) = ", typeof(c2), ", area(c2) = ", area(c2))
println("  ring_area(2.0, 1.0) = ", ring_area(2.0, 1.0), "  [calls area() by its own bare name from inside Shapes]")
try
    Shapes.nope(1)
catch e
    println("  Shapes.nope(1) -- qualified access is strict, no silent fallback: ", e)
end

module ModA
    function tag_of(x::Int)
        return "ModA saw an Int"
    end
end
module ModB
    function tag_of(x::String)
        return "ModB saw a String"
    end
end
using ModA
using ModB
println("  two modules' same-named, unrelated tag_of coexist after using both:")
println("    tag_of(5)   -> ", tag_of(5))
println("    tag_of(\"x\") -> ", tag_of("x"))

println("")
println("-- macros: quote/unquote, hygiene, gensym, esc() --")
e = :(1 + 2)
println("  :(1 + 2) = ", e, "  typeof = ", typeof(e))
println("  eval(:(1 + 2)) = ", eval(e))

macro double(x)
    :($x + $x)
end
println("  @double(3 + 4) = ", @double(3 + 4), "  [expands to (3+4)+(3+4), not 3+4+3+4]")

println("  hygiene: a macro's own temp variable can't clobber the call site's --")
macro my_max(a, b)
    quote
        tmp = $a
        if $b > tmp
            tmp = $b
        end
        tmp
    end
end
tmp = "this must survive untouched"
println("    @my_max(3, 7) = ", @my_max(3, 7))
println("    outer tmp is still: ", tmp)

println("  esc(): a macro that mutates the CALLER's own variables --")
macro swap!(a, b)
    quote
        tmp2 = $(esc(a))
        $(esc(a)) = $(esc(b))
        $(esc(b)) = tmp2
    end
end
x = 1
y = 2
@swap!(x, y)
println("    @swap!(x, y): x = ", x, ", y = ", y, "  [expect x=2, y=1]")

println("  gensym(): a fresh, guaranteed-unique Symbol on demand --")
println("    gensym() = ", gensym(), ", gensym() = ", gensym(), "  [always different]")

println("  a macro generating control flow (a for loop) --")
macro repeat(n, body)
    quote
        for i in 1:$n
            $body
        end
    end
end
@repeat(2, println("    repeated line"))

println("")
println("-- triple-quoted strings and export: found necessary by running real package source --")
module RealPackageShape
export package_hello
"""
    package_hello(name)

Return a greeting for `name` -- a real docstring, closed by three quotes,
not one.
"""
package_hello(name) = "Hello, $name"
end
using RealPackageShape
println("  ", package_hello("World"))
|}

let () = main ()
