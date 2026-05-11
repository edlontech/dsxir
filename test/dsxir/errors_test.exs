defmodule Dsxir.ErrorsTest do
  use ExUnit.Case, async: true

  describe "Dsxir.Errors aggregator" do
    test "splode_error?/1 recognises each concrete class instance" do
      concretes = [
        %Dsxir.Errors.Halted.Plug{plug: :p, reason: :r, context: nil},
        %Dsxir.Errors.Invalid.Configuration{key: :k, value: :v, reason: :r},
        %Dsxir.Errors.Adapter.ParseError{adapter: :a, field: :f, reason: :r, raw_response: ""},
        %Dsxir.Errors.LM.RequestFailed{model_id: "x", status: 500, sycophant_error: nil},
        %Dsxir.Errors.Framework.PredictorError{predictor: :p, signature: :s, inner: nil},
        %Dsxir.Errors.Unknown.Unknown{error: :anything}
      ]

      for e <- concretes do
        assert Dsxir.Errors.splode_error?(e)
        assert is_exception(e)
      end
    end

    test "to_class/2 lifts a concrete error into its class struct" do
      err = %Dsxir.Errors.Adapter.ParseError{
        adapter: :chat,
        field: :x,
        reason: :no_markers,
        raw_response: ""
      }

      class = Dsxir.Errors.to_class(err)
      assert %Dsxir.Errors.Adapter{} = class
      assert [%Dsxir.Errors.Adapter.ParseError{}] = class.errors
    end

    test "to_error/1 wraps an unrecognised value as Unknown.Unknown" do
      assert %Dsxir.Errors.Unknown.Unknown{} = Dsxir.Errors.to_error(:not_an_error)
    end
  end
end
