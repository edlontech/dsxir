defmodule Dsxir.Test.Fixtures.AnswerQuestion do
  @moduledoc false
  use Dsxir.Signature

  signature do
    instruction("Answer the user's question with a single short fact.")
    input(:question, :string)
    output(:answer, :string, desc: "A direct factual answer.")
  end
end

defmodule Dsxir.Test.Fixtures.RankItems do
  @moduledoc false
  use Dsxir.Signature

  signature do
    instruction("Rank the supplied items by relevance to the query.")
    input(:query, :string)
    input(:items, {:list, :string})
    output(:ranked, {:list, :string})
    output(:confidence, :float)
  end
end
