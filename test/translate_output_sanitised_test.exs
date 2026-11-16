defmodule Bonfire.Translation.TranslateOutputSanitisedTest do
  @moduledoc """
  What the translation service answers is not trusted: the translated body of a post is put into the page as HTML, so the answer handed to the page has live markup only of the kind a post may carry, whatever the service (or a text it was fed) put there.

  The translation server here is a real HTTP server running on this machine (`TestServer`) that answers with the markup given by the test.
  """
  use Bonfire.Translation.ConnCase, async: false
  @moduletag :backend

  import Bonfire.Posts.Fake, only: [fake_post!: 3]
  alias Bonfire.Common.HTTP.TestServer

  setup do
    Bonfire.Common.Cache.remove_all()
    {:ok, answer} = Agent.start_link(fn -> "" end)

    port =
      TestServer.start(fn conn ->
        body =
          case conn.request_path do
            "/health" -> ~s({"status": "ok"})
            _ -> Jason.encode!(%{"translatedText" => Agent.get(answer, & &1)})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json", nil)
        |> Plug.Conn.resp(200, body)
      end)

    Process.put(:ssrf_allow_hosts, ["127.0.0.1:#{port}"])
    Process.put(:bonfire_translation_adapters, [Bonfire.Translation.LibreTranslate])

    Process.put([:bonfire_translation, Bonfire.Translation.LibreTranslate],
      base_url: "http://127.0.0.1:#{port}"
    )

    post =
      fake_post!(fake_user!(fake_account!()), "public", %{
        post_content: %{html_body: "<p>a public post</p>"}
      })

    {:ok, post: post, answer: answer}
  end

  defp translate_to(answer, post, markup) do
    Agent.update(answer, fn _ -> markup end)
    Bonfire.Common.Cache.remove_all()

    assert {:ok, %{html_body: html_body}} =
             Bonfire.Social.PostContents.translate(post, "es", current_user: fake_user!())

    html_body
  end

  test "ordinary markup comes through (control)", %{post: post, answer: answer} do
    html_body = translate_to(answer, post, "<p>hola <strong>mundo</strong></p>")

    assert html_body =~ "<strong>mundo</strong>"
  end

  test "an event handler in the answer is dropped", %{post: post, answer: answer} do
    html_body = translate_to(answer, post, ~s|<p>hola</p><img src="x" onerror="alert(1)">|)

    assert html_body =~ "hola"
    refute html_body =~ "onerror"
  end

  test "a script in the answer is dropped", %{post: post, answer: answer} do
    html_body = translate_to(answer, post, "<p>hola</p><script>alert(1)</script>")

    assert html_body =~ "hola"
    refute html_body =~ "<script"
  end

  test "a javascript link in the answer is dropped", %{post: post, answer: answer} do
    html_body = translate_to(answer, post, ~s|<a href="javascript:alert(1)">hola</a>|)

    assert html_body =~ "hola"
    refute html_body =~ "javascript:"
  end
end
