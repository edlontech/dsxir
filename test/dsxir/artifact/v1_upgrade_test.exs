defmodule Dsxir.Artifact.V1UpgradeTest do
  use ExUnit.Case, async: true

  alias Dsxir.Artifact
  alias Dsxir.Program

  defmodule Sig do
    @moduledoc false
    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:a, :string)
    end
  end

  defmodule Prog do
    @moduledoc false
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: Sig)

    def forward(p, inputs), do: call(p, :answer, inputs)
  end

  @fixture "test/support/fixtures/artifacts/v1_static_program.json"

  test "v1 hand-written fixture loads through legacy load/3 with module source" do
    {:ok, prog} = Artifact.load(Prog, @fixture)

    assert %Program{source: %Dsxir.Program.Source.Module{module: Prog}} = prog
    state = Program.get_state(prog, :answer)
    assert length(state.demos) == 2
    assert state.instructions_override == "Answer briefly."
  end

  test "v1 hand-written fixture loads through decode_and_hydrate/1 with inferred module source" do
    raw = File.read!(@fixture)
    prog = Artifact.decode_and_hydrate(raw, target_module: Prog)

    assert %Program{source: %Dsxir.Program.Source.Module{module: Prog}} = prog
    state = Program.get_state(prog, :answer)
    assert length(state.demos) == 2

    Enum.each(state.demos, fn demo ->
      assert %Dsxir.Demo{kind: :labeled, example: %Dsxir.Example{}} = demo
    end)
  end
end
