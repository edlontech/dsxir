defmodule Dsxir.Predictor.PredictTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Predictor.Predict
  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.TelemetryHandler

  setup :set_mimic_from_context

  setup do
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  test "forward/4 threads state.instructions_override into the chat adapter system prompt" do
    parent = self()

    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, msgs, opts ->
      send(parent, {:captured_messages, msgs})
      send(parent, {:captured_lm_opts, opts})
      {:ok, "[[ ## answer ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      state = %Dsxir.Program.State{instructions_override: "MIPRO-PICKED instruction"}

      {^state, _prediction} =
        Predict.forward(state, AnswerQuestion, %{question: "What is Elixir?"}, [])
    end)

    assert_receive {:captured_messages, [system | _]}
    assert system.role == :system
    assert system.content =~ "MIPRO-PICKED instruction"
    refute system.content =~ "Answer the user's question"

    assert_receive {:captured_lm_opts, lm_opts}
    refute Keyword.has_key?(lm_opts, :instruction_override)
  end

  test "forward/4 returns a %Prediction{} from a stubbed LM" do
    markered = """
    [[ ## answer ## ]]
    A dynamic, functional language.
    """

    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
      {:ok, markered, Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      state = %Dsxir.Program.State{}

      {^state, prediction} =
        Predict.forward(state, AnswerQuestion, %{question: "What is Elixir?"}, [])

      assert %Dsxir.Prediction{} = prediction
      assert prediction[:answer] == "A dynamic, functional language."
    end)
  end

  test "forward/4 emits start/stop telemetry with predictor metadata" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\nx", Dsxir.Cost.zero()}
    end)

    parent = self()
    handler_id = {__MODULE__, :start_stop_handler}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach_many(
      handler_id,
      [
        Dsxir.Telemetry.predictor_start(),
        Dsxir.Telemetry.predictor_stop()
      ],
      &TelemetryHandler.forward/4,
      %{parent: parent, tag: :telemetry}
    )

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
    end)

    assert_receive {:telemetry, [:dsxir, :predictor, :start], _,
                    %{
                      predictor: Dsxir.Predictor.Predict,
                      signature: AnswerQuestion,
                      adapter: Dsxir.Adapter.Chat
                    }}

    assert_receive {:telemetry, [:dsxir, :predictor, :stop], %{duration: _},
                    %{
                      prediction: %Dsxir.Prediction{},
                      error_class: nil,
                      cost: %Dsxir.Cost{},
                      _cost_scope: []
                    }}
  end

  test "forward/4 stop event always carries tokens_in/tokens_out/cost measurements" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\nx",
       %Dsxir.Cost{input_tokens: 12, output_tokens: 34, total_cost: 0.0005, calls: 1}}
    end)

    parent = self()
    handler_id = {__MODULE__, :token_handler}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach(
      handler_id,
      Dsxir.Telemetry.predictor_stop(),
      &TelemetryHandler.forward/4,
      %{parent: parent, tag: :telemetry_stop}
    )

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
    end)

    assert_receive {:telemetry_stop, _,
                    %{duration: _, tokens_in: 12, tokens_out: 34, cost: 0.0005},
                    %{
                      cost: %Dsxir.Cost{input_tokens: 12, output_tokens: 34, total_cost: 0.0005},
                      _cost_scope: []
                    }}
  end

  test "forward/4 stop event carries nil token measurements when LM returns empty usage" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\nx", Dsxir.Cost.zero()}
    end)

    parent = self()
    handler_id = {__MODULE__, :nil_token_handler}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach(
      handler_id,
      Dsxir.Telemetry.predictor_stop(),
      &TelemetryHandler.forward/4,
      %{parent: parent, tag: :telemetry_stop}
    )

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
    end)

    assert_receive {:telemetry_stop, _,
                    %{duration: _, tokens_in: nil, tokens_out: nil, cost: nil} = meas, _}

    assert Map.has_key?(meas, :tokens_in)
    assert Map.has_key?(meas, :tokens_out)
    assert Map.has_key?(meas, :cost)
  end

  test "forward/4 propagates settings.metadata into telemetry" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\ny", Dsxir.LM.empty_usage()}
    end)

    parent = self()
    handler_id = {__MODULE__, :metadata_handler}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach(
      handler_id,
      Dsxir.Telemetry.predictor_stop(),
      &TelemetryHandler.forward/4,
      %{parent: parent, tag: :telemetry}
    )

    Dsxir.Settings.context(
      [
        lm: {Dsxir.LM.Sycophant, [model: "stub"]},
        metadata: %{tenant_id: "t1"}
      ],
      fn ->
        Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "y"}, [])
      end
    )

    assert_receive {:telemetry, _, _, %{tenant_id: "t1"}}
  end

  test "forward/4 raises Adapter.ParseError when Chat parse fails and Json fallback also fails" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "no markers here", Dsxir.LM.empty_usage()}
    end)

    stub(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      {:ok, %{wrong_key: "x"}, Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert_raise Dsxir.Errors.Adapter.FallbackExhausted, fn ->
        Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
      end
    end)
  end

  test "forward/4 emits exception telemetry on parse error" do
    stub(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      {:ok, %{wrong_key: "x"}, Dsxir.LM.empty_usage()}
    end)

    parent = self()
    handler_id = {__MODULE__, :exception_handler}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach(
      handler_id,
      Dsxir.Telemetry.predictor_exception(),
      &TelemetryHandler.forward/4,
      %{parent: parent, tag: :telemetry}
    )

    Dsxir.Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: "stub"]}, adapter: Dsxir.Adapter.Json],
      fn ->
        assert_raise Dsxir.Errors.Adapter.FallbackExhausted, fn ->
          Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
        end
      end
    )

    assert_receive {:telemetry, _, _, %{error_class: :adapter, kind: :error}}
  end

  test "forward/4 raises LM.Authentication when transport fails" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:error, %Dsxir.Errors.LM.Authentication{model_id: "stub", reason: :nope}}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert_raise Dsxir.Errors.LM.Authentication, fn ->
        Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
      end
    end)
  end

  test "forward/4 stamps parent path onto FallbackExhausted raised from Json adapter retry" do
    stub(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      {:ok, %{wrong_key: "x"}, Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: "stub"]}, adapter: Dsxir.Adapter.Json],
      fn ->
        err =
          try do
            Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"},
              path: [:run, :extract]
            )

            flunk("expected FallbackExhausted")
          rescue
            e in Dsxir.Errors.Adapter.FallbackExhausted -> e
          end

        assert %Dsxir.Errors.Adapter.FallbackExhausted{
                 from: Dsxir.Adapter.Json,
                 to: Dsxir.Adapter.Json,
                 path: [:run, :extract],
                 last_error: %Dsxir.Errors.Adapter.ZoiValidation{}
               } = err
      end
    )
  end

  test "forward/4 drives the Json adapter end-to-end via generate_object" do
    expect(Dsxir.LM.Sycophant, :generate_object, fn _config, _msgs, _schema, _opts ->
      {:ok, %{answer: "42"}, Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context(
      [
        lm: {Dsxir.LM.Sycophant, [model: "stub"]},
        adapter: Dsxir.Adapter.Json
      ],
      fn ->
        state = %Dsxir.Program.State{}

        {^state, prediction} =
          Predict.forward(state, AnswerQuestion, %{question: "What is the answer?"}, [])

        assert %Dsxir.Prediction{} = prediction
        assert prediction[:answer] == "42"
      end
    )
  end

  test "forward/4 stamps parent path with leaf field on per-field ParseError when Json fallback also fails" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## ranked ## ]]\n[\"a\"]", Dsxir.LM.empty_usage()}
    end)

    expect(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      {:error, %Dsxir.Errors.LM.ContextWindow{model_id: "stub"}}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      err =
        try do
          Predict.forward(
            %Dsxir.Program.State{},
            Dsxir.Test.Fixtures.RankItems,
            %{query: "x", items: ["a"]},
            path: [:run, :extract]
          )

          flunk("expected FallbackExhausted")
        rescue
          e in Dsxir.Errors.Adapter.FallbackExhausted -> e
        end

      assert %Dsxir.Errors.Adapter.FallbackExhausted{
               from: Dsxir.Adapter.Chat,
               to: Dsxir.Adapter.Json,
               path: [:run, :extract],
               last_error: %Dsxir.Errors.LM.ContextWindow{}
             } = err
    end)
  end

  describe "Chat to Json one-shot fallback" do
    test "falls back to Json adapter on Chat ParseError and returns prediction" do
      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
        {:ok, "no markers", Dsxir.LM.empty_usage()}
      end)

      expect(Dsxir.LM.Sycophant, :generate_object, fn _config, _msgs, _schema, _opts ->
        {:ok, %{answer: "42"}, Dsxir.LM.empty_usage()}
      end)

      parent = self()
      handler_id = {__MODULE__, :fallback_happy_handler}
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        Dsxir.Telemetry.adapter_fallback(),
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :fallback}
      )

      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        state = %Dsxir.Program.State{}

        {^state, prediction} =
          Predict.forward(state, AnswerQuestion, %{question: "What is the answer?"}, [])

        assert %Dsxir.Prediction{} = prediction
        assert prediction[:answer] == "42"
      end)

      assert_receive {:fallback, _, _,
                      %{
                        from: Dsxir.Adapter.Chat,
                        to: Dsxir.Adapter.Json,
                        reason: %Dsxir.Errors.Adapter.ParseError{}
                      }}
    end

    test "raises FallbackExhausted when Json adapter also fails" do
      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
        {:ok, "no markers", Dsxir.LM.empty_usage()}
      end)

      expect(Dsxir.LM.Sycophant, :generate_object, fn _config, _msgs, _schema, _opts ->
        {:error,
         %Dsxir.Errors.LM.ContextWindow{
           model_id: "stub",
           prompt_tokens: 9000,
           limit: 8192
         }}
      end)

      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        err =
          try do
            Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
            flunk("expected FallbackExhausted")
          rescue
            e in Dsxir.Errors.Adapter.FallbackExhausted -> e
          end

        assert %Dsxir.Errors.Adapter.FallbackExhausted{
                 from: Dsxir.Adapter.Chat,
                 to: Dsxir.Adapter.Json,
                 last_error: %Dsxir.Errors.LM.ContextWindow{}
               } = err
      end)
    end

    test "LM.ContextWindow on Chat triggers fallback and returns prediction" do
      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
        {:error,
         %Dsxir.Errors.LM.ContextWindow{
           model_id: "stub",
           prompt_tokens: 9000,
           limit: 8192
         }}
      end)

      expect(Dsxir.LM.Sycophant, :generate_object, fn _config, _msgs, _schema, _opts ->
        {:ok, %{answer: "ok"}, Dsxir.LM.empty_usage()}
      end)

      parent = self()
      handler_id = {__MODULE__, :fallback_context_window_handler}
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        Dsxir.Telemetry.adapter_fallback(),
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :fallback}
      )

      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        {%Dsxir.Program.State{}, prediction} =
          Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])

        assert prediction[:answer] == "ok"
      end)

      assert_receive {:fallback, _, _,
                      %{
                        from: Dsxir.Adapter.Chat,
                        to: Dsxir.Adapter.Json,
                        reason: %Dsxir.Errors.LM.ContextWindow{}
                      }}
    end

    test "Authentication error on Chat propagates without firing fallback" do
      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
        {:error, %Dsxir.Errors.LM.Authentication{model_id: "stub", reason: :nope}}
      end)

      parent = self()
      handler_id = {__MODULE__, :fallback_auth_handler}
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        Dsxir.Telemetry.adapter_fallback(),
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :fallback}
      )

      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        assert_raise Dsxir.Errors.LM.Authentication, fn ->
          Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
        end
      end)

      refute_receive {:fallback, _, _, _}, 50
    end

    test "Json primary failure does not trigger a Chat->Json fallback" do
      stub(Dsxir.LM.Sycophant, :generate_object, fn _config, _msgs, _schema, _opts ->
        {:ok, %{wrong_key: "not an answer"}, Dsxir.LM.empty_usage()}
      end)

      parent = self()
      handler_id = {__MODULE__, :fallback_json_primary_handler}
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        Dsxir.Telemetry.adapter_fallback(),
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :fallback}
      )

      Dsxir.Settings.context(
        [
          lm: {Dsxir.LM.Sycophant, [model: "stub"]},
          adapter: Dsxir.Adapter.Json
        ],
        fn ->
          err =
            try do
              Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
              flunk("expected FallbackExhausted")
            rescue
              e in Dsxir.Errors.Adapter.FallbackExhausted -> e
            end

          assert %Dsxir.Errors.Adapter.FallbackExhausted{
                   from: Dsxir.Adapter.Json,
                   to: Dsxir.Adapter.Json,
                   last_error: %Dsxir.Errors.Adapter.ZoiValidation{}
                 } = err
        end
      )

      refute_receive {:fallback, _, _, %{from: Dsxir.Adapter.Chat, to: Dsxir.Adapter.Json}}, 50
      assert_receive {:fallback, _, _, %{from: Dsxir.Adapter.Json, to: Dsxir.Adapter.Json}}
    end
  end

  describe "streaming" do
    test "forward/4 translates LM stream chunks into Dsxir.Stream.Event and returns final prediction" do
      parent = self()
      ref = make_ref()

      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, opts ->
        sink = Keyword.fetch!(opts, :stream)
        sink.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "[[ ## "})
        sink.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "answer ## ]]\n"})
        sink.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "42"})
        sink.(%Dsxir.LM.StreamChunk{type: :usage, data: Dsxir.Cost.zero()})
        sink.(%Dsxir.LM.StreamChunk{type: :done, data: nil})
        {:ok, "[[ ## answer ## ]]\n42", Dsxir.LM.empty_usage()}
      end)

      stream = fn %Dsxir.Stream.Event{} = event -> send(parent, {ref, event.type, event.data}) end

      Dsxir.Settings.context(
        [lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]}],
        fn ->
          {%Dsxir.Program.State{}, prediction} =
            Predict.forward(
              %Dsxir.Program.State{},
              AnswerQuestion,
              %{question: "?"},
              stream: stream
            )

          assert prediction[:answer] == "42"
        end
      )

      assert_receive {^ref, :token, "[[ ## "}
      assert_receive {^ref, :token, "answer ## ]]\n"}
      assert_receive {^ref, :token, "42"}
      assert_receive {^ref, :usage, %Dsxir.Cost{}}
      assert_receive {^ref, :done, nil}
    end

    test "forward/4 with listen: emits :field_delta events for the listened field" do
      parent = self()
      ref = make_ref()

      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, opts ->
        {acc, fun} = Keyword.fetch!(opts, :stream)
        acc = fun.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "[[ ## answer ## ]]\n4"}, acc)
        acc = fun.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "2"}, acc)
        _acc = fun.(%Dsxir.LM.StreamChunk{type: :done, data: nil}, acc)
        {:ok, "[[ ## answer ## ]]\n42", Dsxir.LM.empty_usage()}
      end)

      stream = fn %Dsxir.Stream.Event{} = event -> send(parent, {ref, event}) end

      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "m"]}], fn ->
        {%Dsxir.Program.State{}, prediction} =
          Predict.forward(
            %Dsxir.Program.State{},
            AnswerQuestion,
            %{question: "?"},
            stream: stream,
            listen: [:answer]
          )

        assert prediction[:answer] == "42"
      end)

      assert_receive {^ref, %Dsxir.Stream.Event{type: :token, data: "[[ ## answer ## ]]\n4"}}
      assert_receive {^ref, %Dsxir.Stream.Event{type: :field_delta, field: :answer, data: "4"}}
      assert_receive {^ref, %Dsxir.Stream.Event{type: :field_delta, field: :answer, data: "2"}}
      assert_receive {^ref, %Dsxir.Stream.Event{type: :done}}
    end

    test "forward/4 with listen: raises for a non-string output field" do
      err =
        try do
          Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "m"]}], fn ->
            Predict.forward(
              %Dsxir.Program.State{},
              Dsxir.Test.Fixtures.RankItems,
              %{query: "q", items: ["a"]},
              stream: fn _ -> :ok end,
              listen: [:confidence]
            )
          end)

          flunk("expected Invalid.Configuration")
        rescue
          e in Dsxir.Errors.Invalid.Configuration -> e
        end

      assert %Dsxir.Errors.Invalid.Configuration{
               key: :listen,
               value: :confidence,
               reason: :non_string_listened_field
             } = err
    end

    test "forward/4 with listen: raises for an unknown output field" do
      err =
        try do
          Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "m"]}], fn ->
            Predict.forward(
              %Dsxir.Program.State{},
              AnswerQuestion,
              %{question: "?"},
              stream: fn _ -> :ok end,
              listen: [:nope]
            )
          end)

          flunk("expected Invalid.Configuration")
        rescue
          e in Dsxir.Errors.Invalid.Configuration -> e
        end

      assert %Dsxir.Errors.Invalid.Configuration{
               key: :listen,
               value: :nope,
               reason: :unknown_listened_field
             } = err
    end

    test "forward/4 with Json adapter raises Invalid.Configuration when :stream is set" do
      Dsxir.Settings.context(
        [lm: {Dsxir.LM.Sycophant, [model: "stub"]}, adapter: Dsxir.Adapter.Json],
        fn ->
          err =
            try do
              Predict.forward(
                %Dsxir.Program.State{},
                AnswerQuestion,
                %{question: "x"},
                stream: fn _chunk -> :ok end
              )

              flunk("expected Invalid.Configuration")
            rescue
              e in Dsxir.Errors.Invalid.Configuration -> e
            end

          assert %Dsxir.Errors.Invalid.Configuration{
                   key: :stream,
                   reason: :streaming_unsupported_for_json_adapter
                 } = err
        end
      )
    end

    test "forward/4 without :stream opt runs normally and invokes no callback" do
      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, opts ->
        refute Keyword.has_key?(opts, :stream)
        {:ok, "[[ ## answer ## ]]\nok", Dsxir.LM.empty_usage()}
      end)

      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        {%Dsxir.Program.State{}, prediction} =
          Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])

        assert prediction[:answer] == "ok"
      end)
    end
  end
end
