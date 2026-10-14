defmodule Meerkat.CljfmtTest do
  # Swaps PATH.
  use Meerkat.Case, async: false

  import ExUnit.CaptureIO

  alias Meerkat.Cljfmt

  @hook "clj-paren-repair-claude-hook"
  @installed System.find_executable(@hook)

  @file_text """
  (defn f [x]
    (let [y 1]
      (+ x
         y)))
  """

  describe "context/3" do
    test "holds the lines around the anchor, so they join its lines back into the file" do
      {above, below} = Cljfmt.context("one\ntwo\nthree\nfour\n", 2, 3)
      assert {above, below} == {"one\n", "\nfour\n"}
      assert above <> "two\nthree" <> below == "one\ntwo\nthree\nfour\n"
    end

    test "is empty before the first line and after the last" do
      assert Cljfmt.context("a\nb", 1, 2) == {"", ""}
    end
  end

  # A hook stand-in that rewrites the file by `repair` and, when asked
  # to format, then by `format`; and records what each run read.
  defp fake(repair, format \\ & &1) do
    test_pid = self()

    fn path, cljfmt? ->
      text = File.read!(path)
      send(test_pid, {:ran, cljfmt?, text})
      File.write!(path, if(cljfmt?, do: format.(text), else: repair.(text)))
    end
  end

  defp replace(from, to), do: &String.replace(&1, from, to)

  describe "format_with/4" do
    test "formats the suggestion inside the file around it and cuts it back out" do
      {above, below} = Cljfmt.context(@file_text, 3, 4)
      code = "    (* x\n  y)))"

      run = fake(& &1, replace("(* x\n  y)))", "(* x\n       y)))"))

      assert Cljfmt.format_with(code, above, below, run) == "    (* x\n       y)))"
      assert_received {:ran, false, text}
      assert text == above <> code <> below
      assert_received {:ran, true, ^text}
    end

    test "formats the repaired suggestion" do
      code = "(f x"
      run = fake(replace("(f x", "(f x)"), replace("(f x)", "(f  x)"))

      assert Cljfmt.format_with(code, "(a)\n", "\n(b)\n", run) == "(f  x)"
      assert_received {:ran, true, "(a)\n(f x)\n(b)\n"}
    end

    test "keeps the suggestion's blank lines at either end" do
      run = fake(& &1, replace("(f  x)", "(f x)"))

      assert Cljfmt.format_with("\n  \n(f  x)\n\n", "(a)\n", "\n(b)", run) == "\n\n(f x)\n\n"
    end

    test "keeps blank lines inside the suggestion" do
      run = fake(& &1)
      assert Cljfmt.format_with("(f)\n\n(g)", "(a)\n", "\n(b)", run) == "(f)\n\n(g)"
    end

    test "formats a suggestion with nothing around it" do
      run = fake(& &1, replace("(f  x)", "(f x)"))
      assert Cljfmt.format_with("(f  x)", "", "", run) == "(f x)"
    end

    test "keeps the suggestion when the repair changes the lines above or below it" do
      code = "(f x"
      assert Cljfmt.format_with(code, "(a\n", "\n(b)", fake(replace("(a\n", "(a)\n"))) == code
      assert Cljfmt.format_with(code, "(a)\n", "\n(b", fake(replace("\n(b", "\n(b)"))) == code
      # A repair that empties the file leaves nothing to cut out.
      assert Cljfmt.format_with(code, "(a)\n", "\n(b)", fake(fn _ -> "" end)) == code
    end

    test "keeps the suggestion when formatting joins it with a line around it" do
      code = "x)"
      join_above = fake(& &1, replace("(f\n", "(f "))
      assert Cljfmt.format_with(code, "(f\n", "\n(g)", join_above) == code

      code = "(f x"
      join_below = fake(& &1, replace("x\n)", "x)"))
      assert Cljfmt.format_with(code, "(a)\n", "\n)", join_below) == code
    end

    test "keeps the suggestion when formatting changes more than whitespace" do
      code = "(f x)"
      assert Cljfmt.format_with(code, "", "", fake(& &1, replace("x", "y"))) == code
      # The same characters in another order.
      swapped = fake(& &1, replace("(a)\n(f x)", "(f x)\n(a)"))
      assert Cljfmt.format_with(code, "(a)\n", "", swapped) == code
    end

    test "keeps a suggestion with nothing but whitespace" do
      assert Cljfmt.format_with("  \n", "(a)\n", "\n(b)", fake(& &1)) ==
               "  \n"
    end

    test "keeps the suggestion when the file can't be read back, and removes the file" do
      test_pid = self()

      run = fn path, _ ->
        send(test_pid, {:path, path})
        File.rm!(path)
      end

      assert Cljfmt.format_with("(f x)", "", "", run) == "(f x)"
      assert_received {:path, path}
      refute File.exists?(path)
    end

    test "removes the file it formats in" do
      test_pid = self()
      run = fn path, _ -> send(test_pid, {:path, path}) end

      Cljfmt.format_with("(f x)", "", "", run)
      assert_received {:path, path}
      assert Path.extname(path) == ".clj"
      refute File.exists?(path)
    end
  end

  describe "format/4" do
    setup do
      stub_dir = Meerkat.TestHelpers.tmp_path("meerkat-cljfmt")
      File.mkdir_p!(stub_dir)
      prev_path = System.get_env("PATH")

      on_exit(fn ->
        System.put_env("PATH", prev_path)
        File.rm_rf!(stub_dir)
      end)

      %{stub_dir: stub_dir, prev_path: prev_path}
    end

    # A hook on PATH that records its working directory, arguments and
    # stdin, then exits with `code`.
    defp stub_hook(%{stub_dir: dir, prev_path: prev_path}, code) do
      path = Path.join(dir, @hook)
      calls = Path.join(dir, "calls")

      File.write!(path, """
      #!/bin/sh
      pwd >> '#{calls}'
      echo "$@" >> '#{calls}'
      cat >> '#{calls}'
      echo >> '#{calls}'
      echo hook output
      exit #{code}
      """)

      File.chmod!(path, 0o755)
      System.put_env("PATH", dir <> ":" <> prev_path)
      calls
    end

    test "without the hook on PATH, keeps the suggestion", %{stub_dir: dir} do
      System.put_env("PATH", dir)
      assert Cljfmt.format("(f  x)", "", "", dir) == "(f  x)"
    end

    test "runs the hook in the given directory on an edit of the file, repairing, then formatting",
         ctx do
      calls = stub_hook(ctx, 0)
      cwd = File.cwd!() |> Path.join("test")

      assert Cljfmt.format("(f  x)", "", "", cwd) == "(f  x)"

      [cwd1, args1, payload1, cwd2, args2, payload2] =
        calls |> File.read!() |> String.split("\n", trim: true)

      assert cwd1 == cwd and cwd2 == cwd
      assert args1 == "--no-revert"
      assert args2 == "--no-revert --cljfmt"
      assert payload1 == payload2

      assert %{
               "hook_event_name" => "PostToolUse",
               "tool_name" => "Edit",
               "tool_input" => %{"file_path" => file},
               "tool_response" => %{},
               "session_id" => "meerkat"
             } = Jason.decode!(payload1)

      assert Path.extname(file) == ".clj"
      refute File.exists?(file)
      refute File.exists?(file <> ".json")
    end

    test "logs a hook that fails, and keeps the suggestion", ctx do
      stub_hook(ctx, 3)

      stderr =
        capture_io(:stderr, fn ->
          assert Cljfmt.format("(f  x)", "", "", File.cwd!()) == "(f  x)"
        end)

      assert stderr =~ "meerkat: #{@hook} exited 3: hook output"
    end
  end

  describe "the installed hook" do
    @describetag skip: is_nil(@installed) && "#{@hook} is not installed"

    setup do
      dir = Meerkat.TestHelpers.tmp_path("meerkat-cljfmt-real")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "repairs and formats a suggestion as it sits in its file", %{dir: dir} do
      {above, below} = Cljfmt.context(@file_text, 3, 4)
      # The closers are missing, and the body sits at the wrong column.
      code = "    (* x\n      y"

      assert Cljfmt.format(code, above, below, dir) == "    (* x\n       y)))"
    end
  end
end
