[
  # NimbleParsec generates internal helper clauses for combinators that
  # always raise (via a post_traverse returning `{:error, _}`). Dialyzer
  # flags the never-callable success arm as unused; the runtime path is
  # exercised by tests.
  {"lib/dsxir/predicate/parser.ex", :unused_fun}
]
