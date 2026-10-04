defmodule Bonfire.Translation.LibreTranslateSSRFTest do
  @moduledoc """
  Users can choose their own LibreTranslate server in their settings. That choice must only apply to their own translations: other people's text (and the instance's API key) must never be sent to it. And it must not be usable to make the instance send requests to private addresses.

  The LibreTranslate servers here are real HTTP servers running on this machine (`TestServer`), so every request that would reach them really does. A test that expects a request to be refused checks that the server never received it. Each of those sits next to a test where the same kind of request is allowed and does arrive, which shows the request really would have been made.
  """
  use Bonfire.Translation.ConnCase, async: false
  @moduletag :backend

  import PhoenixTest
  use Bonfire.Common.Settings
  alias Bonfire.Common.HTTP.TestServer

  setup do
    Bonfire.Common.Cache.remove_all()
    Process.put(:bonfire_translation_adapters, [Bonfire.Translation.LibreTranslate])
    :ok
  end

  # a LibreTranslate server running on this machine, which reports each request it gets with its own name
  defp serve(name) do
    test_pid = self()

    port =
      TestServer.start(fn conn ->
        send(test_pid, {:hit, name, conn.request_path})

        body =
          case conn.request_path do
            # checked before translating
            "/health" -> ~s({"status": "ok"})
            _ -> ~s({"translatedText": "hola"})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json", nil)
        |> Plug.Conn.resp(200, body)
      end)

    "http://127.0.0.1:#{port}"
  end

  defp flush_hits(name) do
    receive do
      {:hit, ^name, _} -> flush_hits(name)
    after
      100 -> :ok
    end
  end

  defp allow!(urls) do
    Process.put(
      :ssrf_allow_hosts,
      Enum.map(List.wrap(urls), fn url ->
        %{host: host, port: port} = URI.parse(url)
        "#{host}:#{port}"
      end)
    )
  end

  # the way a person does it, on their own settings page
  defp user_with_own_server(url) do
    account = fake_account!()
    user = fake_user!(account)

    conn(user: user, account: account)
    |> visit("/settings/user/bonfire_translation")
    # the settings sections load asynchronously
    |> wait_async()
    |> within("form[data-scope='Elixir.Bonfire.Translation.LibreTranslate.base_url']", fn form ->
      form
      |> fill_in("LibreTranslate URL", with: url)
      |> submit()
    end)

    user = Bonfire.Me.Users.get_current(user.id)

    # the save itself worked, so a later failure is about how translation uses it
    assert Settings.get([Bonfire.Translation.LibreTranslate, :base_url], nil, current_user: user) ==
             url

    user
  end

  test "the server the admin configured is used (control)" do
    instance = serve(:instance)
    allow!(instance)
    Process.put([:bonfire_translation, Bonfire.Translation.LibreTranslate], base_url: instance)

    Bonfire.Translation.translate("hello", "es", current_user: fake_user!())

    assert_receive {:hit, :instance, "/translate"}
  end

  test "a user's own server is used for their translations" do
    own = serve(:own)
    allow!(own)
    user = user_with_own_server(own)

    Bonfire.Translation.translate("hello", "es", current_user: user)

    assert_receive {:hit, :own, "/translate"}
  end

  test "other people's translations are never sent to a user's own server" do
    instance = serve(:instance)
    own = serve(:own)
    allow!([instance, own])

    user = user_with_own_server(own)
    Bonfire.Translation.translate("hello", "es", current_user: user)
    assert_receive {:hit, :own, "/translate"}
    flush_hits(:own)

    # set after the first user's translation: in tests a `Process.put` value takes precedence over a user's own setting, which on a real instance it doesn't
    Process.put([:bonfire_translation, Bonfire.Translation.LibreTranslate], base_url: instance)

    Bonfire.Translation.translate("goodbye", "es", current_user: fake_user!())
    assert_receive {:hit, :instance, "/translate"}
    refute_received {:hit, :own, _}
  end

  test "a user's own server on a private address is never reached" do
    own = serve(:own)
    user = user_with_own_server(own)

    Bonfire.Translation.translate("hello", "es", current_user: user)

    refute_receive {:hit, :own, _}, 500
  end
end
