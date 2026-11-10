import Config

config :ex_money, auto_start_exchange_rate_service: false
config :ash, :validate_domain_inclusion?, false
config :ash, default_string_length_count: :codepoints
config :logger, level: :warning
