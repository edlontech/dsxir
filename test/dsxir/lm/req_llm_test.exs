defmodule Dsxir.LM.ReqLLMTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.LM.ReqLLM, as: Impl

  setup :set_mimic_from_context

  defp response(text, usage \\ nil) do
    %ReqLLM.Response{
      id: "resp",
      model: "m",
      context: nil,
      message: if(text, do: ReqLLM.Context.assistant(text)),
      usage: usage
    }
  end

  defp stream_response(chunks) do
    %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: self(),
      cancel: fn -> :ok end,
      model: nil,
      context: nil
    }
  end

  describe "generate_text/3" do
    test "returns the response text with a zero cost when usage is nil" do
      expect(ReqLLM, :generate_text, fn "openai:gpt-4o-mini", [%{role: :user}], _opts ->
        {:ok, response("hello")}
      end)

      assert {:ok, "hello", %Dsxir.Cost{}} =
               Impl.generate_text(
                 [model: "openai:gpt-4o-mini"],
                 [%{role: :user, content: "hi"}],
                 []
               )
    end

    test "maps ReqLLM usage into a Dsxir.Cost" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        cache_read_tokens: 10,
        cache_write_tokens: 5,
        reasoning_tokens: 3,
        input_cost: 0.001,
        output_cost: 0.002,
        reasoning_cost: 0.0,
        total_cost: 0.003,
        pricing: %{status: :priced, currency: "USD", total: 0.003}
      }

      expect(ReqLLM, :generate_text, fn _, _, _ -> {:ok, response("hello", usage)} end)

      assert {:ok, "hello", cost} = Impl.generate_text([model: "m"], [], [])

      assert cost == %Dsxir.Cost{
               input_tokens: 100,
               output_tokens: 50,
               cache_read_tokens: 10,
               cache_write_tokens: 5,
               reasoning_tokens: 3,
               input_cost: 0.001,
               output_cost: 0.002,
               reasoning_cost: 0.0,
               total_cost: 0.003,
               currency: "USD",
               calls: 1
             }
    end

    test "per-call opts override config, credentials pass through, dsxir keys are stripped" do
      expect(ReqLLM, :generate_text, fn _model, _msgs, opts ->
        assert opts[:temperature] == 0.0
        assert opts[:api_key] == "sk-test"
        assert opts[:base_url] == "https://example.test"

        for key <- [:model, :lm, :metadata, :hints, :callbacks, :cache, :_dsxir_nonce, :headers] do
          refute Keyword.has_key?(opts, key), "leaked #{inspect(key)}: #{inspect(opts)}"
        end

        {:ok, response("ok")}
      end)

      Impl.generate_text(
        [
          model: "m",
          temperature: 0.7,
          api_key: "sk-test",
          base_url: "https://example.test",
          lm: {Impl, []},
          metadata: %{tenant: "t"},
          headers: [{"x-foo", "bar"}]
        ],
        [],
        temperature: 0.0,
        hints: %{answer: "x"},
        callbacks: [],
        cache: false,
        _dsxir_nonce: 1
      )
    end

    test "a response without a message maps to RequestFailed{parent_error: :empty_response}" do
      expect(ReqLLM, :generate_text, fn _, _, _ -> {:ok, response(nil)} end)

      assert {:error,
              %Dsxir.Errors.LM.RequestFailed{model_id: "m", parent_error: :empty_response}} =
               Impl.generate_text([model: "m"], [], [])
    end
  end

  describe "error translation" do
    defp request_error(fields), do: ReqLLM.Error.API.Request.exception(fields)

    test "401 and 403 become Authentication" do
      for status <- [401, 403] do
        err = request_error(status: status, reason: "nope")
        expect(ReqLLM, :generate_text, fn _, _, _ -> {:error, err} end)

        assert {:error, %Dsxir.Errors.LM.Authentication{model_id: "m", reason: ^err}} =
                 Impl.generate_text([model: "m"], [], [])
      end
    end

    test "429 becomes RateLimited with retry_after in seconds" do
      err = request_error(status: 429, reason: "slow down", headers: %{"retry-after" => ["30"]})
      expect(ReqLLM, :generate_text, fn _, _, _ -> {:error, err} end)

      assert {:error, %Dsxir.Errors.LM.RateLimited{model_id: "m", retry_after: 30}} =
               Impl.generate_text([model: "m"], [], [])
    end

    test "400 with a context-window phrase becomes ContextWindow" do
      body = %{
        "error" => %{
          "message" =>
            "This model's maximum context length was exceeded: prompt of 9001 tokens, limit of 8192."
        }
      }

      err = request_error(status: 400, reason: "Bad Request", response_body: body)
      expect(ReqLLM, :generate_text, fn _, _, _ -> {:error, err} end)

      assert {:error,
              %Dsxir.Errors.LM.ContextWindow{
                model_id: "m",
                prompt_tokens: 9001,
                limit: 8192,
                parent_error: ^err
              }} = Impl.generate_text([model: "m"], [], [])
    end

    test "other 400s and server errors become RequestFailed preserving status" do
      for status <- [400, 503] do
        err = request_error(status: status, reason: "unrelated", response_body: "boom")
        expect(ReqLLM, :generate_text, fn _, _, _ -> {:error, err} end)

        assert {:error,
                %Dsxir.Errors.LM.RequestFailed{model_id: "m", status: ^status, parent_error: ^err}} =
                 Impl.generate_text([model: "m"], [], [])
      end
    end

    test "unrecognised errors become RequestFailed with nil status" do
      expect(ReqLLM, :generate_text, fn _, _, _ -> {:error, :wat} end)

      assert {:error, %Dsxir.Errors.LM.RequestFailed{status: nil, parent_error: :wat}} =
               Impl.generate_text([model: "m"], [], [])
    end
  end

  describe "generate_object/4" do
    test "returns the object and usage, stripping dsxir keys" do
      schema = Zoi.object(%{answer: Zoi.string()})

      expect(ReqLLM, :generate_object, fn "m", _msgs, ^schema, opts ->
        refute Keyword.has_key?(opts, :lm)
        refute Keyword.has_key?(opts, :hints)

        {:ok,
         %ReqLLM.Response{
           id: "r",
           model: "m",
           context: nil,
           object: %{"answer" => "42"},
           usage: %{input_tokens: 7, output_tokens: 11, total_cost: 0.0002}
         }}
      end)

      assert {:ok, %{"answer" => "42"},
              %Dsxir.Cost{input_tokens: 7, output_tokens: 11, total_cost: 0.0002, calls: 1}} =
               Impl.generate_object([model: "m", lm: {Impl, []}], [], schema, hints: %{})
    end

    test "a nil object maps to RequestFailed{parent_error: :empty_object}" do
      expect(ReqLLM, :generate_object, fn _, _, _, _ -> {:ok, response(nil)} end)

      assert {:error, %Dsxir.Errors.LM.RequestFailed{parent_error: :empty_object}} =
               Impl.generate_object([model: "m"], [], Zoi.map(%{}), [])
    end
  end

  describe "embed/3" do
    test "uses :embedding_model, requests usage and maps it" do
      expect(ReqLLM, :embed, fn "openai:text-embedding-3-small", ["a", "b"], opts ->
        assert opts[:return_usage] == true
        refute Keyword.has_key?(opts, :embedding_model)
        refute Keyword.has_key?(opts, :model)

        {:ok, %{embedding: [[0.1, 0.2], [0.3, 0.4]], usage: %{input: 2, total_cost: 0.0}}}
      end)

      assert {:ok, [[0.1, 0.2], [0.3, 0.4]],
              %Dsxir.Cost{input_tokens: 2, output_tokens: 0, total_cost: +0.0, calls: 1}} =
               Impl.embed(
                 [model: "openai:gpt-4o-mini", embedding_model: "openai:text-embedding-3-small"],
                 ["a", "b"],
                 []
               )
    end

    test "per-call :embedding_model wins, then config :model is the fallback" do
      expect(ReqLLM, :embed, fn "override", _, _ -> {:ok, %{embedding: [[0.0]], usage: nil}} end)
      expect(ReqLLM, :embed, fn "m", _, _ -> {:ok, %{embedding: [[0.0]], usage: nil}} end)

      assert {:ok, _, %Dsxir.Cost{}} =
               Impl.embed([model: "m", embedding_model: "cfg"], ["a"],
                 embedding_model: "override"
               )

      assert {:ok, _, _} = Impl.embed([model: "m"], ["a"], [])
    end

    test "translates upstream errors" do
      err = ReqLLM.Error.API.Request.exception(status: 401, reason: "nope")
      expect(ReqLLM, :embed, fn _, _, _ -> {:error, err} end)

      assert {:error, %Dsxir.Errors.LM.Authentication{model_id: "e", reason: ^err}} =
               Impl.embed([model: "m", embedding_model: "e"], ["a"], [])
    end
  end

  describe "generate_text/3 streaming" do
    setup do
      chunks = [
        ReqLLM.StreamChunk.thinking("hmm"),
        ReqLLM.StreamChunk.text("he"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop}),
        ReqLLM.StreamChunk.text("llo")
      ]

      stub(ReqLLM.StreamResponse, :usage, fn _ -> %{input_tokens: 5, output_tokens: 7} end)

      stub(ReqLLM.StreamResponse, :to_response, fn sr ->
        _ = Enum.to_list(sr.stream)
        {:ok, response("hello", %{input_tokens: 5, output_tokens: 7})}
      end)

      %{chunks: chunks}
    end

    test "translates chunks for a 1-arity sink and ends with :usage and :done", %{chunks: chunks} do
      parent = self()

      expect(ReqLLM, :stream_text, fn _model, _msgs, opts ->
        refute Keyword.has_key?(opts, :stream)
        {:ok, stream_response(chunks)}
      end)

      assert {:ok, "hello", %Dsxir.Cost{input_tokens: 5, output_tokens: 7}} =
               Impl.generate_text([model: "m"], [], stream: &send(parent, {:chunk, &1}))

      assert_receive {:chunk, %Dsxir.LM.StreamChunk{type: :reasoning_delta, data: "hmm"}}
      assert_receive {:chunk, %Dsxir.LM.StreamChunk{type: :text_delta, data: "he"}}
      assert_receive {:chunk, %Dsxir.LM.StreamChunk{type: :text_delta, data: "llo"}}

      assert_receive {:chunk,
                      %Dsxir.LM.StreamChunk{
                        type: :usage,
                        data: %Dsxir.Cost{input_tokens: 5, output_tokens: 7, calls: 1}
                      }}

      assert_receive {:chunk, %Dsxir.LM.StreamChunk{type: :done}}
      refute_receive {:chunk, _}
    end

    test "threads the accumulator form through translated chunks", %{chunks: chunks} do
      parent = self()
      expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, stream_response(chunks)} end)

      collector =
        {[],
         fn
           %Dsxir.LM.StreamChunk{type: :done}, acc -> send(parent, {:acc, Enum.reverse(acc)})
           %Dsxir.LM.StreamChunk{type: :text_delta, data: data}, acc -> [data | acc]
           _, acc -> acc
         end}

      assert {:ok, "hello", _} = Impl.generate_text([model: "m"], [], stream: collector)
      assert_receive {:acc, ["he", "llo"]}
    end

    test "a terminal error meta chunk becomes :failed and suppresses :done" do
      parent = self()
      chunks = [ReqLLM.StreamChunk.meta(%{finish_reason: :error, error: "boom", terminal?: true})]

      expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, stream_response(chunks)} end)

      stub(ReqLLM.StreamResponse, :to_response, fn sr ->
        _ = Enum.to_list(sr.stream)
        {:error, "boom"}
      end)

      assert {:error, %Dsxir.Errors.LM.RequestFailed{parent_error: "boom"}} =
               Impl.generate_text([model: "m"], [], stream: &send(parent, {:chunk, &1}))

      assert_receive {:chunk,
                      %Dsxir.LM.StreamChunk{
                        type: :failed,
                        data: %Dsxir.Errors.LM.RequestFailed{model_id: "m", parent_error: "boom"}
                      }}

      refute_receive {:chunk, _}
    end
  end
end
