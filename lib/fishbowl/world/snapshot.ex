defmodule Fishbowl.World.Snapshot do
  @moduledoc """
  Save/load the world to disk so it survives deploys and restarts. Plain
  `:erlang.term_to_binary/1` to a file — the world is small (a few thousand
  tiles/entities), no need for a database.
  """

  require Logger

  alias Fishbowl.World.Entity

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
      {:ok, data} -> {:ok, migrate(:erlang.binary_to_term(data))}
      {:error, _reason} -> :error
    end
  rescue
    error ->
      Logger.warning("Fishbowl.World.Snapshot load failed: #{inspect(error)}")
      :error
  end

  # Snapshots outlive deploys, so a snapshot on disk may have been written by
  # an older `Entity` struct. Rebuild every entity through `struct/2` so fields
  # added since then get their defaults instead of blowing up the first tick
  # with a `KeyError` on `%{entity | new_field: ...}`.
  defp migrate(%{entities: entities} = state) when is_map(entities) do
    %{state | entities: Map.new(entities, fn {id, e} -> {id, migrate_entity(e)} end)}
  end

  defp migrate(state), do: state

  defp migrate_entity(%{__struct__: Entity} = entity),
    do: struct(Entity, Map.delete(entity, :__struct__))

  defp migrate_entity(entity), do: entity
end
