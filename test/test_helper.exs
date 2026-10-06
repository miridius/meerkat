ExUnit.start()

# Controller / LiveView tests need the endpoint started so Phoenix's
# `Phoenix.ConnTest.dispatch/5` can find its persistent_term config.
# Production / CLI flips this on via `Application.put_env` before the
# supervisor starts; we do the equivalent inline here.
Application.put_env(:meerkat, :start_endpoint, true)
{:ok, _} = MeerkatWeb.Endpoint.start_link()
