defmodule Fishbowl.World.Snapshot do
  @moduledoc """
  Save/load the world to disk so it survives deploys and restarts. Plain
  `:erlang.term_to_binary/1` to a file — the world is small (a few thousand
  tiles/entities), no need for a database.
  """

  require Logger

  def path do
    Application.get_env(:fishbowl, :snapshot_path, "priv/world_snapshot.bin")
  end

  def save(state) do
    data = :erlang.term_to_binary(state)
    tmp = path() <> ".tmp"
    File.mkdir_p!(Path.dirname(path()))
    File.write!(tmp, data)
    File.rename!(tmp, path())
    :ok
  rescue
    error ->
      Logger.warning("Fishbowl.World.Snapshot save failed: #{inspect(error)}")
      :error
  end

  def load do
    case File.read(path()) do
      {:ok, data} -> {:ok, :erlang.binary_to_term(data)}
      {:error, _reason} -> :error
    end
  rescue
    error ->
      Logger.warning("Fishbowl.World.Snapshot load failed: #{inspect(error)}")
      :error
  end
end
