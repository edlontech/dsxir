defmodule Dsxir.Adapter.Json do
  @moduledoc """
  Json adapter: instructs the LM to return a structured object validated against
  the signature's output Zoi schema, and parses the returned map through that
  schema directly.

  Unlike `Dsxir.Adapter.Chat`, this adapter consumes a map produced by the
  underlying provider's structured-output endpoint via
  `Dsxir.LM.generate_object/3`. Streaming is not supported with structured
  outputs; passing `:stream` in `opts` raises
  `Dsxir.Errors.Invalid.Configuration`.

  Returns `{:ok, map}` on success or `{:error, %Dsxir.Errors.Adapter.* {}}` on
  schema validation failure. No fallback to other adapters happens here.

  ## One-shot schema-mismatch retry

  When the provider returns an object that fails Zoi validation, the adapter
  retries once with a corrective user message appended that quotes the
  validation error. A second failure surfaces a
  `Dsxir.Errors.Adapter.FallbackExhausted{from: __MODULE__, to: __MODULE__,
  last_error: err}` via `format_and_call/4`'s `{:fallback, err}` return — the
  predictor's rescue path then raises it. Subscribers tell schema-retry
  exhaustion apart from Chat→Json exhaustion by reading `from`/`to`. The retry
  is internal to this module.
  """

  @behaviour Dsxir.Adapter

  alias Dsxir.Errors.Adapter.FallbackExhausted
  alias Dsxir.Errors.Adapter.ZoiValidation
  alias Dsxir.Settings
  alias Dsxir.Signature.Runtime
  alias Dsxir.Telemetry

  @impl Dsxir.Adapter
  def lm_mode, do: :object

  @impl Dsxir.Adapter
  def format(signature, inputs, demos, opts) do
    if Enum.any?(Map.values(inputs), &match?(%Dsxir.Primitives.History{}, &1)) do
      raise %Dsxir.Errors.Invalid.Configuration{
        key: :adapter,
        value: __MODULE__,
        reason: :history_input_unsupported
      }
    end

    if Keyword.has_key?(opts, :stream) do
      raise %Dsxir.Errors.Invalid.Configuration{
        key: :stream,
        value: Keyword.get(opts, :stream),
        reason: :streaming_unsupported_for_json_adapter
      }
    end

    start = System.monotonic_time()

    messages = [
      %{role: :system, content: system_prompt(signature, opts)},
      %{role: :user, content: user_prompt(signature, inputs, demos)}
    ]

    Telemetry.emit(
      Telemetry.adapter_format(),
      %{duration: System.monotonic_time() - start},
      Map.merge(Settings.resolve(:metadata, %{}), %{
        adapter: __MODULE__,
        signature: signature,
        outcome: :ok
      })
    )

    messages
  end

  @impl Dsxir.Adapter
  def parse(signature, raw_object, _opts) when is_map(raw_object) do
    start = System.monotonic_time()
    schema = output_schema(signature)

    result =
      case Zoi.parse(schema, raw_object) do
        {:ok, validated} ->
          {:ok, validated}

        {:error, zoi_errors} ->
          {:error,
           %Dsxir.Errors.Adapter.ZoiValidation{
             adapter: __MODULE__,
             field: nil,
             zoi_errors: zoi_errors,
             path: []
           }}
      end

    outcome = if match?({:ok, _}, result), do: :ok, else: :error

    Telemetry.emit(
      Telemetry.adapter_parse(),
      %{duration: System.monotonic_time() - start},
      Map.merge(Settings.resolve(:metadata, %{}), %{
        adapter: __MODULE__,
        signature: signature,
        outcome: outcome
      })
    )

    result
  end

  @impl Dsxir.Adapter
  def format_and_call(signature, inputs, demos, opts) do
    messages = format(signature, inputs, demos, opts)
    schema = output_schema(signature)

    case do_call_and_parse(signature, messages, schema, opts) do
      {:ok, fields, usage, payload} ->
        {:ok, fields, usage, payload}

      {:retry, validation_err} ->
        emit_fallback(signature, validation_err)
        corrective = corrective_message(signature, validation_err)

        case do_call_and_parse(signature, messages ++ [corrective], schema, opts) do
          {:ok, fields, usage, payload} ->
            {:ok, fields, usage, payload}

          {:retry, second_err} ->
            {:fallback,
             %FallbackExhausted{from: __MODULE__, to: __MODULE__, last_error: second_err}}

          {:lm_error, lm_err} ->
            {:fallback, lm_err}
        end

      {:lm_error, lm_err} ->
        {:fallback, lm_err}
    end
  end

  @doc """
  Build a `Zoi.object/1` schema from the signature's declared outputs.

  Used by predictors to feed the schema into `Dsxir.LM.generate_object/3`.
  """
  @spec output_schema(Dsxir.Adapter.signature()) :: Zoi.schema()
  def output_schema(signature) do
    fields = Runtime.outputs(signature)
    Zoi.object(Map.new(fields, &{&1.name, &1.zoi}))
  end

  defp do_call_and_parse(signature, messages, schema, opts) do
    lm_opts = Keyword.delete(opts, :instruction_override)

    case Dsxir.LM.generate_object(messages, schema, lm_opts) do
      {:ok, payload, usage} ->
        case parse(signature, payload, opts) do
          {:ok, fields} -> {:ok, fields, usage, payload}
          {:error, %ZoiValidation{} = err} -> {:retry, err}
        end

      {:error, lm_err} ->
        {:lm_error, lm_err}
    end
  end

  defp emit_fallback(signature, err) do
    Telemetry.emit(
      Telemetry.adapter_fallback(),
      %{system_time: System.system_time()},
      Map.merge(Settings.resolve(:metadata, %{}), %{
        from: __MODULE__,
        to: __MODULE__,
        signature: signature,
        reason: err
      })
    )
  end

  defp corrective_message(signature, %ZoiValidation{zoi_errors: zoi_errors}) do
    names =
      signature
      |> Runtime.outputs()
      |> Enum.map_join(", ", &Atom.to_string(&1.name))

    %{
      role: :user,
      content:
        "Previous response failed schema validation: #{inspect(zoi_errors)}. " <>
          "Return a JSON object whose keys are exactly #{names}, and whose values conform to the declared types."
    }
  end

  defp system_prompt(signature, opts) do
    instruction =
      case Keyword.get(opts, :instruction_override) do
        text when is_binary(text) and text != "" -> text
        _ -> Runtime.instruction(signature) || ""
      end

    instruction = append_hint(instruction, Keyword.get(opts, :hint))

    inputs_doc = render_field_list("Inputs:", Runtime.inputs(signature))
    outputs_doc = render_field_list("Outputs:", Runtime.outputs(signature))

    """
    #{instruction}

    Respond with a JSON object whose keys match the declared output fields.
    Each value must conform to the field's declared type.

    #{inputs_doc}
    #{outputs_doc}
    """
  end

  defp user_prompt(signature, inputs, demos) do
    demo_section = Enum.map_join(demos, "\n\n", &render_demo(signature, &1))

    input_section =
      Runtime.inputs(signature)
      |> Enum.map_join("\n", fn f ->
        "#{f.name}: #{render_value(Map.fetch!(inputs, f.name))}"
      end)

    if demo_section == "" do
      input_section
    else
      "Examples:\n\n#{demo_section}\n\nNow your turn:\n\n#{input_section}"
    end
  end

  defp append_hint(instruction, nil), do: instruction
  defp append_hint(instruction, ""), do: instruction

  defp append_hint(instruction, hint) when is_binary(hint),
    do: instruction <> "\n\nFeedback from a previous attempt:\n" <> hint

  defp render_field_list(_label, []), do: ""

  defp render_field_list(label, fields) do
    bullets =
      Enum.map_join(fields, "\n", fn f ->
        desc = if f.desc, do: " — #{f.desc}", else: ""
        "  - #{f.name}#{desc}"
      end)

    "#{label}\n#{bullets}"
  end

  defp render_demo(signature, %Dsxir.Demo{example: %Dsxir.Example{data: data}}),
    do: render_demo(signature, data)

  defp render_demo(signature, %Dsxir.Example{data: data}), do: render_demo(signature, data)

  defp render_demo(signature, demo) when is_map(demo) do
    Runtime.fields(signature)
    |> Enum.map_join("\n", fn f ->
      value = Map.get(demo, f.name)
      "#{f.name}: #{render_value(value)}"
    end)
  end

  defp render_value(v) when is_binary(v), do: v
  defp render_value(v), do: Jason.encode!(v)
end
