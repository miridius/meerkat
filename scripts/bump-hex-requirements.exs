# Rewrites mix.exs requirements so each named Hex package can reach
# the given release. scripts/bump-deps.sh passes `name version` pairs
# from `mix hex.outdated`'s "Update not possible" rows. A `~>`
# requirement keeps its precision: with latest 0.15.2, "~> 0.14.0"
# becomes "~> 0.15.2"; with latest 2.1.0, "~> 1.2" becomes "~> 2.1".
#
# A requirement that already allows the release is left alone: another
# dependency holds the package back. Any other requirement form stops
# the commit, naming the package, to be edited by hand.
#
#   elixir scripts/bump-hex-requirements.exs mdex 0.15.2 [name version ...]

fail = fn message ->
  IO.puts(:stderr, "pre-commit: #{message}")
  System.halt(1)
end

bump = fn source, name, latest ->
  # Line-anchored, so a commented-out entry is never the one rewritten.
  pattern = ~r/^(\s*\{:#{Regex.escape(name)},\s*")([^"]+)(")/m

  old =
    case Regex.run(pattern, source, capture: :all_but_first) do
      [_, old, _] -> old
      nil -> fail.("mix.exs has no {:#{name}, \"<requirement>\"} entry to move to #{latest}.")
    end

  version = Version.parse!(latest)

  requirement =
    case Version.parse_requirement(old) do
      {:ok, requirement} -> requirement
      :error -> fail.("mix.exs #{name} \"#{old}\" is not a valid requirement.")
    end

  new =
    cond do
      Version.match?(version, requirement) ->
        nil

      match = Regex.run(~r/^~> \d+\.\d+(\.\d+)?$/, old) ->
        case match do
          [_] -> "~> #{version.major}.#{version.minor}"
          [_, _] -> "~> #{version.major}.#{version.minor}.#{version.patch}"
        end

      true ->
        fail.(
          "mix.exs #{name} \"#{old}\" excludes #{latest}; edit the requirement by hand."
        )
    end

  if new do
    IO.puts("pre-commit: mix.exs #{name} \"#{old}\" -> \"#{new}\"")
    Regex.replace(pattern, source, "\\g{1}#{new}\\g{3}", global: false)
  else
    IO.puts(
      "pre-commit: mix.exs #{name} \"#{old}\" allows #{latest}; another dependency " <>
        "holds it back (mix hex.outdated #{name})."
    )

    source
  end
end

updated =
  System.argv()
  |> Enum.chunk_every(2)
  |> Enum.reduce(File.read!("mix.exs"), fn [name, latest], source ->
    bump.(source, name, latest)
  end)

File.write!("mix.exs", updated)
