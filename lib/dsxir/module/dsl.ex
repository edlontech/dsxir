defmodule Dsxir.Module.Dsl do
  @moduledoc false

  @predictor %Spark.Dsl.Entity{
    name: :predictor,
    target: Dsxir.Module.PredictorDecl,
    args: [:name, :impl],
    schema: [
      name: [type: :atom, required: true, doc: "Predictor name used by call/3."],
      impl: [type: :atom, required: true, doc: "Predictor implementation module."],
      signature: [type: :atom, required: true, doc: "Signature module."]
    ]
  }

  @module_section %Spark.Dsl.Section{
    name: :module,
    entities: [@predictor],
    top_level?: true
  }

  use Spark.Dsl.Extension, sections: [@module_section]
end
