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
end
