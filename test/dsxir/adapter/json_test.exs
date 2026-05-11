defmodule Dsxir.Adapter.JsonTest do
  use ExUnit.Case, async: true

  alias Dsxir.Adapter.Json
  alias Dsxir.Telemetry
  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.Fixtures.RankItems

  describe "lm_mode/0" do
    test "returns :object" do
      assert Json.lm_mode() == :object
    end
  end

  describe "output_schema/1" do
    test "builds a Zoi.object from the signature outputs" do
      schema = Json.output_schema(AnswerQuestion)

      assert {:ok, %{answer: "hi"}} = Zoi.parse(schema, %{answer: "hi"})
    end

    test "validates typed fields" do
      schema = Json.output_schema(RankItems)

      assert {:ok, %{ranked: ["a"], confidence: 0.5}} =
               Zoi.parse(schema, %{ranked: ["a"], confidence: 0.5})

      assert {:error, _} = Zoi.parse(schema, %{ranked: "not-a-list", confidence: 0.5})
    end
  end

  describe "format/4" do
    test "renders system + user messages similar to Chat" do
      [system, user] = Json.format(AnswerQuestion, %{question: "What is Elixir?"}, [], [])

      assert system.role == :system
      assert system.content =~ "Answer the user's question"

      assert user.role == :user
      assert user.content =~ "What is Elixir?"
    end

    test "raises Invalid.Configuration when :stream is in opts" do
      err =
        assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
          Json.format(AnswerQuestion, %{question: "x"}, [], stream: true)
        end

      assert err.key == :stream
      assert err.value == true
      assert err.reason == :streaming_unsupported_for_json_adapter
    end

    test "emits [:dsxir, :adapter, :format] with adapter: Dsxir.Adapter.Json metadata" do
      parent = self()
      ref = make_ref()
      handler_id = {__MODULE__, ref}

      :ok =
        :telemetry.attach(
          handler_id,
          Telemetry.adapter_format(),
          fn _event, meas, meta, _ -> send(parent, {ref, meas, meta}) end,
          nil
        )

      try do
        Json.format(AnswerQuestion, %{question: "x"}, [], [])

        assert_receive {^ref, %{duration: duration},
                        %{
                          adapter: Dsxir.Adapter.Json,
                          signature: AnswerQuestion,
                          outcome: :ok
                        }},
                       200

        assert is_integer(duration) and duration >= 0
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "parse/3" do
    test "validates a valid object against the output schema" do
      assert {:ok, %{answer: "Elixir"}} =
               Json.parse(AnswerQuestion, %{answer: "Elixir"}, [])
    end

    test "validates typed fields" do
      assert {:ok, %{ranked: ["a", "b"], confidence: 0.9}} =
               Json.parse(RankItems, %{ranked: ["a", "b"], confidence: 0.9}, [])
    end

    test "returns ZoiValidation on schema mismatch" do
      assert {:error,
              %Dsxir.Errors.Adapter.ZoiValidation{
                adapter: Dsxir.Adapter.Json,
                field: nil,
                path: []
              }} = Json.parse(RankItems, %{ranked: "not-a-list", confidence: 0.5}, [])
    end

    test "emits [:dsxir, :adapter, :parse] telemetry with adapter metadata" do
      parent = self()
      ref = make_ref()
      handler_id = {__MODULE__, ref}

      :ok =
        :telemetry.attach(
          handler_id,
          Telemetry.adapter_parse(),
          fn _event, meas, meta, _ -> send(parent, {ref, meas, meta}) end,
          nil
        )

      try do
        assert {:ok, _} = Json.parse(AnswerQuestion, %{answer: "ok"}, [])

        assert_receive {^ref, %{duration: duration},
                        %{
                          adapter: Dsxir.Adapter.Json,
                          signature: AnswerQuestion,
                          outcome: :ok
                        }},
                       200

        assert is_integer(duration) and duration >= 0
      after
        :telemetry.detach(handler_id)
      end
    end

    test "parse telemetry emits :error outcome on validation failure" do
      parent = self()
      ref = make_ref()
      handler_id = {__MODULE__, ref}

      :ok =
        :telemetry.attach(
          handler_id,
          Telemetry.adapter_parse(),
          fn _event, meas, meta, _ -> send(parent, {ref, meas, meta}) end,
          nil
        )

      try do
        assert {:error, _} =
                 Json.parse(RankItems, %{ranked: "not-a-list", confidence: 0.5}, [])

        assert_receive {^ref, %{duration: _}, %{outcome: :error}}, 200
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
