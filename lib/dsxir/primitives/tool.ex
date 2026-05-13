defmodule Dsxir.Primitives.Tool do
  @moduledoc """
  Value type describing a tool callable by `Dsxir.Predictor.ReAct`.

      %Dsxir.Primitives.Tool{
        name: "calculator",
        description: "Evaluate an arithmetic expression",
        parameters: Zoi.object(%{expression: Zoi.string()}),
        function: fn %{expression: expr} -> Code.eval_string(expr) |> elem(0) |> to_string() end
      }

  `parameters` is a Zoi schema. Arguments are validated through it before the
  function is invoked; a Zoi failure short-circuits without calling `:function`.

  `function` is a 1-arity callable returning a string-coercible value. Any
  exception raised inside the function is caught by `execute/2` and surfaced as
  an `Dsxir.Errors.Invalid.Tool` value with `reason: :execution_error` so the
  ReAct loop can route around it.

  `to_sycophant_tool/1` returns a `%Sycophant.Tool{}` with `function: nil` so
  Sycophant does not auto-execute the tool. dsxir owns the loop.
  """

  @derive {Inspect, except: [:function]}
  @enforce_keys [:name, :description, :parameters, :function]
  defstruct [:name, :description, :parameters, :function]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: Zoi.schema(),
          function: (map() -> any())
        }

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Validate `args` against the tool's Zoi schema and dispatch the function.

  Returns `{:ok, observation_string}` on success and `{:error, %Dsxir.Errors.Invalid.Tool{}}`
  on validation failure or function exception.
  """
  @spec execute(t(), map()) :: {:ok, String.t()} | {:error, Dsxir.Errors.Invalid.Tool.t()}
  def execute(%__MODULE__{parameters: schema, function: fun, name: name}, args)
      when is_map(args) and is_function(fun, 1) do
    case Zoi.parse(schema, args) do
      {:ok, validated} ->
        try do
          {:ok, validated |> fun.() |> to_string()}
        rescue
          e ->
            {:error,
             %Dsxir.Errors.Invalid.Tool{
               tool: name,
               reason: :execution_error,
               inner: Exception.format(:error, e, __STACKTRACE__)
             }}
        end

      {:error, zoi_errors} ->
        {:error,
         %Dsxir.Errors.Invalid.Tool{
           tool: name,
           reason: :argument_validation,
           inner: zoi_errors
         }}
    end
  end

  @doc "Build a `%Sycophant.Tool{}` shape; `function: nil` keeps Sycophant out of the loop."
  @spec to_sycophant_tool(t()) :: Sycophant.Tool.t()
  def to_sycophant_tool(%__MODULE__{} = tool) do
    %Sycophant.Tool{
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters,
      function: nil,
      schema_source: :zoi
    }
  end
end
