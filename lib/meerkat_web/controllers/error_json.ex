defmodule MeerkatWeb.ErrorJSON do
  @moduledoc """
  Default JSON error response — `{errors: {detail: <status message>}}`.
  """

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
