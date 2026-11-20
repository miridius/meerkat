defmodule Meerkat.BrowserTest do
  use ExUnit.Case, async: true

  alias Meerkat.Browser

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
    assert String.ends_with?(System.find_executable(cmd), "/test/support/no-browser/#{cmd}")

    assert Browser.open("http://127.0.0.1:80/") ==
             {:error, "#{cmd} exited 1: meerkat tests open no browser: http://127.0.0.1:80/"}
  end
end
