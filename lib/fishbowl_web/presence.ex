defmodule FishbowlWeb.Presence do
  use Phoenix.Presence,
    otp_app: :fishbowl,
    pubsub_server: Fishbowl.PubSub
end
