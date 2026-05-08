defmodule Dsxir.Application do
  @moduledoc false

  use Application

  @doc false
  @impl true
  def start(_type, _args) do
    children =
      dev_children()

    opts = [strategy: :one_for_one, name: Dsxir.Supervisor]
    Supervisor.start_link(children, opts)
  end

  if Mix.env() == :dev do
    defp dev_children do
      if top_level_project?() and System.get_env("TIDEWAVE_REPL") == "true" and
           Code.ensure_loaded?(Bandit) do
        Application.ensure_all_started(:tidewave)
        port = String.to_integer(System.get_env("TIDEWAVE_PORT", "10001"))
        [{Bandit, plug: Tidewave, port: port}]
      else
        []
      end
    end

    defp top_level_project? do
      Code.ensure_loaded?(Mix.Project) and apply(Mix.Project, :get, []) == Dsxir.MixProject
    end
  else
    def dev_children, do: []
  end
end
