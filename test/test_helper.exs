# ExUnit's 100 ms default for assert_receive can run out on a loaded CI
# runner, and 1 s ran out while other gates shared the machine. A message
# that arrives ends the wait, so a passing test is no slower; set no
# shorter wait on an assert_receive.
ExUnit.start(assert_receive_timeout: 5_000)

Meerkat.TestHelpers.put_git_config_env()

# Controller / LiveView tests need the endpoint started so Phoenix's
# `Phoenix.ConnTest.dispatch/5` can find its persistent_term config.
# Production / CLI flips this on via `Application.put_env` before the
# supervisor starts; we do the equivalent inline here.
Application.put_env(:meerkat, :start_endpoint, true)
{:ok, _} = MeerkatWeb.Endpoint.start_link()

# Keep every test's toolbar settings out of the user's config dir.
settings_dir = Meerkat.TestHelpers.tmp_path("meerkat-test-settings")
Application.put_env(:meerkat, :settings_path, Path.join(settings_dir, "settings.json"))
ExUnit.after_suite(fn _ -> File.rm_rf!(settings_dir) end)
