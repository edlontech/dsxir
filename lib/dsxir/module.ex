defmodule Dsxir.Module do
  @moduledoc """
  Declarative user-program shell.

      defmodule MyApp.MeetingNotes do
        use Dsxir.Module

        predictor :answer, Dsxir.Predictor.Predict, signature: MyApp.AnswerQuestion

        def forward(prog, %{question: q}) do
          {prog, pred} = call(prog, :answer, %{question: q})
          {prog, pred}
        end
      end

  Inside `forward/2`, `call(prog, :name, inputs)` dispatches through
  `Dsxir.Module.Runtime`. Predictor names referenced in `call/3` must be
  declared via the `predictor` entity above; the compile-time verifier
  catches typos. Non-literal predictor names (variables, dynamic dispatch)
  bypass the static check and are validated at runtime.
  """

  use Spark.Dsl, default_extensions: [extensions: [Dsxir.Module.Dsl]]

  defmacro __using__(opts) do
    spark_using = super(opts)

    quote do
      unquote(spark_using)

      Module.register_attribute(__MODULE__, :dsxir_calls, accumulate: true)
      @before_compile Dsxir.Module.Verifier

      import Dsxir.Module, only: [call: 3, call: 4]
    end
  end

  defmacro call(prog, name, inputs) when is_atom(name) do
    Module.put_attribute(__CALLER__.module, :dsxir_calls, name)

    quote do
      Dsxir.Module.Runtime.call(unquote(prog), unquote(name), unquote(inputs), [])
    end
  end

  defmacro call(prog, name, inputs) do
    quote do
      Dsxir.Module.Runtime.call(unquote(prog), unquote(name), unquote(inputs), [])
    end
  end

  defmacro call(prog, name, inputs, opts) when is_atom(name) do
    Module.put_attribute(__CALLER__.module, :dsxir_calls, name)

    quote do
      Dsxir.Module.Runtime.call(unquote(prog), unquote(name), unquote(inputs), unquote(opts))
    end
  end

  defmacro call(prog, name, inputs, opts) do
    quote do
      Dsxir.Module.Runtime.call(unquote(prog), unquote(name), unquote(inputs), unquote(opts))
    end
  end
end
