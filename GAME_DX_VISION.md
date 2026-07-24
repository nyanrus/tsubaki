# Tsubaki Game DX — 設計思想 (Keel)

> ゲームエンジン群を研究して、「親切で便利なUX」でゲームを書けるように
> Tsubaki を設計し直すための、**思想を先に描いた**ドキュメント。
> 実装計画ではなく、*どうあれば気持ちいいか* を先に決める。
> レンズは nyanrus が足した第五の軸 —— **Julia準拠**。

これは「Tsubaki を別物のエンジンに作り替える」話ではありません。むしろ逆で、
痛みのほとんどに *Julia 自身の語彙* が既に答えを持っている、という発見の
記録です。文字列コンポーネント名も、floatスープの引数も、`state[17]` の
手計算も、immutable再構築も —— 多重ディスパッチ・キーワード引数・
`T(x; f=v)` の部分更新・値型・`do`ブロック・Observable。理想のゲームDXは、
たぶん *「ちゃんと使われた Julia」* とほぼ同義になる。

研究した対象: **Bevy**(ECS as functions) / **Godot**(nodes・signals) /
**Love2D・PyGame Zero・GameZero.jl**(最小親切ループ) / **Unity**(DOTS・Inspector) /
**Flecs**(query DSL・observers) / **Overseer.jl・Glimpse.jl・Starlight.jl**(Julia の
ECS) / **Makie.jl Observable + GeometryBasics + StaticArrays**(反応的グラフィクス
と値型) / **Julia イディオム道具箱**(`@kwdef`・`@set`/Setfield・broadcasting・
`do`ブロック・Revise)。

---

## 0. 正直な前提 —— Tsubaki は今どこにいるか

「Julia準拠」を語るなら、素の Julia との差を正直に知っておきたい。
ソースを実際に見て確かめた台帳:

**Tsubaki が既に持っている(=土台になる):**

- 多重ディスパッチ・抽象型階層・first-class 型 (`Type{X}`, `VType`)
- mutable / immutable struct、しかも **意味が正直**: immutable ⇒ 列指向(SoA)で
  速い・スナップショット的、mutable ⇒ AoS で参照的に書ける
- **キーワード引数**(定義も呼び出しも。parser が `(args, kwargs)` を返す)
- **部分更新コンストラクタ `T(existing; field=val)`** —— 既存の全フィールドを
  コピーして名前付きの上書きだけ適用する。real Julia の `@set`/Setfield と
  まさに同じものが、任意の構造体に対して *もう言語に入っている* (`eval.ml:482`)
- マクロ (quote/unquote・`.head`/`.args`・`Expr` 構築・`Symbol`↔`String`)
- クロージャ・タプル + 多値返し (`VTuple`)・broadcast **dot-call** `f.(x)`
- ECS 芯 (`bin/ecs.ml`)・render/input/loop (`bin/gpuBridge.ml`)・
  物理 (`bin/physicsBridge.ml`)・音 (`bin/audioBridge.ml`)

**Tsubaki に無い(=素の Julia にはある。正直に):**

- `do`ブロック構文 (`f(a) do x … end`)。今は `on_frame(function() … end)` だけ
- broadcast **演算子** `a .+ b` / `.+=`(`f.(x)` の dot-call だけ有る)
- NamedTuple
- 組み込み `Vec2`/`Vec3`/`SVector`/`Point`(構造体で自作は自明。`main.ml` が実演)
- 引数位置のタプルリテラル・`for (a,b) in` 分配・裸の generator 式
- 可変長引数の定義 / 呼び出し位置の splat (`spawn(app, comps...)`)

**そして、ここが芯の緊張** —— SoA 高速パスは **全フィールドが厳密に `::Float`**
のスカラー構造体しか受け付けない (`runtime.ml:995`
`List.for_all (fun ft -> ft = ["Float"]) sd.field_types`)。つまり
`pos::Vec2` を持つ構造体は SoA に乗らず AoS(遅い方)に落ちる。
**値型 `Vec2` の親切さと、~97k体を捌く SoA の速さは、今日は両立しない。**
この一点が、このドキュメント全体がいちばん指し示す、まだ解けていない問題です
(§7)。

---

## 1. 北極星 —— Keel(竜骨)

> 竜骨は、小舟と軍艦が同じ一本の背骨に沿って組まれる、そのひとすじ。
> 15行のシーンと10万体の群れを、同じ原理で立たせる。小舟で覚えたことは、
> 大きい船を作るときに一つも捨てない。

Tsubaki のゲームDXの背骨は **一つの共有 `Transform`**。物理がそこへ書き、
描画がそこを読み、入力がそこを押す。三つの世界は *フィールドの上で* 出会う。
手で数えた `state[17]` の上ではなく。

三つの核:

1. **値が意味を運ぶ。引数リストは意味を持たない。**
   `Vec2`・`Color`(名前で `RED`)・`Circle`/`Rect` は演算子メソッドを持つ値型。
   `p + v*dt` が式そのもの。8個の匿名 float を渡す `draw_rect` は、
   ライブラリの中の *たった一箇所* の秘密に留まる。

2. **メソッドを定義することが、登録すること。**
   `update`/`draw`/`process!` は本物のジェネリック。自分の値にメソッドを
   足すと、それが登録になる。GameZero の「名前で見つける親切さ」を、
   *ディスパッチ* でやる —— だから `uptate` と綴り間違えれば、3フレーム後の
   静かな no-op ではなく、*定義した行* での `MethodError`。

3. **同じ動詞が、上から下まで生き延びる。**
   ゲームが育って変わるのは *状態がどこに住むか* だけ(トップレベルの
   ゆるい actor → 自作の node 構造体 → 詰め込まれた SoA カラム)。
   `update`/`draw`/`spawn!`/`Transform`/`Vec2` は変わらない。
   進級は機械を *足す* のであって、書いたものを *取り消さない*。

親切さは、プリミティブの *上に敷いた便利* であって、それを隠す *第二の
エンジン* ではない。正面の扉は素直な方へ開く —— `update(g, dt)` を埋めれば、
窓もループも時計も GPU も壁も、塗り絵のように既に下描きしてある。型付き
ECS も、反応的な継ぎ目も、生 WGSL も、その下に居て、いつでも手が届く。
壁ではなく。

---

## 2. 5つの痛み → Julia の語彙 (before → after)

各項に **正直な現状** を付ける:
✅ 今日書ける ／ 🟡 今ある部品で組めるが糖衣か制約つき ／ 🔧 言語・ランタイム追加が要る

### A. 型のある書き味 🟡

文字列コンポーネント名を殺す。名前付き引数。丸ごと spawn。その場で動かす。

```julia
# before —— ecs_bounce.jl
for e in query(["Position", "Velocity"])
    p = get_component(e, "Position"); v = get_component(e, "Velocity")
    add_component!(e, Position(p.x + v.dx, p.y + v.dy))   # 動かすのに丸ごと再構築
end

# after
red = spawn!(stage, Ball(pos = Vec2(100, 50), r = 15, vel = Vec2(80, 0)); color = RED)

function process!(p::PlayerBall, dt, scene)
    dir = arrows()                        # 押されてるキーから Vec2、無ければ ZERO
    dir != ZERO && (p.tf.vel = dir * 200.0)   # その場で書く。再構築じゃない
end
# 差分で上書きしたい? もう言語にある部分更新: Ball(red; color = BLUE) が @set
```

使う Julia の語彙: **多重ディスパッチ**(コンポーネントは *型*、文字列でない)・
**キーワード引数 + `@kwdef`**(float の入れ替わり事故を消す)・
**`T(x; f=v)` 部分更新**(既に有る)。`process!` の in-place 書き込みは
mutable struct(=AoS)なら効く。型でコンポーネントを引く本物の型キー化は
`Type{X}` を Tsubaki が既に持っているので Julia準拠として最も深い一手だが、
mutable コンポーネントへの *書き戻し* が絡むので 🔧(§5)。

### B. 3世界の統合 🟡

`state[17]` の手計算オフセットなしで ECS ↔ 物理 ↔ GPU を繋ぐ。

```julia
# before —— bouncing_balls.jl
# 壁4つが先に入る(bodies 1-4 = 16数字)、だから ball1.x は state[17]
state = physics_get_bodies(world)
draw_rect(state[17]-15.0, state[18]-15.0, 30.0, 30.0, 0.9, 0.3, 0.2, 1.0)

# after —— オフセット計算はライブラリの中に一度だけ、handle から導く
#   base = 4*(handle-1); node.tf.pos = Vec2(state[base+1], state[base+2])
# あなたのコードはボディを数えない。背骨を読むだけ:
draw(b::Ball) = draw(Circle(b.tf.pos, b.radius), b.color)
# 壁を足しても spawn 順を変えても、手で index しないから何もずれない
```

使う語彙: オブジェクト identity → 物理 handle の **Dict**(背骨の糊)。
`spawn!` 時に handle をノードに紐付け、`step!` がフラット配列を *一度だけ*
デコードして各 `tf` に書く。これは小さなランタイム追加(§5)。

> ⚠️ Critique が見つけた正直: `physicsBridge.ml` に **ボディ削除関数が一つも
> 無い**。`base = 4*(handle-1)` は「物理配列が決して詰め直されない」ことに
> 黙って依存している。despawn を入れるなら tombstone 方式(ずらさない)で
> この不変条件を守る必要がある(§6)。

### C. 描画/GPU の親切化 🟡

生 WGSL と wgpu 定型を隠す。ただし逃げ道は残す。

```julia
# before —— ecs_gpu_instanced.jl
shader = """ …raw WGSL vs_main / fs_main… """
pos_buf = create_buffer(len*4, "storage-read"); write_buffer(pos_buf, positions)
pipeline = create_render_pipeline(shader, "vs_main", "fs_main",
            ["storage-read","uniform"], "triangle-list", "replace")
draw_frame(pipeline, [pos_buf, params_buf], 6, n)

# after —— 幾何+色がフラット ABI に触れる、ライブラリの中のたった一箇所:
draw(c::Circle, col::Color) =
    draw_rect(c.center.x - c.r, c.center.y - c.r, 2c.r, 2c.r, col.r, col.g, col.b, col.a)
# 作者は「何を描くか」を名前で言うだけ。形を足すのは switch を編集するのでなく
# メソッドを一つ足すこと:
draw(Circle(pos, 15.0), RED)
```

使う語彙: **値型 + 演算子メソッド + 多重ディスパッチ**。ドローアブルの
`Vector` は静かに batched `draw_rects` / instanced 経路に乗る。WGSL は
`shader=` の逃げ道として下に生きる(L4)。

> ⚠️ 正直: 演算子 `p + v*dt` は Tsubaki の `EBinOp` が Dispatch 経由なので
> *機構としては在りそう* だが、`main.ml` の `Vec2` は `+` メソッドを持たず、
> `Vec2(e.pos.x + e.vel.x*dt, …)` と手で再構築している —— つまり今のコードが
> 実演しているのは *回避策の方*。「機構は在る」は正しいが「もう実演済み」
> は嘘。まず `Base.:+(::Vec2,::Vec2)` を足して実証するのが最初の一歩(§8)。

### D. エラー/ツール体験 🔧

教えてくれるエラー。hot-reload。デバッグ可視化。

```julia
# before —— 全部が静かに失敗する
query(["Positon"])       # タイポ → 静かに空の結果、エラー無し
key_down("ArowRight")    # タイポ → 静かに一度も発火しない
get_component(e, "Hp")   # 無い → nothing を返し、2行後で落ちる

# after
@each (tf::Transform, hp::Hp) in world begin … end   # `Hpp` → その行で UndefVarError
key_down(:ArrowRight)                                 # Symbol: タイポ耐性・補完可
get_component(e, Hp)   # 無い → 投げる:「entity は :pos, :vel を持つ — spawn が Hp を忘れた?」
```

使う語彙: define-by-dispatch(タイポが定義位置の `MethodError`)・型キー
コンポーネント(タイポが `UndefVarError`)・`fieldnames` による 0-boilerplate
な `inspect(e)`・Symbol キー入力。

> ⚠️ Critique の指摘(重い): D は *層の中に織り込まれていない*。L0-L4 の
> スケッチにエラーも hot-reload も inspect も出てこない。教えるエラーを
> *最も必要とする* L0 の初学者に、一つも見せていない。→ L0 に「タイポした
> コンポーネント → entity の実フィールドを列挙する `MethodError`」を一つ
> 見せること。そして hot-reload は WasmGC ブラウザ実行では file-watch も
> module reload も無く不確実なので、**約束を借りない**: 「重力を編集して
> 遊び続ける」は今日、`ui_lib` のスライダーで実現できる(§6)。

### E. Julia準拠(A〜D 全部にかかるレンズ) 🟡

どの機構も、外来のエンジン DSL ではなく本物の Julia イディオム。

```julia
on(scene.collisions) do hits; hits > 0 && play_tone(220, 0.05); end  # Observables.jl そのもの
draw(b::Ball) = draw(Circle(b.tf.pos, b.radius), b.color)            # 多重ディスパッチ
Stage(g; gravity = Vec2(0, 250))   # Tsubaki に既にある部分更新コンストラクタ = @set
```

露わになるギャップ(`do`ブロック・broadcast 演算子・`obs[]` 糖衣)は、
*ちょうど Tsubaki がまだ育てていない Julia の機能* であって、発明ではない。
これが「Julia準拠」の意味 —— 足りないものが「Julia にあって Tsubaki にまだ
無いもの」と一致する限り、道は素直。

---

## 3. 段階的開示 —— 一本の背骨の5層

同じ `update`/`draw`/`spawn!`/`Transform`/`Vec2` が、子供の12行から
パワーユーザーの本気 ECS まで、**書き直しなしで** 貫く。

### L0 —— 塗り絵: `update(g, dt)` を埋める
初めての人・子供。型の木も schedule も反応グラフも無しに、読める15行で動く絵。

```julia
using Keel
stage = Stage(gravity = Vec2(0, 400), edges = walls(SCREEN, bounce = 0.6))
red  = spawn!(stage, Ball(pos = Vec2(100, 50), r = 15, vel = Vec2(80, 0)); color = RED)
blue = spawn!(stage, Ball(pos = Vec2(300,100), r = 20, vel = Vec2(-60,40)); color = BLUE)

function update(g::Stage, dt)          # 定義することが登録すること
    step!(g, dt)                        # 物理 + 壁の反射; 全 tf が同期済み
    d = arrows(); d != ZERO && (red.tf.vel = d * 200)   # その場で押す、再構築なし
    collided(g) && beep(220, 0.05)
end
# draw 不要: 既定の draw(::Stage) が各 actor を自分の tf で batched 描画
play("Bouncing balls", size = (480, 320))
```

### L1 —— ノード: モノに振る舞いを教える
小さな実ゲーム(player, enemy, wall)。振る舞いをデータの隣に。

```julia
abstract type Node end
abstract type Ball <: Node end
process!(::Node, dt, scene) = nothing            # no-op 既定: 要る動詞だけ書く

@node mutable struct PlayerBall <: Ball
    tf::Transform; radius::Float64; color::Color; speed::Float64 = 200.0
end
draw(b::Ball) = draw(Circle(b.tf.pos, b.radius), b.color)   # 両 Ball 種が継承

function process!(p::PlayerBall, dt, scene)      # player *だけ* が入力を聴く
    d = arrows(); d != ZERO && set_velocity!(scene, p, d * p.speed)
end
spawn!(scene, PlayerBall(tf = Transform(100, 50; vel = Vec2(80,0)), radius = 15, color = RED))
```

### L2 —— 継ぎ目: イベントに反応する(神経系)
score・collision・camera・UI。イベントや shared 状態を、粗く・宣言的に。

```julia
score  = Observable(0)
on(scene.collisions) do hits             # 毎フレーム poll でなく、信号
    hits > 0 && (score[] += hits; play_tone(220, 0.05))
end
on(keys.arrows) do dir                    # press / hold / release が別々の瞬間
    set_velocity!(scene, player, dir * 200)
end
draw!(hud) do                             # retained: score が変わった時だけ再描画
    label(10, 10, "SCORE $(score[])")
end
```

### L3 —— 型付きカラム上のシステム(群れ / ECS)
数千〜10万体のホットパス。SoA と一度きりの FFI 越え。でも L0 と同じ `Transform`/`Vec2`/`spawn!`。

```julia
struct Velocity; dx::Float64; dy::Float64; end   # immutable ⇒ 列指向(SoA)、速い

function move!(world, dt)
    @each (tf::Transform, v::Velocity) in world begin   # archetype を *型* で名指す
        tf.x += v.dx * dt; tf.y += v.dy * dt
    end
end
add_systems!(world, :update, move!, bounce!)     # system はスケジュール内のただの関数
run!(world, 1/60)
```

> ⚠️ 正直: このL3スケッチは §7 の未解決に直接ぶつかる。上では `Velocity` の
> フィールドを `dx::Float64, dy::Float64`(全 `::Float`)にして SoA 適格に
> してある —— `v::Vec2` にした瞬間 SoA を外れるから。そして `tf.x += …` が
> その場で効くのは `tf` が mutable(AoS)のときだけ。**「速い」と
> 「その場で mutable」は今日、同居できない**(§7)。L0-L2 の親切さは
> `Vec2` を使い、L3 の速さは平たい `::Float` カラムを使う —— この段差を
> どう埋めるかが、この設計最大の宿題。

### L4 —— 生の金属: WGSL・buffer・フラット配列
カスタムシェーダ・カスタム instancing。いつでも届く逃げ道、決して必須でない。

```julia
positions = soa_flatten("Velocity", ["dx", "dy"])   # ECS が既に持つカラム、コピー無し
buf  = create_buffer(length(positions) * 4, "storage-read"); write_buffer(buf, positions)
pipe = create_render_pipeline(my_wgsl, "vs_main", "fs_main",
                              ["storage-read", "uniform"], "triangle-list", "replace")
begin_frame(0.05, 0.05, 0.08, 1.0); draw_frame(pipe, [buf, params_buf], 6, n); end_frame()
# physics_get_bodies(world) もここに在る、本当に自分でフラット配列を index したいなら
```

> ⚠️ 正直: `soa_flatten("Transform", ["pos.x", "pos.y"])` は **今日投げる**。
> `soa_flatten` は実フィールド名しか解決しない(`ecs.ml:208`)し、`Vec2` を
> 持つ `Transform` はそもそも SoA 適格でない。ネストしたフィールド名を
> 分解できるよう `soa_flatten` を拡張するのが §6 の直し。

---

## 4. 正直な台帳 —— この設計が今どれだけ本物か

| 提案 | 現状 | 根拠 / 注 |
|---|---|---|
| キーワード引数で spawn (`Ball(pos=…, vel=…)`) | ✅ | parser が両サイドで kwargs |
| `T(x; f=v)` 差分更新 = `@set` | ✅ | `eval.ml:482`、任意 struct |
| define-by-dispatch(`update`/`draw`/`process!`) | ✅ | 多重ディスパッチが既にある |
| 値型 `Vec2` + 演算子(`p + v*dt`) | 🟡 | `EBinOp` は Dispatch 経由=機構は在る。だが未実演(`main.ml` は手で再構築)。`Base.:+(::Vec2,…)` を足して実証 |
| immutable=SoA / mutable=AoS の正直な意味 | ✅ | 前回の mutable 正直化で確立 |
| in-place `p.tf.vel = …`(mutable) | ✅ | AoS なら書き戻る |
| `on_frame` が `dt` を渡す | 🔧 | 今は 0 引数。小さなブリッジ変更 |
| `do`ブロック | 🔧 | 無い。今は `function() … end` |
| 型キーコンポーネント `get_component(e, Hp)` | 🔧 | 今は文字列。`Type{X}` は在るが書き戻しが絡む |
| identity → 物理 handle の Dict(3世界の糊) | 🔧 | 小さなランタイム primitive |
| Symbol キー入力 `key_down(:Right)` | 🟡 | 文字列ブリッジの薄い上乗せ |
| Observable / `on` の粗い核 | 🔧 | クロージャで組めるが `obs[]` は index 上書きが要る |
| `@each` の in-place mutable 書き戻し | 🔧 | SoA は copy を返す(`ecs.ml`)。mutable は AoS 強制 |
| `Vec2` フィールド + SoA 速度 の両立 | 🔧 大 | **不可(今日)**。`runtime.ml:995` が全 `::Float` を要求(§7) |
| `soa_flatten("T", ["pos.x"])` | 🔧 | 今日投げる。ネスト名分解の拡張が要る |
| despawn(ボディ削除・id 再利用) | 🔧 | 物理に削除関数が無い・カラムは増える一方(§6) |
| フレームレート非依存 | 🔧 | `dt` を渡すだけでは不十分。固定タイムステップ蓄積が要る |
| ブラウザ hot-reload | 🔧 大 | WasmGC に file-watch/module reload 無し。関数本体の再定義止まりが正直 |

---

## 5. 要る言語追加(順位つき)

「今あるもので組めるか」を先に問い、足すのは最後。小さくて効くものから:

1. **`do`ブロック構文** (小・最優先) —— `f(a) do x … end` を末尾クロージャに
   desugar。全層が使う。これが無いと5つのスケッチの一番きれいな行が一番
   非現実(正直に `function()…end` に劣化)。*読み* を一気に本物にする。
2. **`on_frame` が `dt` を渡す** (小) —— `update(g, dt)` は正面扉の署名。
   `gpuBridge.ml` の小変更で、フレームレート非依存の土台。
3. **Base 演算子への値型メソッド** (小) —— `Base.:+(::Vec2,::Vec2)` 等。
   `p + v*dt`・`dir * 200`・`dir != ZERO` の全語彙がここに乗る。§8 の実証点。
4. **`@kwdef` 相当**(既定値つきキーワード構築、`<: Supertype` 保持) (中) ——
   `Ball(pos=, r=, vel=)`。Tsubaki は kwargs も本物のマクロ introspection も
   持つので、コア変更でなくマクロで組める。足元: 可変既定の毎回評価。
5. **Symbol キー入力アダプタ** (小) —— `key_down(:Right)`。文字列ブリッジの
   薄い層。タイポを捕まえ補完可能に。
6. **identity → handle の Dict** (小) —— 背骨の糊。`step!` がフラット配列を
   一度だけデコードして各 `tf` に書く。`state[17]` を退役させる。
7. **型キーコンポーネント + 型付き `@each` 分配** (中) —— `get_component(e, Transform)`
   が実型値を解決。Pain A/D を正直に果たす、最も深い Julia準拠の一手。
   難所は mutable コンポーネントへの write-through ref。
8. **Observable/`on` の小さな核 + user 型への `getindex/setindex!` 上書き** (中) ——
   粗い継ぎ目(collision/score/camera)。`@lift` を上に。*粗さを保つ*: 継ぎ目
   一つに Observable 一つ、エンティティ毎には決して置かない(Makie 更新嵐の崖)。
9. **可変長定義 + 呼び出し splat** (中) —— `spawn(app, comps...)`。無いと
   固定 arity ヘルパーに劣化。
10. **write-through ref(mutable コンポ・`@each` 下) + broadcast 演算子** (大) ——
    `positions .+= vels .* dt`。immutable-SoA と mutable-AoS の *速い方*。
    Host VM の特殊化と噛み合わせるのが最難。
11. **ブラウザ hot-reload** (大・最不確実) —— Revise 風の部分再評価 + `@once`
    ガード。WasmGC ブラウザの制約は厳しい。v1 は「関数本体+定数の再定義」に
    正直に絞る。

---

## 6. まだ埋まっていない穴(Critique が教えてくれた)

ビジョンが綺麗に言い切ったところを、Critique が実ソースで突き崩した。
折り込んでおく:

- **despawn / オブジェクトプール** が丸ごと無い。全部 `spawn!` だけ。
  `destroy_entity!` は在る(`ecs.ml:242`)が id は再利用されず、カラムは増える
  一方。物理は削除関数ゼロ。弾/敵/パーティクルの churn が配列を無限リーク
  し、物理ボディを永遠に孤児化する。→ `despawn!` + `physics_remove_body` +
  id free-list + handle→slot remap(tombstone 方式)。
- **タイマー/コルーチン/tween** が無い。「2秒後に次の波」「0.5秒でカメラを
  ease」。`bin/async.ml` が既に在るのに未使用。→ `after(dt,f)`・`every(dt,f)`・
  `tween(obj, field, to, dur, ease)`。
- **アセット/テクスチャ** が無い。`draw_rect`/`draw_text` だけ。スケッチの
  `Sprite`/`sprite_rects` は画像を含意するがパイプラインが無い。→ テクスチャ
  経路を足すか、`Sprite` を名乗るのをやめて `Rect` にするか、はっきりさせる。
- **描画順 / z レイヤー** が無い。描画順=spawn 順。HUD が下に潜る。→
  `draw(shape, color; z=0)` を FFI 越え前にソート。
- **固定タイムステップ** が無い。可変ブラウザ dt で `physics_step` は非決定的。
  → `play!`/`step!` 内に蓄積器(実 dt を貯めて 1/120 固定で刻む)+ `pause()`。
- **deferred command buffer** が無い(Bevy Commands)。今の after ループは
  反復中に ECS を書き換えている。→ `spawn!`/`despawn!` を queue して frame 末に flush。

使われていない Julia イディオムで、ここに効くもの:

- **StructArrays.jl 風の行ビュー**(`getproperty`/`setproperty!` を per-field 配列に
  転送)。これが §7 の「列に化けたノード」問題の *Julia ネイティブの答え*。
- **StaticArrays `SVector`/`FieldVector`**。`pos::Vec2` を2つの Float カラムに
  分解させ、`Vec2` と SoA を排他でなくする、まさに欠けている部品。
- **`@enum`**(入力キー・ゲーム状態 Menu/Playing/Paused・衝突レイヤー)。
  タイポ耐性・補完可能。
- **`getproperty`/`setproperty!` 上書き**。`state[17]` を `body.x` に変え、
  かつ write-through 列ビューを可能にする、より load-bearing な方。

---

## 7. 中心にある一つの未解決 —— SoA-fast ↔ AoS-writable の継ぎ目

これがこの設計が最も指し示す、まだ解けていない問題。正直に一段に。

共有 `Transform` は **mutable** でありたい(物理が書き、描画がその場で読む)
⇒ AoS。しかし AoS は ~97k体を捌く immutable-SoA 列の速さと戦う。そして
SoA の `get_component` は毎回 *新しいコピー* を返す(`ecs.ml`)から、SoA 上の
フィールド書き戻しは効かない。**速い ＋ その場で mutable は、今日、同居
できない。** `runtime.ml:995` の「全フィールド厳密 `::Float`」制約が、
`Vec2` の親切さ(Pain A/C を治す当のもの)を、SoA 群れ経路(速さをくれる
当のもの)から締め出している。

Julia ネイティブの答えは **StructArrays + StaticArrays**: `pos::Vec2` を
`pos.x`/`pos.y` の2列に分解して裏で SoA に格納し、`tf.pos` アクセスには
列に write-through する行ビュー構造体を被せる。`tf.pos.x = …` が新しい
コピーでなく生きた列を書く。これは「StaticArrays+StructArrays を Tsubaki で
綴る」こと —— `soa_eligible`/`make_soa_column` を「全 Float の struct 型
フィールドを分解する」よう拡張し(`Vec2`→2列、`Color`→4列)、`soa_flatten` が
`"pos.x"` を解決できるようにする。

これが解ければ、原則「ECS が既に持つ列が、batched 描画が欲しい列と同じ」が
本物になり、親切さと速さが *競う* のでなく *一致* する。解けるまでは正直に:
L3 のコンポーネントは平たい `x::Float, y::Float` にし、境界で `Vec2` を
再構成し、「全層で同じ Vec2」の看板は下ろしておく。

もう一つの正直: 型キー化と Host VM。今の `@each` は型名を文字列化する
(`each_kinds(Position, Velocity)` → `"Position"`)ので、(a) タイポが捕まらず
(b) `@each` が Host VM/SoA 特殊化に乗らない(前回メモの壁)。本物の型キー化が
コンパイラの特殊化を *助ける* のか *妨げる* のか —— タイポ安全の物語と速さの
物語が、同じつまみを逆に引く可能性がある。

---

## 8. もし進めるなら —— 最初の一手(実装は後、でも足場だけ)

実装計画は今回のスコープ外。でも「拾い上げるなら、いちばん小さくて *手触りを
実証する* 一歩」だけ置いておく。

**フィール実証 MVP(SoA を一切触らない)** ——
`do`ブロック + `on_frame` に `dt` + `Base.:+(::Vec2,…)` 等の演算子 +
`spawn!`/`draw` の mutable `Transform` 上のディスパッチ + identity→handle の
Dict。これだけで L0 の塗り絵 bouncing_balls が *今日に近い形で* 動く ——
速さの話(SoA)には一切踏み込まずに、親切さの手触りだけを先に確かめられる。
`main.ml` が今実演しているのは回避策の方なので、まず `Vec2` に演算子を
足して「機構は在る」を「実演した」に変えるのが、いちばん正直な出発点。

その次に **型キーの背骨**(Pain A/D を本物に)、そして最後に §7 の
**SoA 行ビュー**(速さと親切さを一致させる)。この順なら、各段が独立に
気持ちよく、書いたものを後で取り消さずに済む。

---

## この文書について

ゲームエンジン8系統 + Julia ライブラリ群を並列調査し、痛み→イディオムの
対応を作り、理想DXを4方向から描いて採点・統合し、実ソースで正直さを検証
した素材から、Shiro (Claude Opus 4.8) が nyanrus と下書きしたものです。

思想を先に描くのが目的なので、実装の段取りより *どうあれば気持ちいいか* に
重心を置いています。台帳の ✅/🟡/🔧 は実際にソースを見て確かめましたが、
見落としや misreading があれば教えてください —— そこが、いちばん新しく
見えるところなので。
