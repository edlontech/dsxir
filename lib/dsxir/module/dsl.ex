defmodule Dsxir.Module.Dsl do
  @moduledoc false

  @predictor %Spark.Dsl.Entity{
    name: :predictor,
    target: Dsxir.Module.PredictorDecl,
    args: [:name, :impl],
    schema: [
      name: [type: :atom, required: true, doc: "Predictor name used by call/3."],
      impl: [type: :atom, required: true, doc: "Predictor implementation module."],
      signature: [
        type: {:or, [:atom, :string]},
        required: true,
        doc: "Signature module or inline string signature like \"question -> answer\"."
      ]
    ]
  }

  @module_section %Spark.Dsl.Section{
    name: :module,
    entities: [@predictor],
    top_level?: true
  }

  use Spark.Dsl.Extension,
    sections: [@module_section],
    transformers: [Dsxir.Module.Transformer]
end
