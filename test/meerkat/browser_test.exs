defmodule Meerkat.BrowserTest do
  # open/1 tests replace the OS open command through PATH, which is global.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [put_env: 2, tmp_path: 1]

  alias Meerkat.Browser

  describe "open/1" do
    setup do
      bin = tmp_path("meerkat-browser-test")
      File.mkdir_p!(bin)
      on_exit(fn -> File.rm_rf!(bin) end)
      {:ok, bin: bin}
    end

    # Installs `body` as the OS open command for this OS, alone on PATH.
    defp fake_open(bin, body) do
      {cmd, _args} = Browser.open_argv_for(:os.type(), "")
      File.write!(Path.join(bin, cmd), "#!/bin/sh\n" <> body)
      File.chmod!(Path.join(bin, cmd), 0o755)
      put_env("PATH", bin)
      cmd
    end

    test "runs the OS open command on the URL and returns :ok when it exits 0", %{bin: bin} do
      log = Path.join(bin, "args")
      fake_open(bin, "printf '%s\\n' \"$@\" > #{log}\n")

      assert Browser.open("http://127.0.0.1:4000/") == :ok

      assert File.read!(log) |> String.split("\n", trim: true) |> List.last() ==
               "http://127.0.0.1:4000/"
    end

    test "a non-zero exit is an error naming the command, code and trimmed output",
         %{bin: bin} do
      cmd = fake_open(bin, "echo '  no browser  '\nexit 3\n")

      assert Browser.open("http://x/") == {:error, "#{cmd} exited 3: no browser"}
    end

    test "an error carries what the command wrote to stderr", %{bin: bin} do
      cmd = fake_open(bin, "echo 'no display' >&2\nexit 3\n")

      assert Browser.open("http://x/") == {:error, "#{cmd} exited 3: no display"}
    end

    test "a missing open command is an error rather than a crash", %{bin: bin} do
      put_env("PATH", bin)

      assert {:error, message} = Browser.open("http://x/")
      assert message =~ "enoent"
    end

    test "rejects a URL that is not a string" do
      # Read back at runtime so the compiler's type check doesn't flag it.
      charlist_url = Process.get(:charlist_url, ~c"http://x/")
      assert_raise FunctionClauseError, fn -> Browser.open(charlist_url) end
    end
  end

  describe "open_argv_for/2 (OS dispatch table)" do
    test "macOS → `open <url>`" do
      assert Browser.open_argv_for({:unix, :darwin}, "http://x/") == {"open", ["http://x/"]}
    end

    test "Linux / other unix → `xdg-open <url>`" do
      assert Browser.open_argv_for({:unix, :linux}, "http://x/") == {"xdg-open", ["http://x/"]}
      assert Browser.open_argv_for({:unix, :freebsd}, "http://x/") == {"xdg-open", ["http://x/"]}
    end

    test "Windows → `cmd /c start \"\" <url>`" do
      assert Browser.open_argv_for({:win32, :nt}, "http://x/") ==
               {"cmd", ["/c", "start", "", "http://x/"]}
    end
  end

  # A mutant of a guard in lib/ can reach the real opener from a test.
  test "in a test, open/1 runs the no-browser stub, which opens nothing" do
    {cmd, _} = Browser.open_argv_for(:os.type(), "")
    # Checked first, so a test run without the stub opens nothing either.
    assert path = System.find_executable(cmd)
    assert String.ends_with?(path, "/test/support/no-browser/#{cmd}")

    assert Browser.open("http://127.0.0.1:80/") ==
             {:error, "#{cmd} exited 1: meerkat tests open no browser: http://127.0.0.1:80/"}
  end
end
