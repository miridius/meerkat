# Both bounds catch only a hang; a passing test is no slower for them.
# While other gates load the machine, a test that starts gits, hooks or
# BEAMs can run past ExUnit's 60 s default, and an assert_receive past
# 1 s, then 5 s. Set no shorter wait on an assert_receive. It stays well
# below the test timeout, so a message that never comes fails at its
# assert_receive.
ExUnit.start(timeout: 180_000, assert_receive_timeout: 30_000)
Meerkat.TestHelpers.isolate_tmp_dir()

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
