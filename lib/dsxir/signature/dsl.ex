defmodule Dsxir.Signature.Dsl do
  @moduledoc false

  @input %Spark.Dsl.Entity{
    name: :input,
    target: Dsxir.Signature.Field,
    args: [:name, :type],
    schema: [
      name: [type: :atom, required: true, doc: "Field name."],
      type: [type: :any, required: true, doc: "Shorthand atom or Zoi schema."],
      desc: [type: :string, doc: "Optional field description rendered in prompts."]
    ],
    auto_set_fields: [kind: :input]
  }

  @output %Spark.Dsl.Entity{
    name: :output,
    target: Dsxir.Signature.Field,
    args: [:name, :type],
    schema: [
      name: [type: :atom, required: true, doc: "Field name."],
      type: [type: :any, required: true, doc: "Shorthand atom or Zoi schema."],
      desc: [type: :string, doc: "Optional field description rendered in prompts."]
    ],
    auto_set_fields: [kind: :output]
  }

  @signature %Spark.Dsl.Section{
    name: :signature,
    entities: [@input, @output],
    schema: [
      instruction: [type: :string, doc: "Top-level instruction rendered in the system prompt."],
      description: [type: :string, doc: "Optional human-readable description."]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@signature],
    transformers: [Dsxir.Signature.Transformer]
end
