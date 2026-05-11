defmodule Dsxir.LM.SycophantTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.LM.Sycophant, as: Impl

  setup :set_mimic_from_context

  test "generate_text/3 returns the response text on success" do
    expect(Sycophant, :generate_text, fn "openai:gpt-4o-mini", _msgs, _opts ->
      {:ok, %Sycophant.Response{text: "hello", context: %Sycophant.Context{messages: []}}}
    end)

    assert {:ok, "hello"} =
             Impl.generate_text(
               [model: "openai:gpt-4o-mini"],
               [Sycophant.Message.user("hi")],
               []
             )
  end

  test "generate_text/3 lifts api_key/base_url into credentials" do
    expect(Sycophant, :generate_text, fn _model, _msgs, opts ->
      assert opts[:credentials] == %{api_key: "sk-test", base_url: "https://example.test"}
      refute Keyword.has_key?(opts, :api_key)
      refute Keyword.has_key?(opts, :base_url)
      {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
    end)

    Impl.generate_text(
      [model: "m", api_key: "sk-test", base_url: "https://example.test"],
      [],
      []
    )
  end

  test "per-call opts override config opts" do
    expect(Sycophant, :generate_text, fn _model, _msgs, opts ->
      assert opts[:temperature] == 0.0
      {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
    end)

    Impl.generate_text(
      [model: "m", temperature: 0.7],
      [],
      temperature: 0.0
    )
  end

  test "translates AuthenticationFailed to Dsxir.Errors.LM.Authentication" do
    err = %Sycophant.Error.Provider.AuthenticationFailed{status: 401, body: "nope"}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.Authentication{model_id: "m", reason: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates RateLimited preserving retry_after" do
    err = %Sycophant.Error.Provider.RateLimited{retry_after: 30}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RateLimited{retry_after: 30}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates ServerError preserving status" do
    err = %Sycophant.Error.Provider.ServerError{status: 503, body: "down"}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{status: 503}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates BadRequest preserving status" do
    err = %Sycophant.Error.Provider.BadRequest{status: 400, body: "nope"}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{status: 400}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates Timeout to RequestFailed with nil status" do
    err = %Sycophant.Error.Provider.Timeout{reason: :etimeout}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{status: nil, sycophant_error: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates ResponseInvalid to RequestFailed with nil status" do
    err = %Sycophant.Error.Provider.ResponseInvalid{errors: ["bad"], raw: %{}}

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{status: nil, sycophant_error: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates ContentFiltered into RequestFailed preserving the upstream error" do
    err = Sycophant.Error.Provider.ContentFiltered.exception(reason: "policy")

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{model_id: "m", sycophant_error: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates ModelNotFound into RequestFailed preserving the upstream error" do
    err = Sycophant.Error.Provider.ModelNotFound.exception(model: "m")

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{model_id: "m", sycophant_error: ^err}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "translates MissingCredentials to Authentication{reason: :missing_credentials}" do
    err = Sycophant.Error.Invalid.MissingCredentials.exception(provider: :openai)

    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, %Dsxir.Errors.LM.Authentication{reason: :missing_credentials, model_id: "m"}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "falls back to generic RequestFailed for unrecognised errors" do
    expect(Sycophant, :generate_text, fn _, _, _ -> {:error, :wat} end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{sycophant_error: :wat}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "Response{text: nil} maps to RequestFailed{sycophant_error: :empty_response}" do
    expect(Sycophant, :generate_text, fn _, _, _ ->
      {:ok, %Sycophant.Response{text: nil, context: %Sycophant.Context{messages: []}}}
    end)

    assert {:error, %Dsxir.Errors.LM.RequestFailed{sycophant_error: :empty_response}} =
             Impl.generate_text([model: "m"], [], [])
  end

  test "drops :headers from sycophant opts" do
    expect(Sycophant, :generate_text, fn _model, _msgs, opts ->
      refute Keyword.has_key?(opts, :headers)
      {:ok, %Sycophant.Response{text: "ok", context: %Sycophant.Context{messages: []}}}
    end)

    Impl.generate_text(
      [model: "m", headers: [{"x-foo", "bar"}]],
      [],
      []
    )
  end
end
