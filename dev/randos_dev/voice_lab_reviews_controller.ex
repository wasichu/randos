defmodule RandosDev.VoiceLabReviewsController do
  use RandosWeb, :controller

  def create(conn, params) do
    case RandosDev.VoiceLabReviews.save(params) do
      {:ok, saved_at} ->
        conn |> put_status(:created) |> json(%{saved_at: saved_at})

      {:error, :invalid_review} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Please add a valid rating or note (up to 2,000 characters)."})

      {:error, :storage_failed} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "Could not write the review file. Your browser draft is still available."
        })
    end
  end
end
