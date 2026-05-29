defmodule Meerkat.GitHub do
  @moduledoc """
  `gh` CLI wrapper. `view/2` reads `gh pr view <N> --json
  number,baseRefName,headRefName,title,body,url` for `--pr <N>` review
  metadata. `post_review/3` posts a PENDING review back via `gh api`.
  """

  @typedoc "Subset of the PR JSON we care about."
  @type pr :: %{
          number: pos_integer(),
          base_ref: String.t(),
          head_ref: String.t(),
          title: String.t(),
          body: String.t(),
          url: String.t()
        }

  @json_fields ~w(number baseRefName headRefName title body url)

  @doc """
  Run `gh pr view <spec> --json ...` and parse the result into the
  shape ReviewState consumes. `spec` may be a number (`"123"`) or a
  full PR URL — `gh` handles both.
  """
  @spec view(String.t(), String.t()) :: {:ok, pr} | {:error, String.t()}
  def view(repo_path, spec) do
    case run_pr_view(repo_path, [spec]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, decode_pr(json)}
          {:error, e} -> {:error, "could not parse `gh pr view` JSON: #{Exception.message(e)}"}
        end

      {:exit, code, output} ->
        {:error, "gh pr view #{spec} exited #{code}: #{String.trim(output)}"}
    end
  end

  # Shared shell-out for `gh pr view`. `extra_args` is the
  # caller-specific prefix (e.g. `[spec]` or `[]` for current-branch).
  # Returns `{:ok, output}` on exit-0, `{:exit, code, output}`
  # otherwise. Doesn't rescue ErlangError — callers that need to
  # treat "gh not on PATH" specially do so themselves.
  defp run_pr_view(repo_path, extra_args) do
    args = ["pr", "view"] ++ extra_args ++ ["--json", Enum.join(@json_fields, ",")]

    case System.cmd("gh", args, cd: repo_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:exit, code, output}
    end
  end

  @doc """
  Best-effort `gh pr view --json …` against the current branch. Used by
  the staged-commit / range / single-ref review paths to populate
  `state.pr` when the branch already has an open PR, so the header
  chip shows it and the decision footer offers Post-to-GitHub. Returns
  `nil` on any failure (gh missing, not authed, no open PR, malformed
  JSON, …) so the caller can fall through to the no-PR rendering.
  """
  @spec current_pr(String.t()) :: pr | nil
  def current_pr(repo_path) do
    case run_pr_view(repo_path, []) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, json} ->
            decode_pr(json)

          {:error, err} ->
            IO.puts(
              :stderr,
              "meerkat: warning — gh pr view returned non-JSON on success: " <>
                "#{Exception.message(err)}"
            )

            nil
        end

      {:exit, _code, output} ->
        trimmed = String.trim(output)

        cond do
          # Expected: branch has no PR.
          trimmed =~ ~r/no pull requests? found/i ->
            nil

          # `gh` not installed / not on PATH — also expected outside
          # repos with GitHub remotes.
          trimmed =~ ~r/(command not found|gh: not found)/i ->
            nil

          # Anything else is a real failure worth surfacing.
          true ->
            IO.puts(
              :stderr,
              "meerkat: warning — gh pr view failed: #{trimmed}"
            )

            nil
        end
    end
  rescue
    e in [ErlangError] ->
      IO.puts(
        :stderr,
        "meerkat: warning — gh pr view: gh not on PATH (#{Exception.message(e)})"
      )

      nil

    e in [KeyError, ArgumentError, FunctionClauseError] ->
      IO.puts(
        :stderr,
        "meerkat: warning — gh pr view returned an unexpected JSON shape: " <>
          "#{Exception.message(e)}"
      )

      nil
  end

  defp decode_pr(json) do
    %{
      number: Map.fetch!(json, "number") |> coerce_number(),
      base_ref: Map.get(json, "baseRefName") || "",
      head_ref: Map.get(json, "headRefName") || "",
      title: Map.get(json, "title") || "",
      body: Map.get(json, "body") || "",
      url: Map.get(json, "url") || ""
    }
  end

  defp coerce_number(n) when is_integer(n), do: n
  defp coerce_number(n) when is_binary(n), do: String.to_integer(n)

  @doc false
  # Test seam for `decode_pr/1` — exposes the JSON → struct
  # serialisation contract without requiring callers to set up the
  # gh stub. Not part of the public API.
  def decode_pr_for_test(json), do: decode_pr(json)

  @typedoc "Sub-pieces of a GitHub PENDING review payload."
  @type review_payload :: %{
          body: String.t(),
          event: String.t(),
          comments: [map()]
        }

  @doc """
  POST a PENDING review to GitHub via `gh api`. Returns the
  response's `html_url` so the caller can open it in a new tab.
  `gh` infers the owner/repo from the local clone's remote, so the
  caller only passes the PR number.

  The request body is written to a tmp file and passed to
  `gh api --input <path>` — no shell, no stdin race, no interpolation
  of paths into a command string. The tmp file is removed in an
  `after` block whether the call succeeded or not.
  """
  @spec post_review(String.t(), pos_integer(), review_payload) ::
          {:ok, String.t()} | {:error, String.t()}
  def post_review(repo_path, pr_number, payload) do
    body_json = Jason.encode!(payload)

    tmp =
      Path.join(System.tmp_dir!(), "meerkat-gh-#{System.unique_integer([:positive])}.json")

    try do
      case File.write(tmp, body_json) do
        :ok ->
          case System.find_executable("gh") do
            nil ->
              {:error, "gh binary not found on PATH"}

            _gh ->
              args = [
                "api",
                "-X",
                "POST",
                "/repos/{owner}/{repo}/pulls/#{pr_number}/reviews",
                "--input",
                tmp
              ]

              case System.cmd("gh", args, cd: repo_path, stderr_to_stdout: true) do
                {output, 0} ->
                  case Jason.decode(output) do
                    {:ok, %{"html_url" => url}} when is_binary(url) ->
                      {:ok, url}

                    {:ok, _} ->
                      {:error, "gh api response missing html_url: #{output}"}

                    {:error, e} ->
                      {:error, "could not parse gh api response: #{Exception.message(e)}"}
                  end

                {output, code} ->
                  {:error, "gh api exited #{code}: #{String.trim(output)}"}
              end
          end

        {:error, reason} ->
          {:error, "couldn't stage gh request body at #{tmp}: #{inspect(reason)}"}
      end
    after
      _ = File.rm(tmp)
    end
  end
end
