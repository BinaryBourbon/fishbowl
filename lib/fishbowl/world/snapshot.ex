defmodule Fishbowl.World.Snapshot do
  @moduledoc """
  Save/load the world to disk so it survives deploys and restarts. Plain
  `:erlang.term_to_binary/1` to a file — the world is small (a few thousand
  tiles/entities), no need for a database.
  """

  require Logger

  alias Fishbowl.World.{Entity, Tile}

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
  # an older `Entity`/`Tile` struct. Rebuild every one through `struct/2` so
  # fields added since then get their defaults instead of blowing up the
  # first tick with a `KeyError` on `%{entity | new_field: ...}`.
  defp migrate(state) do
    state
    |> migrate_field(:entities, &migrate_struct(&1, Entity))
    |> migrate_field(:tiles, &migrate_struct(&1, Tile))
  end

  defp migrate_field(state, key, fun) do
    case Map.get(state, key) do
      map when is_map(map) -> Map.put(state, key, Map.new(map, fn {k, v} -> {k, fun.(v)} end))
      _ -> state
    end
  end

  defp migrate_struct(%{__struct__: module} = value, module),
    do: struct(module, Map.delete(value, :__struct__))

  defp migrate_struct(value, _module), do: value
end
