import Config

# Totem's own tests start the servers they need, each with its own root.
if config_env() == :test, do: config(:totem, server: false)
