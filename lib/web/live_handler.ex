defmodule Bonfire.Translation.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler
  import Untangle

  @doc """
  Handles server-side translation of a post's content fields.

  Expects params:
    - "id" - the object/post ID to translate
    - "target_lang" - target language code (e.g., "en")
    - "source_lang" - optional source language code

  Pushes a "translation_result" event back to the JS hook with translated fields.
  """
  def handle_event("translate", %{"id" => object_id} = params, socket) do
    target_lang = params["target_lang"] || to_string(Bonfire.Common.Localise.get_locale_id())
    source_lang = params["source_lang"]
    user = current_user(socket)

    with {:ok, object} <-
           Bonfire.Social.Objects.read(object_id, current_user: user),
         {:ok, translations} <-
           Bonfire.Social.PostContents.translate(object, target_lang,
             source_lang: source_lang,
             current_user: user
           ) do
      {:noreply,
       socket
       |> maybe_push_event("translation_result", %{
         id: object_id,
         translations: translations,
         target_lang: target_lang
       })}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> maybe_push_event("translation_error", %{
           id: object_id,
           error: to_string(reason)
         })}

      other ->
        error(other, l("Could not translate this content"))

        {:noreply,
         socket
         |> maybe_push_event("translation_error", %{
           id: object_id,
           error: l("Could not translate this content")
         })}
    end
  end

end
