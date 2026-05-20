defmodule Dsxir.ProgramContextTest do
  use ExUnit.Case, async: true

  alias Dsxir.ProgramContext
  alias Dsxir.RuntimeProgram
  alias Dsxir.Test.Fixtures.RuntimePrograms

  setup_all do
    Code.ensure_loaded!(Dsxir.Test.Fixtures.AnswerQuestion)
    Code.ensure_loaded!(Dsxir.Predictor.Predict)
    _ = [:qa, :refine, :question, :answer, :required]
    :ok
  end

  test "new/2 wraps a runtime program with defaults from Settings.resolve" do
    rp = RuntimePrograms.minimal_valid()

    Dsxir.context([metadata: %{tenant_id: "t1"}], fn ->
      ctx = ProgramContext.new(rp)

      assert %ProgramContext{
               runtime_program: ^rp,
               metadata: %{tenant_id: "t1"},
               caller: nil
             } = ctx
    end)
  end

  test "new/2 accepts explicit :metadata and :caller opts" do
    rp = RuntimePrograms.minimal_valid()
    caller = self()

    ctx =
      ProgramContext.new(rp,
        metadata: %{request_id: "r-1"},
        caller: caller
      )

    assert %ProgramContext{
             runtime_program: %RuntimeProgram{} = wrapped,
             metadata: %{request_id: "r-1"},
             caller: ^caller
           } = ctx

    assert wrapped == rp
  end

  test "new/2 defaults metadata to %{} when settings carry nothing" do
    rp = RuntimePrograms.minimal_valid()
    ctx = ProgramContext.new(rp)
    assert ctx.metadata == %{}
    assert ctx.caller == nil
  end
end
