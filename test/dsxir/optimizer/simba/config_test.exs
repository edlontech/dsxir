defmodule Dsxir.Optimizer.SIMBA.ConfigTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors
  alias Dsxir.Example
  alias Dsxir.Optimizer.SIMBA.Auto
  alias Dsxir.Optimizer.SIMBA.Config
  alias Dsxir.Settings

  defp examples(n), do: Enum.map(1..n, &Example.new(%{x: &1}, input_keys: [:x]))

  describe "Auto.expand/2" do
    test "medium preset yields documented values" do
      cfg = Auto.expand([], :medium)
      assert cfg.bsize == 32
      assert cfg.num_candidates == 6
      assert cfg.max_steps == 8
      assert cfg.max_demos == 4
    end

    test "single-key override changes only that key" do
      cfg = Auto.expand([bsize: 10], :light)
      assert cfg.bsize == 10
      assert cfg.num_candidates == 4
      assert cfg.max_steps == 4
      assert cfg.max_demos == 3
    end
  end

  describe "Config.validate/2" do
    setup do
      {:ok, base: Auto.expand([], :medium)}
    end

    test "empty trainset returns :empty error", %{base: base} do
      assert {:error, %Errors.Invalid.Trainset{reason: :empty}} = Config.validate(base, [])
    end

    test "trainset shorter than bsize returns :too_small error", %{base: base} do
      assert {:error, %Errors.Invalid.Trainset{reason: :too_small}} =
               Config.validate(base, examples(10))
    end

    test "valid trainset returns resolved config with defaults filled", %{base: base} do
      assert {:ok, cfg} = Config.validate(base, examples(50))
      assert cfg.bsize == 32
      assert cfg.temperature_for_sampling == 0.2
      assert cfg.temperature_for_candidates == 0.2
      assert cfg.sampling_temperature == 1.0
      assert cfg.demo_input_field_maxlen == 100_000
      assert cfg.num_threads == 4
    end

    test "reflective_lm defaults to Settings.resolve(:lm)", %{base: base} do
      {:ok, cfg} = Config.validate(base, examples(50))
      assert cfg.reflective_lm == Settings.resolve(:lm)
    end
  end
end
