[
  import_deps: [:spark],
  plugins: [Recode.FormatterPlugin],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
