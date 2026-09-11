defmodule Dsxir.Test.Fixtures.ObjectCapableLM do
  @moduledoc false
  @behaviour Dsxir.LM

  @impl Dsxir.LM
  def generate_text(_config, _messages, _opts) do
    {:ok, "text-response", Dsxir.LM.empty_usage()}
  end

  @impl Dsxir.LM
  def generate_object(_config, _messages, _schema, _opts) do
    {:ok, %{answer: "object-response"}, Dsxir.LM.empty_usage()}
  end
end

defmodule Dsxir.Test.Fixtures.ScriptedLM do
  @moduledoc """
  A `Dsxir.Predictor` fixture that returns scripted `%Dsxir.Prediction{}`
  values without touching the LM behaviour or any adapter. Reused by the
  runtime-program executor tests and the integration suite.

  The script lives in the process dictionary, keyed by predictor name. Each
  entry is a map `%{atom() => term() | function()}`:

    * a `function()` value receives the resolved inputs map and must return
      either a `%Dsxir.Prediction{}`, a `{fields_map, prediction_opts}` tuple,
      a plain `fields` map, or raise to simulate a runtime failure,
    * any other value is treated as the literal `fields` map.

  Predictors with no script entry raise — every executor test must script
  every predictor it expects to invoke.
  """

  @behaviour Dsxir.Predictor

  alias Dsxir.Prediction
  alias Dsxir.Program.State

  @key {__MODULE__, :script}

  @doc "Install a scripted-response map for the current process."
  @spec install_script(%{atom() => term()}) :: :ok
  def install_script(%{} = script) do
    Process.put(@key, script)
    :ok
  end

  @doc "Clear any scripted response for the current process."
  @spec clear_script() :: :ok
  def clear_script do
    Process.delete(@key)
    :ok
  end

  @impl Dsxir.Predictor
  def forward(%State{} = state, _signature, inputs, opts) do
    predictor = Keyword.fetch!(opts, :path) |> List.last()
    script = Process.get(@key) || %{}

    case Map.fetch(script, predictor) do
      :error ->
        raise "ScriptedLM has no entry for predictor #{inspect(predictor)}; install_script/1 first"

      {:ok, value} ->
        {state, build_prediction(value, inputs)}
    end
  end

  defp build_prediction(%Prediction{} = pred, _inputs), do: pred

  defp build_prediction({fields, opts}, _inputs) when is_map(fields) and is_list(opts),
    do: Prediction.new(fields, opts)

  defp build_prediction(fields, _inputs) when is_map(fields), do: Prediction.new(fields)

  defp build_prediction(fun, inputs) when is_function(fun, 1) do
    case fun.(inputs) do
      %Prediction{} = pred -> pred
      fields when is_map(fields) -> Prediction.new(fields)
      {fields, opts} when is_map(fields) and is_list(opts) -> Prediction.new(fields, opts)
      other -> raise "ScriptedLM script function returned unsupported shape: #{inspect(other)}"
    end
  end
end

defmodule Dsxir.Test.Fixtures.OptsEchoLM do
  @moduledoc """
  A `Dsxir.Predictor` fixture that records the `opts` keyword list it is
  invoked with into the process dictionary, keyed by predictor name, and
  returns a static `%{answer: "echoed"}` prediction. Used by the executor
  test suite to assert on `node_opts` injection and merging.
  """

  @behaviour Dsxir.Predictor

  alias Dsxir.Prediction
  alias Dsxir.Program.State

  @key {__MODULE__, :received_opts}

  @doc "Fetch the opts most recently received by `predictor_name`, or nil."
  @spec received_opts(atom()) :: keyword() | nil
  def received_opts(predictor_name) do
    Map.get(Process.get(@key, %{}), predictor_name)
  end

  @impl Dsxir.Predictor
  def forward(%State{} = state, _signature, _inputs, opts) do
    predictor = Keyword.fetch!(opts, :path) |> List.last()
    Process.put(@key, Map.put(Process.get(@key, %{}), predictor, opts))
    {state, Prediction.new(%{answer: "echoed"})}
  end
end
