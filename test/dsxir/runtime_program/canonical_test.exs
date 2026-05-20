defmodule Dsxir.RuntimeProgram.CanonicalTest do
  use ExUnit.Case, async: true

  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Canonical
  alias Dsxir.Test.Fixtures.RuntimeProgramPayloads

  test "same logical content yields the same version" do
    payload = RuntimeProgramPayloads.minimal()
    rp1 = RuntimeProgram.parse(payload)
    rp2 = RuntimeProgram.parse(payload)
    assert rp1.version == rp2.version
  end

  test "differing metadata.description does NOT change the version" do
    base = RuntimeProgramPayloads.minimal()
    a = RuntimeProgram.parse(put_in(base, ["metadata", "description"], "foo"))
    b = RuntimeProgram.parse(put_in(base, ["metadata", "description"], "bar"))
    assert a.version == b.version
  end

  test "swapping node order DOES change the version (order is semantic)" do
    base = RuntimeProgramPayloads.minimal()
    swapped = update_in(base, ["nodes"], &Enum.reverse/1)
    a = RuntimeProgram.parse(base)
    b = RuntimeProgram.parse(swapped)
    assert a.version != b.version
  end

  test "changing an edge kind from required to optional changes the version" do
    base = RuntimeProgramPayloads.minimal()

    flipped =
      update_in(base, ["edges"], fn [e | rest] -> [Map.put(e, "kind", "optional") | rest] end)

    a = RuntimeProgram.parse(base)
    b = RuntimeProgram.parse(flipped)
    assert a.version != b.version
  end

  test "Canonical.encode/1 produces iodata that flattens to a binary" do
    rp = RuntimeProgram.parse(RuntimeProgramPayloads.minimal())
    iodata = Canonical.encode(rp)
    assert is_binary(IO.iodata_to_binary(iodata))
  end

  test "FieldSpec description is non-semantic — different desc, same version" do
    base = RuntimeProgramPayloads.minimal()

    described =
      update_in(base, ["inputs"], fn [field | rest] ->
        [Map.put(field, "description", "the user's question") | rest]
      end)

    a = RuntimeProgram.parse(base)
    b = RuntimeProgram.parse(described)
    assert a.version == b.version
  end

  defmodule StructA do
    @moduledoc false
    defstruct [:label, :count]
  end

  defmodule StructB do
    @moduledoc false
    defstruct [:label, :count]
  end

  test "two distinct structs with identical fields encode to different bytes" do
    a = %StructA{label: "x", count: 1}
    b = %StructB{label: "x", count: 1}

    bin_a = IO.iodata_to_binary(Canonical.encode_term_for_test(a))
    bin_b = IO.iodata_to_binary(Canonical.encode_term_for_test(b))

    assert bin_a != bin_b
  end
end
