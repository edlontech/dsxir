defmodule Dsxir.ErrorsTest do
  use ExUnit.Case, async: true

  describe "Dsxir.Errors aggregator" do
    test "splode_error?/1 recognises each concrete class instance" do
      concretes = [
        %Dsxir.Errors.Halted.Plug{plug: :p, reason: :r, context: nil},
        %Dsxir.Errors.Invalid.Configuration{key: :k, value: :v, reason: :r},
        %Dsxir.Errors.Adapter.ParseError{adapter: :a, field: :f, reason: :r, raw_response: ""},
        %Dsxir.Errors.LM.RequestFailed{model_id: "x", status: 500, parent_error: nil},
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

  describe "class_of/1" do
    test "returns the class atom from a Splode struct" do
      err = %Dsxir.Errors.Adapter.ParseError{
        adapter: :chat,
        field: :x,
        reason: :no_markers,
        raw_response: ""
      }

      assert Dsxir.Errors.class_of(err) == :adapter
    end

    test "returns the class atom for LM-class errors" do
      err = %Dsxir.Errors.LM.RequestFailed{model_id: "m", status: 500, parent_error: nil}
      assert Dsxir.Errors.class_of(err) == :lm
    end

    test "returns the class atom for Invalid-class errors" do
      err = %Dsxir.Errors.Invalid.Configuration{key: :k, value: :v, reason: :r}
      assert Dsxir.Errors.class_of(err) == :invalid
    end

    test "returns :unknown for a non-exception value" do
      assert Dsxir.Errors.class_of(:not_an_error) == :unknown
      assert Dsxir.Errors.class_of(%{}) == :unknown
      assert Dsxir.Errors.class_of(nil) == :unknown
    end
  end

  describe "Framework.CodeExecutionError" do
    test "carries type, message, code, trajectory and renders a message" do
      err = %Dsxir.Errors.Framework.CodeExecutionError{
        type: :max_iters,
        message: "all attempts failed",
        code: "x = 1",
        trajectory: [%{code: "x = 1", error: "boom", ok?: false}]
      }

      assert Dsxir.Errors.class_of(err) == :framework
      assert Exception.message(err) =~ "max_iters"
      assert Exception.message(err) =~ "all attempts failed"
    end
  end

  describe "message/1 produces readable strings" do
    test "Adapter.ParseError with field" do
      err = %Dsxir.Errors.Adapter.ParseError{
        adapter: Dsxir.Adapter.Chat,
        field: :answer,
        reason: :missing_field,
        raw_response: ""
      }

      msg = Exception.message(err)
      assert msg =~ "parse failed"
      assert msg =~ "field=:answer"
      assert msg =~ "reason=:missing_field"
    end

    test "Adapter.ParseError omits field segment when field is nil" do
      err = %Dsxir.Errors.Adapter.ParseError{
        adapter: Dsxir.Adapter.Chat,
        field: nil,
        reason: :no_markers,
        raw_response: ""
      }

      msg = Exception.message(err)
      assert msg =~ "parse failed"
      assert msg =~ "reason=:no_markers"
      refute msg =~ "field="
    end

    test "Adapter.ZoiValidation" do
      err = %Dsxir.Errors.Adapter.ZoiValidation{
        adapter: Dsxir.Adapter.Chat,
        field: :ranked,
        zoi_errors: [:bad]
      }

      msg = Exception.message(err)
      assert msg =~ "Zoi validation failed"
      assert msg =~ ":ranked"
    end

    test "Adapter.FallbackExhausted" do
      last =
        %Dsxir.Errors.Adapter.ParseError{
          adapter: Dsxir.Adapter.Chat,
          field: :answer,
          reason: :missing_field,
          raw_response: ""
        }

      err = %Dsxir.Errors.Adapter.FallbackExhausted{
        from: Dsxir.Adapter.Chat,
        to: Dsxir.Adapter.Json,
        last_error: last
      }

      msg = Exception.message(err)
      assert msg =~ "fallback"
      assert msg =~ "exhausted"
      assert msg =~ "parse failed"
    end

    test "Adapter.FallbackExhausted with non-exception last_error returns a string" do
      atom_err = %Dsxir.Errors.Adapter.FallbackExhausted{
        from: Dsxir.Adapter.Chat,
        to: Dsxir.Adapter.Json,
        last_error: :raw_atom
      }

      atom_msg = Exception.message(atom_err)
      assert is_binary(atom_msg)
      assert atom_msg =~ "fallback"
      assert atom_msg =~ "exhausted"
      assert atom_msg =~ ":raw_atom"

      nil_err = %Dsxir.Errors.Adapter.FallbackExhausted{
        from: Dsxir.Adapter.Chat,
        to: Dsxir.Adapter.Json,
        last_error: nil
      }

      nil_msg = Exception.message(nil_err)
      assert is_binary(nil_msg)
      assert nil_msg =~ "fallback"
      assert nil_msg =~ "exhausted"
      assert nil_msg =~ "nil"
    end

    test "LM.RequestFailed" do
      err = %Dsxir.Errors.LM.RequestFailed{
        model_id: "gpt-4",
        status: 500,
        parent_error: :timeout
      }

      msg = Exception.message(err)
      assert msg =~ "LM"
      assert msg =~ "gpt-4"
      assert msg =~ "status=500"
      assert msg =~ ":timeout"
    end

    test "LM.RateLimited" do
      err = %Dsxir.Errors.LM.RateLimited{model_id: "gpt-4", retry_after: 5}
      msg = Exception.message(err)
      assert msg =~ "gpt-4"
      assert msg =~ "rate-limited"
      assert msg =~ "retry_after=5"
    end

    test "LM.Authentication" do
      err = %Dsxir.Errors.LM.Authentication{model_id: "gpt-4", reason: :missing_key}
      msg = Exception.message(err)
      assert msg =~ "gpt-4"
      assert msg =~ "authentication failed"
      assert msg =~ ":missing_key"
    end

    test "Invalid.Configuration" do
      err = %Dsxir.Errors.Invalid.Configuration{key: :lm, value: nil, reason: :missing}
      msg = Exception.message(err)
      assert msg =~ "invalid configuration"
      assert msg =~ "key=:lm"
      assert msg =~ "reason=:missing"
    end

    test "Invalid.Signature" do
      err = %Dsxir.Errors.Invalid.Signature{module: MySig, field: :x, reason: :unknown_type}
      msg = Exception.message(err)
      assert msg =~ "invalid signature"
      assert msg =~ "MySig"
      assert msg =~ ":x"
    end

    test "Invalid.Module" do
      err = %Dsxir.Errors.Invalid.Module{
        module: MyMod,
        predictor: :missing,
        reason: :undeclared_predictor
      }

      msg = Exception.message(err)
      assert msg =~ "invalid module"
      assert msg =~ "MyMod"
      assert msg =~ ":missing"
    end

    test "Invalid.SignatureMismatch" do
      err = %Dsxir.Errors.Invalid.SignatureMismatch{
        module: MyMod,
        expected: %{},
        loaded: %{},
        diff: [added: [:x]]
      }

      msg = Exception.message(err)
      assert msg =~ "signature mismatch"
      assert msg =~ "MyMod"
      assert msg =~ ":x"
    end

    test "Invalid.Trainset" do
      err = %Dsxir.Errors.Invalid.Trainset{reason: :empty, example: nil}
      msg = Exception.message(err)
      assert msg =~ "invalid trainset"
      assert msg =~ ":empty"
    end

    test "Invalid.Metric" do
      err = %Dsxir.Errors.Invalid.Metric{
        example: %{a: 1},
        returned: :wat,
        expected: "a float or boolean"
      }

      msg = Exception.message(err)
      assert msg =~ "invalid metric"
      assert msg =~ ":wat"
    end

    test "Framework.UndefinedFunction" do
      err = %Dsxir.Errors.Framework.UndefinedFunction{
        module: MyApp.Metric,
        function: :score,
        arity: 3
      }

      assert Dsxir.Errors.class_of(err) == :framework

      msg = Exception.message(err)
      assert msg =~ "undefined function"
      assert msg =~ "MyApp.Metric"
      assert msg =~ "score/3"
    end
  end
end
