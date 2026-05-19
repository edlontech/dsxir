defmodule Dsxir.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    install_default_globals()

    children =
      [
        {Task.Supervisor, name: Dsxir.TaskSupervisor},
        Dsxir.History,
        Dsxir.OptimizerSession.Store.ETS,
        {Registry, keys: :unique, name: Dsxir.OptimizerSession.Registry},
        {DynamicSupervisor,
         name: Dsxir.OptimizerSession.DynamicSupervisor, strategy: :one_for_one}
      ] ++ dev_children()

    opts = [strategy: :one_for_one, name: Dsxir.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp install_default_globals do
    case :persistent_term.get({Dsxir.Settings, :globals}, :not_set) do
      :not_set ->
        :persistent_term.put({Dsxir.Settings, :globals}, Dsxir.Settings.default_globals())

      _existing ->
        :ok
    end
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
      Code.ensure_loaded?(Mix.Project) and Mix.Project.get() == Dsxir.MixProject
    end
  else
    defp dev_children, do: []
  end
end
