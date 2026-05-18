defmodule Dsxir.DemoStrategy.KNNTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.DemoStrategy.KNN
  alias Dsxir.DemoStrategy.KNN.Entry

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defp strategy(entries, opts) do
    %KNN{
      k: Keyword.get(opts, :k, 2),
      embedder: {Dsxir.LM.Sycophant, [model: "test-embed"]},
      embedder_id: "test-embed",
      embed_fields: Keyword.get(opts, :embed_fields, :all),
      entries: entries
    }
  end

  defp ex(data), do: %Dsxir.Example{data: data}

  defp entry(vec, data), do: %Entry{embedding: vec, example: ex(data)}

  test "returns top-K examples sorted by cosine descending" do
    entries = [
      entry([1.0, 0.0], %{label: "north"}),
      entry([0.0, 1.0], %{label: "east"}),
      entry([0.7, 0.7], %{label: "northeast"})
    ]

    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, ["a: north\n"], _opts ->
      {:ok, [[1.0, 0.0]], Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "test-embed"]}], fn ->
      result = KNN.resolve(strategy(entries, k: 2), %{a: "north"})
      assert Enum.map(result, & &1.data.label) == ["north", "northeast"]
    end)
  end

  test "k > length(entries) returns all and emits insufficient_entries telemetry" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:dsxir, :knn, :insufficient_entries]])

    entries = [entry([1.0, 0.0], %{label: "a"})]

    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, _texts, _opts ->
      {:ok, [[1.0, 0.0]], Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "test-embed"]}], fn ->
      result = KNN.resolve(strategy(entries, k: 5), %{a: "x"}, predictor: :p)
      assert length(result) == 1
    end)

    assert_receive {[:dsxir, :knn, :insufficient_entries], ^ref, _meas,
                    %{requested_k: 5, available: 1, predictor: :p}}
  end

  test "resolve telemetry fires with embedder_id and predictor" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:dsxir, :knn, :resolve]])

    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, _texts, _opts ->
      {:ok, [[1.0, 0.0]], Dsxir.LM.empty_usage()}
    end)

    entries = [entry([1.0, 0.0], %{x: 1})]

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "test-embed"]}], fn ->
      KNN.resolve(strategy(entries, k: 1), %{a: "x"}, predictor: :extract)
    end)

    assert_receive {[:dsxir, :knn, :resolve], ^ref, %{k_returned: 1, embed_duration: d},
                    %{predictor: :extract, embedder_id: "test-embed"}}

    assert is_integer(d)
  end

  test "embedder error bubbles up as a typed LM error" do
    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, _texts, _opts ->
      {:error, %Dsxir.Errors.LM.RateLimited{model_id: "test-embed", retry_after: 5}}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "test-embed"]}], fn ->
      assert_raise Dsxir.Errors.LM.RateLimited, fn ->
        KNN.resolve(strategy([entry([1.0], %{x: 1})], k: 1), %{a: "x"})
      end
    end)
  end

  test "non-typed embedder error wraps as RequestFailed with parent_error field" do
    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, _texts, _opts ->
      {:error, :nxdomain}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "test-embed"]}], fn ->
      err =
        assert_raise Dsxir.Errors.LM.RequestFailed, fn ->
          KNN.resolve(strategy([entry([1.0], %{x: 1})], k: 1), %{a: "x"})
        end

      assert err.model_id == "test-embed"
      assert err.parent_error == :nxdomain
    end)
  end

  test "unexpected multi-vector embed response raises PredictorError with :unexpected_embed_count" do
    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, _texts, _opts ->
      {:ok, [[1.0, 0.0], [0.0, 1.0]], Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "test-embed"]}], fn ->
      err =
        assert_raise Dsxir.Errors.Framework.PredictorError, fn ->
          KNN.resolve(strategy([entry([1.0, 0.0], %{x: 1})], k: 1), %{a: "x"})
        end

      assert err.reason == :unexpected_embed_count
      assert err.trajectory == %{got: 2, expected: 1}
    end)
  end

  test "credentials from Settings :lm are merged into stripped strategy config" do
    test_pid = self()

    expect(Dsxir.LM.Sycophant, :embed, fn cfg, _texts, _opts ->
      send(test_pid, {:cfg, cfg})
      {:ok, [[1.0]], Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: "gen-model", api_key: "k-from-settings"]}],
      fn ->
        s = %KNN{
          k: 1,
          embedder: {Dsxir.LM.Sycophant, [model: "test-embed"]},
          embedder_id: "test-embed",
          embed_fields: :all,
          entries: [entry([1.0], %{x: 1})]
        }

        KNN.resolve(s, %{a: "x"})
      end
    )

    assert_receive {:cfg, cfg}
    assert Keyword.get(cfg, :model) == "test-embed"
    assert Keyword.get(cfg, :api_key) == "k-from-settings"
  end

  test "strip_credentials drops api_key, base_url, headers" do
    assert KNN.strip_credentials(
             model: "m",
             api_key: "k",
             base_url: "u",
             headers: [],
             temperature: 0.0
           ) == [model: "m", temperature: 0.0]
  end

  test "Inspect for %KNN{} hides entries and embedder config" do
    s =
      strategy(
        [
          entry([1.0, 0.0, 0.0], %{x: 1}),
          entry([0.0, 1.0, 0.0], %{x: 2})
        ],
        k: 3,
        embed_fields: [:question]
      )

    inspected = inspect(s)

    assert inspected ==
             "#Dsxir.DemoStrategy.KNN<k: 3, embedder_id: \"test-embed\", embed_fields: [:question], entries: 2>"
  end

  test "Inspect for %KNN.Entry{} hides the embedding vector" do
    e = entry([0.1, 0.2, 0.3, 0.4, 0.5], %{x: 42})
    inspected = inspect(e)

    refute inspected =~ "0.1"
    refute inspected =~ "0.2"
    assert inspected =~ "#Dsxir.DemoStrategy.KNN.Entry<dim: 5"
    assert inspected =~ "example:"
  end
end
