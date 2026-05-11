spark_locals_without_parens = [
  predictor: 3,
  input: 2,
  output: 2,
  output: 3,
  instruction: 1
]

[
  import_deps: [:spark],
  plugins: [Recode.FormatterPlugin],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
