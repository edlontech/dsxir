defmodule Dsxir.DemoStrategy do
  @moduledoc """
  Marker module for per-call demo resolution strategies. v1 ships a single
  strategy (`Dsxir.DemoStrategy.KNN`); the runtime hook in
  `Dsxir.Module.Runtime.call/4` dispatches via a `case` over the struct.

  A future `@behaviour Dsxir.DemoStrategy` with `resolve/3` is the natural
  generalization when a second concrete strategy lands (MMR, rerank). v1
  keeps it as a struct union per the design.
  """

  @typedoc "Union of all demo-resolution strategy structs."
  @type t :: Dsxir.DemoStrategy.KNN.t()
end
