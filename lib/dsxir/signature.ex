defmodule Dsxir.Signature do
  @moduledoc """
  Declarative signature module. Wraps `Spark.Dsl` so authors write:

      defmodule MyApp.AnswerQuestion do
        use Dsxir.Signature

        signature do
          instruction "Answer the user's question."
          input :question, :string
          output :answer, :string, desc: "A direct factual answer."
        end
      end
  """

  use Spark.Dsl, default_extensions: [extensions: [Dsxir.Signature.Dsl]]
end
