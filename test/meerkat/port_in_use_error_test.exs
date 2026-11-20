defmodule Meerkat.PortInUseErrorTest do
  use ExUnit.Case, async: true

  test "the message names the taken port and how to get past it" do
    assert Exception.message(%Meerkat.PortInUseError{port: 4799}) ==
             "meerkat: port 4799 is in use (--port 4799); pick another port or omit --port"
  end
end
