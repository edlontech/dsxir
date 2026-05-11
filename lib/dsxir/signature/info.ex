defmodule Dsxir.Signature.Info do
  @moduledoc false
  use Spark.InfoGenerator, extension: Dsxir.Signature.Dsl, sections: [:signature]
end
