defmodule Bonfire.Translation.AnonymousTranslateTest do
  @moduledoc """
  Translating costs the instance money (a request to the translation service per call), so only signed-in users may trigger it. A visitor without a session who requests a translation of a public post through the plain `/LiveHandler` route must not cause any request to the translation service.

  The translation server here is a real HTTP server running on this machine (`TestServer`), so a test that expects no request checks that the server never received one. It sits next to a test where the same post is translated by a signed-in user and the request does arrive.
  """
  use Bonfire.Translation.ConnCase, async: false
  @moduletag :backend

  import Bonfire.Posts.Fake, only: [fake_post!: 3]
  alias Bonfire.Common.HTTP.TestServer

  setup do
    Bonfire.Common.Cache.remove_all()
    test_pid = self()

    port =
      TestServer.start(fn conn ->
        send(test_pid, {:hit, conn.request_path})

        body =
          case conn.request_path do
            "/health" -> ~s({"status": "ok"})
            _ -> ~s({"translatedText": "hola"})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json", nil)
        |> Plug.Conn.resp(200, body)
      end)

    url = "http://127.0.0.1:#{port}"

    Process.put(:ssrf_allow_hosts, ["127.0.0.1:#{port}"])
    Process.put(:bonfire_translation_adapters, [Bonfire.Translation.LibreTranslate])
    Process.put([:bonfire_translation, Bonfire.Translation.LibreTranslate], base_url: url)

    post =
      fake_post!(fake_user!(fake_account!()), "public", %{
        post_content: %{html_body: "<p>a public post</p>"}
      })

    {:ok, post: post}
  end

  test "a signed-in user's translation of a public post reaches the translation server (control)",
       %{post: post} do
    assert {:ok, _} =
             Bonfire.Social.PostContents.translate(post, "es", current_user: fake_user!())

    assert_receive {:hit, "/translate"}
  end

  test "a visitor without a session cannot make the instance call the translation server", %{
    post: post
  } do
    get(build_conn(), "/LiveHandler/Bonfire.Translation/translate?id=#{post.id}&target_lang=es")

    refute_receive {:hit, _}, 500
  end
end
