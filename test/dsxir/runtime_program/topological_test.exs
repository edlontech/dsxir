defmodule Dsxir.RuntimeProgram.TopologicalTest do
  use ExUnit.Case, async: true

  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.Node, as: RPNode
  alias Dsxir.RuntimeProgram.Topological

  defp rp_node(name), do: %RPNode{name: name, impl: __MODULE__, signature: __MODULE__}

  test "empty graph returns an empty order" do
    assert {:ok, []} = Topological.sort([], [])
  end

  test "single node with no edges returns that node" do
    assert {:ok, [:a]} = Topological.sort([rp_node(:a)], [])
  end

  test "linear chain A -> B -> C produces topological order" do
    nodes = [rp_node(:a), rp_node(:b), rp_node(:c)]

    edges = [
      %Edge{from: {:node, :a, :out}, to: {:node, :b, :in}},
      %Edge{from: {:node, :b, :out}, to: {:node, :c, :in}}
    ]

    assert {:ok, order} = Topological.sort(nodes, edges)
    assert Enum.find_index(order, &(&1 == :a)) < Enum.find_index(order, &(&1 == :b))
    assert Enum.find_index(order, &(&1 == :b)) < Enum.find_index(order, &(&1 == :c))
  end

  test "non-node edges (program_input/program_output/const) do not create dependencies" do
    nodes = [rp_node(:a), rp_node(:b)]

    edges = [
      %Edge{from: {:program_input, :q}, to: {:node, :a, :question}},
      %Edge{from: {:program_input, :q}, to: {:node, :b, :question}},
      %Edge{from: {:node, :a, :answer}, to: {:program_output, :answer}},
      %Edge{from: {:const, "x"}, to: {:node, :b, :hint}}
    ]

    assert {:ok, order} = Topological.sort(nodes, edges)
    assert Enum.sort(order) == [:a, :b]
  end

  test "cycle is reported with the offending node names" do
    nodes = [rp_node(:a), rp_node(:b)]

    edges = [
      %Edge{from: {:node, :a, :out}, to: {:node, :b, :in}},
      %Edge{from: {:node, :b, :out}, to: {:node, :a, :in}}
    ]

    assert {:error, {:cycle, cyclic}} = Topological.sort(nodes, edges)
    assert Enum.sort(cyclic) == [:a, :b]
  end

  test "diamond A -> {B,C} -> D yields a valid topological order" do
    nodes = [rp_node(:a), rp_node(:b), rp_node(:c), rp_node(:d)]

    edges = [
      %Edge{from: {:node, :a, :out}, to: {:node, :b, :in}},
      %Edge{from: {:node, :a, :out}, to: {:node, :c, :in}},
      %Edge{from: {:node, :b, :out}, to: {:node, :d, :left}},
      %Edge{from: {:node, :c, :out}, to: {:node, :d, :right}}
    ]

    assert {:ok, order} = Topological.sort(nodes, edges)
    idx = fn n -> Enum.find_index(order, &(&1 == n)) end
    assert idx.(:a) < idx.(:b)
    assert idx.(:a) < idx.(:c)
    assert idx.(:b) < idx.(:d)
    assert idx.(:c) < idx.(:d)
  end

  test "linear chain of 100 nodes sorts in correct topological order" do
    names = for i <- 0..99, do: :"n#{i}"
    nodes = Enum.map(names, &rp_node/1)

    edges =
      for i <- 0..98 do
        %Edge{
          from: {:node, :"n#{i}", :out},
          to: {:node, :"n#{i + 1}", :in}
        }
      end

    assert {:ok, ^names} = Topological.sort(nodes, edges)
  end

  test "wide layered DAG (50+ nodes) respects all edges" do
    layer_size = 6
    layer_count = 10
    total = layer_size * layer_count

    names =
      for layer <- 0..(layer_count - 1),
          j <- 0..(layer_size - 1),
          do: :"l#{layer}_#{j}"

    assert length(names) == total
    nodes = Enum.map(names, &rp_node/1)

    edges =
      for layer <- 0..(layer_count - 2),
          src_j <- 0..(layer_size - 1),
          dst_j <- 0..(layer_size - 1) do
        %Edge{
          from: {:node, :"l#{layer}_#{src_j}", :out},
          to: {:node, :"l#{layer + 1}_#{dst_j}", :in}
        }
      end

    assert {:ok, order} = Topological.sort(nodes, edges)
    assert Enum.sort(order) == Enum.sort(names)

    layer_of = fn name ->
      [layer_str, _] =
        name
        |> Atom.to_string()
        |> String.trim_leading("l")
        |> String.split("_")

      String.to_integer(layer_str)
    end

    order_index = Map.new(Enum.with_index(order))

    Enum.each(edges, fn %Edge{from: {:node, src, _}, to: {:node, dst, _}} ->
      assert order_index[src] < order_index[dst]
      assert layer_of.(src) < layer_of.(dst)
    end)
  end
end
