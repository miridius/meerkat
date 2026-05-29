defmodule MeerkatWeb.ErrorHTML do
  @moduledoc """
  Plain-text HTML error responses — meerkat has no custom error
  pages, intentionally; the LV is the only user-facing surface.
  """
  use MeerkatWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
