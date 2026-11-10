spark_locals_without_parens = [
  currency: 1,
  field: 2,
  field: 3,
  key: 1,
  label: 1,
  path: 1,
  required?: 1,
  resource: 1,
  table: 1,
  table: 2,
  version: 1
]

[
  import_deps: [:ash, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
