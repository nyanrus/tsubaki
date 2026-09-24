# Tsubaki — the language a drop's logic is written in

> **This page is for people meeting Tsubaki from inside a noraneko drop.**
> The language itself — the OCaml interpreter, WasmGC, the GPU work — lives in
> the [README](../README.md) and the other pages; this is just the depth that
> "write a drop's logic" needs.

drop の logic(`ops/*.tsubaki`)は、この言語で書きます。窓に触らず、DOM も preact も
知らない ── **state と action と view というデータだけ**を扱う、純粋なところ。
その理由と、何ができるかの表は noraneko-registry の
[`docs/ABI.md`](https://docs.f3liz.casa/f3liz-casa/noraneko-registry/docs/ABI) と
[`docs/GUIDE.md`](https://docs.f3liz.casa/f3liz-casa/noraneko-registry/docs/GUIDE) に。

## 最小の一枚

`ops/main.tsubaki` 一枚で drop が書けます(`drops/hello-tsubaki` が実物)。

```julia
PREF = "noraneko.hello.count"

setup() = Dict(
    "anchor" => Dict("at" => "parent", "selector" => "#nav-bar", "tag" => "hbox", "id" => "nora-hello"),
    "style" => "#nora-hello label { padding: 2px 8px; }",
    "prefs" => [PREF]
)

struct AppState
    count
end

STATE = AppState(0)

struct Bump end

view(s) = el("label", Dict("value" => "hello " * string(s.count), "on:click" => Bump()))

update(s::AppState, a::Bump) = Step(AppState(s.count + 1), [SetPref(PREF, s.count + 1)])

struct Step
    state
    effects
end

function start(facts)
    prefs = get(facts, :prefs, Dict())
    held = get(prefs, PREF, 0)
    STATE = AppState(held === nothing ? 0 : held)
    return frame(view(STATE))
end

function dispatch(a)
    kind = get(a, :__type, "")
    action = kind == "Bump" ? Bump() : error("unknown action " * kind)
    st = update(STATE, action)
    STATE = st.state
    return frame(view(STATE), st.effects)
end
```

三つの door がすべて。`setup()` はどこに置くか、`start(facts)` は最初の一枚、
`dispatch(action)` は次の一枚。**一枚 = `frame(view, effects)`**、view も effect も
データです。

## ここで覚えること(言語の顔ぶれ)

drop の logic で実際に使うのは、Julia の書き心地のうちのこの辺り:

| 書きかた | 何 |
|---|---|
| `struct` / `@kwdef struct` | state の形。`@kwdef` なら既定値を名前で |
| `update(s::AppState, a::Bump) = ...` | **多重ディスパッチ**。action ごとに一つ method |
| `Dict(...)` / `el("label", Dict("value" => …))` | view の木。`"style" => Dict("width" => "320px")` |
| `"on:command" => Select(id)` | 行事の値は closure ではなく **action そのもの** |
| `[SetPref(PREF, n)]` | effect の並び。effect もデータ(作るだけ、するのは殻) |
| `get(d, :key, 既定)` / `put(d, key, v)` / `merge` | Dict のことば(`:key` は文字の鍵も読む) |
| `t(:add)` | 字は鍵で書く。どのロケールになるかは殻が決める |
| `Ask(["uuid"], "AddPanel")` / `Measure("#box", "SetWidth")` | 事実を**訊く**(logic は作らない) |
| `40px` / `var(--…)` の棚(`Theme`) | style はデータとして。単位も色も名前で |

**Tsubaki の言語そのもの**を深く知りたいときは、下の一枚へ。drop を書くだけなら、
上の表と `drops/hello-tsubaki` と `drops/webpanel` の実物で足ります。

## もっと知る

- [`language.md`](language.md) — 言語の基本を一枚に(値・型・関数と多重ディスパッチ・制御・module・macro)
- [`../README.md`](../README.md) — 言語の全体(何ができるか、deliberately できないこと、benchmark)
- [`../ROADMAP.md`](../ROADMAP.md) — `LinearAlgebra` の段取り
- [`../AST_IN_RUST_EXPERIMENT.md`](../AST_IN_RUST_EXPERIMENT.md) — 制限つき bytecode compiler と VM
- [`../rust_parser/README.md`](../rust_parser/README.md) — 式を Rust へ写した枝(差分テストのため)
- drop の作法 — [ABI](https://docs.f3liz.casa/f3liz-casa/noraneko-registry/docs/ABI) ·
  [GUIDE](https://docs.f3liz.casa/f3liz-casa/noraneko-registry/docs/GUIDE) ·
  [LAYERS](https://docs.f3liz.casa/f3liz-casa/noraneko-registry/docs/LAYERS)
