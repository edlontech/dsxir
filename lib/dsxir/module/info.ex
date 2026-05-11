defmodule Dsxir.Module.Info do
  @moduledoc false
  use Spark.InfoGenerator, extension: Dsxir.Module.Dsl, sections: [:module]
end
