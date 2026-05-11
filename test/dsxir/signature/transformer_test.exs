defmodule Dsxir.Signature.TransformerTest do
  use ExUnit.Case, async: true

  alias Dsxir.Test.Fixtures.RankItems

  test "shorthand atoms expand to Zoi schemas" do
    {:ok, query_zoi} = Dsxir.Signature.Runtime.zoi_for(RankItems, :query)
    {:ok, conf_zoi} = Dsxir.Signature.Runtime.zoi_for(RankItems, :confidence)
    {:ok, items_zoi} = Dsxir.Signature.Runtime.zoi_for(RankItems, :items)

    assert Zoi.parse(query_zoi, "hello") == {:ok, "hello"}
    assert Zoi.parse(conf_zoi, 0.9) == {:ok, 0.9}
    assert Zoi.parse(items_zoi, ["a", "b"]) == {:ok, ["a", "b"]}
  end

  test "unknown shorthand raises Invalid.Signature at compile time" do
    assert_raise Dsxir.Errors.Invalid.Signature, fn ->
      defmodule BadSig do
        use Dsxir.Signature

        signature do
          input(:weird, :not_a_type)
          output(:answer, :string)
        end
      end
    end
  end

  test "duplicate field names raise Invalid.Signature at compile time" do
    assert_raise Dsxir.Errors.Invalid.Signature, fn ->
      defmodule DupSig do
        use Dsxir.Signature

        signature do
          input(:x, :string)
          input(:x, :integer)
          output(:answer, :string)
        end
      end
    end
  end

  test "raw Zoi schema is accepted unchanged" do
    defmodule RawZoiSig do
      use Dsxir.Signature

      signature do
        input(:q, Zoi.string())
        output(:a, :string)
      end
    end

    {:ok, zoi} = Dsxir.Signature.Runtime.zoi_for(RawZoiSig, :q)
    assert Zoi.parse(zoi, "x") == {:ok, "x"}
  end

  test "{:list, Zoi.schema()} is accepted unchanged" do
    defmodule ListZoiSig do
      use Dsxir.Signature

      signature do
        input(:xs, {:list, Zoi.string()})
        output(:a, :string)
      end
    end

    {:ok, zoi} = Dsxir.Signature.Runtime.zoi_for(ListZoiSig, :xs)
    assert Zoi.parse(zoi, ["a", "b"]) == {:ok, ["a", "b"]}
  end

  test "nested list shorthand expands recursively" do
    defmodule NestedListSig do
      use Dsxir.Signature

      signature do
        input(:matrix, {:list, {:list, :integer}})
        output(:a, :string)
      end
    end

    {:ok, zoi} = Dsxir.Signature.Runtime.zoi_for(NestedListSig, :matrix)
    assert Zoi.parse(zoi, [[1, 2], [3]]) == {:ok, [[1, 2], [3]]}
  end

  test "non-Zoi struct is rejected at compile time" do
    assert_raise Dsxir.Errors.Invalid.Signature, fn ->
      defmodule BadStructSig do
        use Dsxir.Signature

        signature do
          input(:weird, %URI{})
          output(:a, :string)
        end
      end
    end
  end

  test "duplicate output field names raise Invalid.Signature at compile time" do
    assert_raise Dsxir.Errors.Invalid.Signature, fn ->
      defmodule DupOutputSig do
        use Dsxir.Signature

        signature do
          input(:q, :string)
          output(:a, :string)
          output(:a, :integer)
        end
      end
    end
  end
end
