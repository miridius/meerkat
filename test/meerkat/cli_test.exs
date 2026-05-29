defmodule Meerkat.CLITest do
  use ExUnit.Case, async: true

  alias Meerkat.CLI

  describe "parse_args/1" do
    test "defaults: no commit-msg / pr / positional, browser opens, port 0" do
      assert CLI.parse_args([]) == %{
               commit_msg_path: nil,
               positional: nil,
               pr: nil,
               no_open: false,
               port: 0
             }
    end

    test "--commit-msg threads through" do
      assert %{commit_msg_path: "/tmp/MSG"} = CLI.parse_args(["--commit-msg", "/tmp/MSG"])
    end

    test "--no-open is a boolean flag" do
      assert %{no_open: true} = CLI.parse_args(["--no-open"])
    end

    test "--port parses as integer" do
      assert %{port: 4321} = CLI.parse_args(["--port", "4321"])
    end

    test "positional arg is captured for ref/range parsing" do
      assert %{positional: "HEAD"} = CLI.parse_args(["HEAD"])
      assert %{positional: "main..feat"} = CLI.parse_args(["main..feat"])
      assert %{positional: "main...feat"} = CLI.parse_args(["main...feat"])
    end

    test "--pr threads through" do
      assert %{pr: "123"} = CLI.parse_args(["--pr", "123"])
    end

    test "all flags together" do
      assert CLI.parse_args(["--commit-msg", "/tmp/x", "--no-open", "--port", "0"]) == %{
               commit_msg_path: "/tmp/x",
               positional: nil,
               pr: nil,
               no_open: true,
               port: 0
             }
    end
  end
end
