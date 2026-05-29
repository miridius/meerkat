defmodule MeerkatWeb.Layouts do
  @moduledoc """
  Embeds the root layout (`layouts/root.html.heex`). meerkat is a
  single-LV app — no per-view inner layout, no flash group component;
  the LV manages its own flash banner directly.
  """
  use MeerkatWeb, :html

  embed_templates "layouts/*"
end
