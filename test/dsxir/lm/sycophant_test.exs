defmodule Dsxir.LM.SycophantTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.LM.Sycophant, as: Impl

  setup :set_mimic_from_context

  test "generate_text/3 returns the response text on success" do
    expect(Sycophant, :generate_text, fn "openai:gpt-4o-mini", _msgs, _opts ->
      {:ok, %Sycophant.Response{text: "hello", context: %Sycophant.Context{messages: []}}}
    end)

    assert {:ok, "hello", %Dsxir.Cost{}} =
             Impl.generate_text(
               [model: "openai:gpt-4o-mini"],
               [Sycophant.Message.user("hi")],
               []
             )
  end

  test "generate_text/3 extracts usage tokens and cost from Sycophant.Usage" do
    usage = %Sycophant.Usage{input_tokens: 10, output_tokens: 25, total_cost: 0.0001}

    expect(Sycophant, :generate_text, fn _model, _msgs, _opts ->
      {:ok,
       %Sycophant.Response{
         text: "hello",
         usage: usage,
         context: %Sycophant.Context{messages: []}
       }}
    end)

    assert {:ok, "hello",
            %Dsxir.Cost{input_tokens: 10, output_tokens: 25, total_cost: 0.0001, calls: 1}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "generate_text/3 maps a full Sycophant.Usage into a Dsxir.Cost" do
    usage = %Sycophant.Usage{
      input_tokens: 100,
      output_tokens: 50,
      cache_read_input_tokens: 10,
      cache_creation_input_tokens: 5,
      reasoning_tokens: 3,
      total_cost: 0.003,
      pricing: %Sycophant.Pricing{currency: "USD"}
    }

    expect(Sycophant, :generate_text, fn _model, _msgs, _opts ->
      {:ok,
       %Sycophant.Response{
         text: "hello",
         usage: usage,
         context: %Sycophant.Context{messages: []}
       }}
    end)

    assert {:ok, "hello", cost} = Impl.generate_text([model: "m"], [], [])

    assert cost == %Dsxir.Cost{
             input_tokens: 100,
             output_tokens: 50,
             cache_read_tokens: 10,
             cache_write_tokens: 5,
             reasoning_tokens: 3,
             total_cost: 0.003,
             currency: "USD",
             calls: 1
           }
  end

  test "generate_text/3 returns a zero Dsxir.Cost when usage is nil" do
    expect(Sycophant, :generate_text, fn _model, _msgs, _opts ->
      {:ok,
       %Sycophant.Response{
         text: "hello",
         usage: nil,
         context: %Sycophant.Context{messages: []}
       }}
    end)

    assert {:ok, "hello", %Dsxir.Cost{}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "generate_text/3 lifts api_key/base_url into credentials" do
    expect(Sycophant, :generate_text, fn _model, _msgs, opts ->
      assert opts[:credentials] == %{api_key: "sk-test", base_url: "https://example.test"}
      refute Keyword.has_key?(opts, :api_key)
      refute Keyword.has_key?(opts, :base_url)
      {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
    end)

    Impl.generate_text(
      [model: "m", api_key: "sk-test", base_url: "https://example.test"],
      [],
      []
    )
  end

  test "per-call opts override config opts" do
    expect(Sycophant, :generate_text, fn _model, _msgs, opts ->
      assert opts[:temperature] == 0.0
      {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
    end)

    Impl.generate_text(
      [model: "m", temperature: 0.7],
      [],
      temperature: 0.0
    )
  end

  test "generate_text/3 never forwards Dsxir settings keys to Sycophant" do
    expect(Sycophant, :generate_text, fn _model, _msgs, opts ->
      for key <- [:lm, :callbacks, :call_plugs, :program_plugs, :metadata, :hints] do
        refute Keyword.has_key?(opts, key), "leaked #{inspect(key)} to Sycophant: #{inspect(opts)}"
      end

      assert opts[:temperature] == 0.5
      {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
    end)

    Impl.generate_text(
      [model: "m", lm: {Impl, []}, metadata: %{tenant: "t"}, temperature: 0.5],
      [],
      hints: %{answer: "x"}, callbacks: []
    )
  end

  test "generate_object/4 never forwards Dsxir settings keys to Sycophant" do
    expect(Sycophant, :generate_object, fn _model, _msgs, _schema, opts ->
      refute Keyword.has_key?(opts, :lm)
      refute Keyword.has_key?(opts, :hints)
      {:ok, %Sycophant.Response{object: %{a: 1}, context: %Sycophant.Context{messages: []}}}
    end)

    Impl.generate_object(
      [model: "m", lm: {Impl, []}],
      [],
      Zoi.map(%{}),
      hints: %{answer: "x"}
    )
  end

  test "translates AuthenticationFailed to Dsxir.Errors.LM.Authentication" do
    err = %Sycophant.Error.Provider.AuthenticationFailed{status: 401, body: "nope"}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.Authentication{model_id: "m", reason: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates RateLimited preserving retry_after" do
    err = %Sycophant.Error.Provider.RateLimited{retry_after: 30}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RateLimited{retry_after: 30}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates ServerError preserving status" do
    err = %Sycophant.Error.Provider.ServerError{status: 503, body: "down"}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{status: 503}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates BadRequest preserving status" do
    err = %Sycophant.Error.Provider.BadRequest{status: 400, body: "nope"}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{status: 400}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates BadRequest with context-window phrase into ContextWindow" do
    body =
      "This model's maximum context length was exceeded: prompt of 9001 tokens, limit of 8192."

    err = %Sycophant.Error.Provider.BadRequest{status: 400, body: body}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error,
            %Dsxir.Errors.LM.ContextWindow{
              model_id: "m",
              prompt_tokens: 9001,
              limit: 8192,
              parent_error: ^err
            }} = Impl.generate_text([model: "m"], [], [])
  end

  test "BadRequest without a context-window phrase still translates to RequestFailed" do
    err = %Sycophant.Error.Provider.BadRequest{
      status: 400,
      body: "some unrelated upstream problem"
    }

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error,
            %Dsxir.Errors.LM.RequestFailed{model_id: "m", status: 400, parent_error: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates Timeout to RequestFailed with nil status" do
    err = %Sycophant.Error.Provider.Timeout{reason: :etimeout}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{status: nil, parent_error: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates ResponseInvalid to RequestFailed with nil status" do
    err = %Sycophant.Error.Provider.ResponseInvalid{errors: ["bad"], raw: %{}}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{status: nil, parent_error: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates ContentFiltered into RequestFailed preserving the upstream error" do
    err = Sycophant.Error.Provider.ContentFiltered.exception(reason: "policy")

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{model_id: "m", parent_error: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates ModelNotFound into RequestFailed preserving the upstream error" do
    err = Sycophant.Error.Provider.ModelNotFound.exception(model: "m")

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{model_id: "m", parent_error: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates MissingCredentials to Authentication{reason: :missing_credentials}" do
    err = Sycophant.Error.Invalid.MissingCredentials.exception(provider: :openai)

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.Authentication{reason: :missing_credentials, model_id: "m"}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "falls back to generic RequestFailed for unrecognised errors" do
    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, :wat} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{parent_error: :wat}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "Response{text: nil} maps to RequestFailed{parent_error: :empty_response}" do
    expect(Sycophant, :generate_text, fn _, _, _ ->
      {:ok, %Sycophant.Response{text: nil, context: %Sycophant.Context{messages: []}}}
    end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{parent_error: :empty_response}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "drops :headers from sycophant opts" do
    expect(Sycophant, :generate_text, fn _model, _msgs, opts ->
      refute Keyword.has_key?(opts, :headers)
      {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
    end)

    Impl.generate_text(
      [model: "m", headers: [{"x-foo", "bar"}]],
      [],
      []
    )
  end

  test "drops dsxir-internal opts (:path, :adapter) from sycophant opts" do
    expect(Sycophant, :generate_text, fn _model, _msgs, opts ->
      refute Keyword.has_key?(opts, :path)
      refute Keyword.has_key?(opts, :adapter)
      {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
    end)

    Impl.generate_text(
      [model: "m"],
      [],
      path: [:extract_actions, :action_items],
      adapter: Dsxir.Adapter.Chat
    )
  end

  describe "message normalization" do
    test "generate_text/3 converts plain %{role:, content:} maps with string roles to Sycophant.Message" do
      expect(Sycophant, :generate_text, fn _model, msgs, _opts ->
        assert [%Sycophant.Message{role: :user, content: "hi"}] = msgs
        {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
      end)

      assert {:ok, "ok", _usage} =
               Impl.generate_text([model: "m"], [%{role: "user", content: "hi"}], [])
    end

    test "generate_text/3 passes through %Sycophant.Message{} unchanged" do
      original = Sycophant.Message.user("hello")

      expect(Sycophant, :generate_text, fn _model, msgs, _opts ->
        assert msgs == [original]
        {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
      end)

      Impl.generate_text([model: "m"], [original], [])
    end

    test "generate_text/3 normalizes atom roles" do
      expect(Sycophant, :generate_text, fn _model, msgs, _opts ->
        assert [
                 %Sycophant.Message{role: :system, content: "be brief"},
                 %Sycophant.Message{role: :user, content: "hi"}
               ] = msgs

        {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
      end)

      Impl.generate_text(
        [model: "m"],
        [%{role: :system, content: "be brief"}, %{role: :user, content: "hi"}],
        []
      )
    end

    test "generate_object/4 also normalizes plain maps" do
      schema = Zoi.object(%{answer: Zoi.string()})

      expect(Sycophant, :generate_object, fn _model, msgs, _schema, _opts ->
        assert [%Sycophant.Message{role: :user, content: "hi"}] = msgs

        {:ok,
         %Sycophant.Response{
           text: nil,
           object: %{"answer" => "42"},
           context: %Sycophant.Context{messages: []}
         }}
      end)

      Impl.generate_object([model: "m"], [%{role: "user", content: "hi"}], schema, [])
    end
  end

  test ":cache and :_dsxir_nonce are stripped before forwarding to Sycophant" do
    expect(Sycophant, :generate_text, fn _model, _msgs, sycophant_opts ->
      refute Keyword.has_key?(sycophant_opts, :cache)
      refute Keyword.has_key?(sycophant_opts, :_dsxir_nonce)
      assert sycophant_opts[:temperature] == 1.0
      {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
    end)

    assert {:ok, "ok", _usage} =
             Impl.generate_text(
               [model: "openai:gpt-4o-mini"],
               [],
               cache: false,
               _dsxir_nonce: 42,
               temperature: 1.0
             )
  end

  describe "generate_object/4" do
    test "returns {:ok, object, usage} on success" do
      usage = %Sycophant.Usage{input_tokens: 7, output_tokens: 11, total_cost: 0.0002}

      expect(Sycophant, :generate_object, fn "openai:gpt-4o-mini", _msgs, _schema, _opts ->
        {:ok,
         %Sycophant.Response{
           text: nil,
           object: %{"answer" => "42"},
           usage: usage,
           context: %Sycophant.Context{messages: []}
         }}
      end)

      schema = Zoi.object(%{answer: Zoi.string()})

      assert {:ok, %{"answer" => "42"},
              %Dsxir.Cost{input_tokens: 7, output_tokens: 11, total_cost: 0.0002, calls: 1}} =
               Impl.generate_object(
                 [model: "openai:gpt-4o-mini"],
                 [Sycophant.Message.user("hi")],
                 schema,
                 []
               )
    end

    test "returns {:ok, object, empty_usage} when Sycophant returns nil usage" do
      expect(Sycophant, :generate_object, fn _model, _msgs, _schema, _opts ->
        {:ok,
         %Sycophant.Response{
           object: %{"answer" => "42"},
           usage: nil,
           context: %Sycophant.Context{messages: []}
         }}
      end)

      schema = Zoi.object(%{answer: Zoi.string()})

      assert {:ok, %{"answer" => "42"}, %Dsxir.Cost{}} =
               Impl.generate_object([model: "m"], [], schema, [])
    end

    test "returns RequestFailed{parent_error: :empty_object} when object is nil" do
      expect(Sycophant, :generate_object, fn _model, _msgs, _schema, _opts ->
        {:ok,
         %Sycophant.Response{
           object: nil,
           usage: nil,
           context: %Sycophant.Context{messages: []}
         }}
      end)

      schema = Zoi.object(%{answer: Zoi.string()})

      assert {:error,
              %Dsxir.Errors.LM.RequestFailed{
                model_id: "m",
                status: nil,
                parent_error: :empty_object
              }} =
               Impl.generate_object([model: "m"], [], schema, [])
    end

    test "translates upstream errors via the same translate path" do
      err = %Sycophant.Error.Provider.AuthenticationFailed{status: 401, body: "nope"}

      expect(Sycophant, :generate_object, fn _, _, _, _ -> {:error, err} end)

      schema = Zoi.object(%{answer: Zoi.string()})

      assert {:error, %Dsxir.Errors.LM.Authentication{model_id: "m", reason: ^err}} =
               Impl.generate_object([model: "m"], [], schema, [])
    end

    test "lifts api_key/base_url into credentials and drops :headers" do
      expect(Sycophant, :generate_object, fn _model, _msgs, _schema, opts ->
        assert opts[:credentials] == %{api_key: "sk-test", base_url: "https://example.test"}
        refute Keyword.has_key?(opts, :api_key)
        refute Keyword.has_key?(opts, :base_url)
        refute Keyword.has_key?(opts, :headers)

        {:ok,
         %Sycophant.Response{
           object: %{"answer" => "ok"},
           context: %Sycophant.Context{messages: []}
         }}
      end)

      schema = Zoi.object(%{answer: Zoi.string()})

      Impl.generate_object(
        [
          model: "m",
          api_key: "sk-test",
          base_url: "https://example.test",
          headers: [{"x-foo", "bar"}]
        ],
        [],
        schema,
        []
      )
    end
  end

  describe "embed/3" do
    test "returns float vectors in input order" do
      expect(Sycophant, :embed, fn %Sycophant.EmbeddingRequest{
                                     inputs: ["a", "b"],
                                     model: "openai:text-embedding-3-small"
                                   },
                                   _opts ->
        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: [[0.1, 0.2], [0.3, 0.4]]},
           model: "openai:text-embedding-3-small",
           usage: %Sycophant.Usage{input_tokens: 2, output_tokens: 0, total_cost: +0.0}
         }}
      end)

      assert {:ok, [[0.1, 0.2], [0.3, 0.4]],
              %Dsxir.Cost{input_tokens: 2, output_tokens: 0, total_cost: +0.0, calls: 1}} =
               Impl.embed(
                 [
                   model: "openai:gpt-4o-mini",
                   embedding_model: "openai:text-embedding-3-small"
                 ],
                 ["a", "b"],
                 []
               )
    end

    test "per-call :embedding_model overrides config :embedding_model" do
      expect(Sycophant, :embed, fn %Sycophant.EmbeddingRequest{model: "override:model"}, _opts ->
        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: [[+0.0]]},
           usage: nil
         }}
      end)

      assert {:ok, [[+0.0]], %Dsxir.Cost{}} =
               Impl.embed(
                 [model: "m", embedding_model: "config:model"],
                 ["a"],
                 embedding_model: "override:model"
               )
    end

    test "falls back to config :model when no :embedding_model is set" do
      expect(Sycophant, :embed, fn %Sycophant.EmbeddingRequest{model: "openai:gpt-4o-mini"},
                                   _opts ->
        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: [[0.5]]},
           usage: nil
         }}
      end)

      assert {:ok, [[0.5]], _usage} =
               Impl.embed([model: "openai:gpt-4o-mini"], ["a"], [])
    end

    test "drops :embedding_model from sycophant opts" do
      expect(Sycophant, :embed, fn _req, opts ->
        refute Keyword.has_key?(opts, :embedding_model)

        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: [[0.0]]},
           usage: nil
         }}
      end)

      Impl.embed(
        [model: "m", embedding_model: "e"],
        ["a"],
        []
      )
    end

    test "lifts api_key/base_url into credentials and drops :headers" do
      expect(Sycophant, :embed, fn _req, opts ->
        assert opts[:credentials] == %{api_key: "sk-test", base_url: "https://example.test"}
        refute Keyword.has_key?(opts, :api_key)
        refute Keyword.has_key?(opts, :base_url)
        refute Keyword.has_key?(opts, :headers)

        {:ok,
         %Sycophant.EmbeddingResponse{
           embeddings: %{float: [[0.0]]},
           usage: nil
         }}
      end)

      Impl.embed(
        [
          model: "m",
          api_key: "sk-test",
          base_url: "https://example.test",
          headers: [{"x-foo", "bar"}]
        ],
        ["a"],
        []
      )
    end

    test "returns :no_float_embeddings when the response has no float vectors" do
      expect(Sycophant, :embed, fn _req, _opts ->
        {:ok, %Sycophant.EmbeddingResponse{embeddings: %{int8: [[1, 2]]}}}
      end)

      assert {:error,
              %Dsxir.Errors.Invalid.Configuration{
                key: :embedding_type,
                value: [:int8],
                reason: :no_float_embeddings
              }} =
               Impl.embed(
                 [model: "m", embedding_model: "e"],
                 ["a"],
                 []
               )
    end

    test "translates upstream errors via the same translate path" do
      err = %Sycophant.Error.Provider.AuthenticationFailed{status: 401, body: "nope"}

      expect(Sycophant, :embed, fn _req, _opts -> {:error, err} end)

      assert {:error, %Dsxir.Errors.LM.Authentication{model_id: "e", reason: ^err}} =
               Impl.embed([model: "m", embedding_model: "e"], ["a"], [])
    end
  end

  describe "Dsxir.LM.embed/2 dispatcher" do
    defmodule NoEmbedImpl do
      @behaviour Dsxir.LM
      @impl true
      def generate_text(_c, _m, _o), do: {:ok, "", Dsxir.LM.empty_usage()}
      @impl true
      def generate_object(_c, _m, _s, _o), do: {:ok, %{}, Dsxir.LM.empty_usage()}
    end

    test "raises Configuration{reason: :embed_unsupported} when impl does not export embed/3" do
      Dsxir.Settings.context([lm: {NoEmbedImpl, [model: "fake:m"]}], fn ->
        assert_raise Dsxir.Errors.Invalid.Configuration, ~r/embed_unsupported/, fn ->
          Dsxir.LM.embed(["a"])
        end
      end)
    end

    test "raises Configuration{reason: :no_lm_configured} when :lm is unset" do
      Dsxir.Settings.context([lm: nil], fn ->
        assert_raise Dsxir.Errors.Invalid.Configuration, ~r/no_lm_configured/, fn ->
          Dsxir.LM.embed(["a"])
        end
      end)
    end

    test "raises Configuration{reason: :expected_impl_config_tuple} for malformed config" do
      Dsxir.Settings.context([lm: :bogus], fn ->
        assert_raise Dsxir.Errors.Invalid.Configuration, ~r/expected_impl_config_tuple/, fn ->
          Dsxir.LM.embed(["a"])
        end
      end)
    end
  end
end
