(* real Julia performance/codegen hints -- @inline, @inbounds, etc. never
   change behavior in a tree-walking interpreter (only codegen in real
   Julia), so they're treated as pure identity: SMacroCall for one of these
   just runs (or resolves) the wrapped statement directly, no macro-
   expansion machinery involved at all. Shared by Resolve and Eval, hence
   defined out here rather than inside either. *)
let is_inert_hint_macro name =
  List.mem name
    [ "inline"; "noinline"; "inbounds"; "propagate_inbounds"; "simd"; "fastmath"; "boundscheck"
    ; "nospecialize"; "specialize"
    ]
