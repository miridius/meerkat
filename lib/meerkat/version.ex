defmodule Meerkat.Version do
  @moduledoc """
  Identity and changelog of the running meerkat, for the toolbar version
  chip. A prod release reads the manifest install.sh bakes into the version
  dir (the build commit, the repo URL, and the recent merged-PR subjects);
  a dev source tree reports the checkout's branch with no changelog.
  """

  require Logger

  @manifest_name "meerkat_version"

  @type entry :: %{number: pos_integer(), title: String.t(), url: String.t()}
  @type t :: %{label: String.t(), dev?: boolean(), changelog: [entry()]}

  @doc "Version label and changelog for the chip."
  @spec info() :: t()
  def info do
    case read_manifest() do
      {:ok, [commit, repo_url | subjects]} ->
        %{label: short(commit), dev?: false, changelog: changelog(subjects, repo_url)}

      :dev ->
        dev_info()

      broken ->
        # A prod release whose manifest is missing/short/unreadable would
        # otherwise show itself as a dev build with no signal.
        Logger.warning("Meerkat.Version: unreadable version manifest (#{inspect(broken)})")
        dev_info()
    end
  end

  defp dev_info, do: %{label: "dev: #{dev_branch()}", dev?: true, changelog: []}

  # :dev when not a release (no manifest expected); {:ok, lines} or
  # {:error, reason} when RELEASE_ROOT is set, so info/0 can tell a genuine
  # dev tree from a broken install.
  defp read_manifest do
    case System.get_env("RELEASE_ROOT") do
      nil ->
        :dev

      root ->
        with {:ok, contents} <- File.read(Path.join(root, @manifest_name)) do
          {:ok, contents |> String.split("\n") |> Enum.map(&String.trim/1)}
        end
    end
  end

  # Keep only subjects that carry a `(#N)` PR reference (squash-merge
  # subjects do; a stray direct commit doesn't and is dropped).
  defp changelog(subjects, repo_url) do
    Enum.flat_map(subjects, fn subject ->
      case Regex.run(~r/\(#(\d+)\)\s*$/, subject) do
        [_, n] ->
          number = String.to_integer(n)
          title = String.replace(subject, ~r/\s*\(#\d+\)\s*$/, "")
          [%{number: number, title: title, url: pr_url(repo_url, number)}]

        nil ->
          []
      end
    end)
  end

  # No origin remote baked in: list the entry without a (dead) link.
  defp pr_url("", _number), do: nil
  defp pr_url(repo_url, number), do: "#{repo_url}/pull/#{number}"

  defp short(commit), do: String.slice(commit, 0, 7)

  defp dev_branch do
    root = Path.expand("../..", __DIR__)

    case System.cmd("git", ["-C", root, "branch", "--show-current"], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> "unknown"
          branch -> branch
        end

      _ ->
        "unknown"
    end
  rescue
    _ -> "unknown"
  end
end
