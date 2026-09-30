# Rewrites mix.exs requirements so each named Hex package can reach
# the given release. scripts/bump-deps.sh passes `name version` pairs
# from `mix hex.outdated`'s "Update not possible" rows. A requirement
# keeps its `~>` precision: "~> 0.14.0" becomes "~> 0.15.2" and
# "~> 1.2" becomes "~> 2.0".
#
#   elixir scripts/bump-hex-requirements.exs mdex 0.15.2 [name version ...]

bump = fn source, name, latest ->
  pattern = ~r/(\{:#{Regex.escape(name)},\s*")~> ([^"]+)(")/
  [_, old, _] = Regex.run(pattern, source, capture: :all_but_first)
  latest = Version.parse!(latest)

  new =
    case String.split(old, ".") do
      [_, _] -> "~> #{latest.major}.#{latest.minor}"
      [_, _, _] -> "~> #{latest.major}.#{latest.minor}.#{latest.patch}"
    end

  IO.puts("pre-commit: mix.exs #{name} \"~> #{old}\" -> \"#{new}\"")
  Regex.replace(pattern, source, "\\g{1}#{new}\\g{3}", global: false)
end

updated =
  System.argv()
  |> Enum.chunk_every(2)
  |> Enum.reduce(File.read!("mix.exs"), fn [name, latest], source ->
    bump.(source, name, latest)
  end)

File.write!("mix.exs", updated)
