defmodule Mix.Tasks.Dsxir.Check.NoEvalTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Dsxir.Check.NoEval

  describe "scan_path_explicit/1" do
    @tag :tmp_dir
    test "returns [] for clean file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "clean.ex")
      File.write!(path, "defmodule Clean do\n  def hello, do: :world\nend\n")
      assert NoEval.scan_path_explicit(path) == []
    end

    @tag :tmp_dir
    test "reports Code.eval_string hit with file and line", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.ex")
      File.write!(path, "defmodule Bad do\n  Code.eval_string(\"x\")\nend\n")
      assert [{^path, 2, "Code.eval_string"}] = NoEval.scan_path_explicit(path)
    end

    @tag :tmp_dir
    test "reports Code.eval_quoted hit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.ex")
      File.write!(path, "defmodule Bad do\n  Code.eval_quoted(quote do: 1)\nend\n")
      assert [{^path, 2, "Code.eval_quoted"}] = NoEval.scan_path_explicit(path)
    end

    @tag :tmp_dir
    test "reports Code.compile_string hit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.ex")
      File.write!(path, "defmodule Bad do\n  Code.compile_string(\"x\")\nend\n")
      assert [{^path, 2, "Code.compile_string"}] = NoEval.scan_path_explicit(path)
    end

    @tag :tmp_dir
    test "reports Code.compile_quoted hit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.ex")
      File.write!(path, "defmodule Bad do\n  Code.compile_quoted(quote do: 1)\nend\n")
      assert [{^path, 2, "Code.compile_quoted"}] = NoEval.scan_path_explicit(path)
    end

    @tag :tmp_dir
    test "reports Module.create hit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.ex")
      File.write!(path, "defmodule Bad do\n  Module.create(Foo, quote(do: nil), __ENV__)\nend\n")
      assert [{^path, 2, "Module.create"}] = NoEval.scan_path_explicit(path)
    end

    @tag :tmp_dir
    test "reports :erl_eval hit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.ex")
      File.write!(path, "defmodule Bad do\n  :erl_eval.expr(nil, [])\nend\n")
      assert [{^path, 2, ":erl_eval"}] = NoEval.scan_path_explicit(path)
    end

    @tag :tmp_dir
    test "reports String.to_atom hit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.ex")
      File.write!(path, "defmodule Bad do\n  def x(s), do: String.to_atom(s)\nend\n")
      assert [{^path, 2, "String.to_atom"}] = NoEval.scan_path_explicit(path)
    end

    @tag :tmp_dir
    test "reports multiple hits across lines in one file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.ex")

      File.write!(path, """
      defmodule Bad do
        Code.eval_string("x")
        def y(s), do: String.to_atom(s)
      end
      """)

      hits = NoEval.scan_path_explicit(path)
      assert {^path, 2, "Code.eval_string"} = Enum.find(hits, &match?({_, 2, _}, &1))
      assert {^path, 3, "String.to_atom"} = Enum.find(hits, &match?({_, 3, _}, &1))
    end

    @tag :tmp_dir
    test "scans every *.ex file in a directory", %{tmp_dir: tmp_dir} do
      sub = Path.join(tmp_dir, "nested")
      File.mkdir_p!(sub)
      a = Path.join(sub, "a.ex")
      b = Path.join(sub, "b.ex")
      File.write!(a, "defmodule A do\n  String.to_atom(\"x\")\nend\n")
      File.write!(b, "defmodule B do\n  def ok, do: :ok\nend\n")

      hits = NoEval.scan_path_explicit(sub)
      assert [{^a, 2, "String.to_atom"}] = hits
    end

    @tag :tmp_dir
    test "ignores non-existent path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.ex")
      assert NoEval.scan_path_explicit(path) == []
    end

    @tag :tmp_dir
    test "String.to_existing_atom is allowed (does not match String.to_atom)",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ok.ex")
      File.write!(path, "defmodule Ok do\n  def x(s), do: String.to_existing_atom(s)\nend\n")
      # The literal substring "String.to_atom" does NOT appear in "String.to_existing_atom"
      assert NoEval.scan_path_explicit(path) == []
    end
  end

  describe "scan_all/0" do
    test "current dsxir codebase is clean (acceptance criterion)" do
      assert NoEval.scan_all() == []
    end
  end
end
