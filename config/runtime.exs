import Config

decode_32_byte_key! = fn environment_name ->
  case System.get_env(environment_name) do
    nil ->
      raise "environment variable #{environment_name} is missing"

    encoded_key ->
      case Base.decode64(encoded_key) do
        {:ok, key} when byte_size(key) == 32 -> key
        _other -> raise "#{environment_name} must encode exactly 32 bytes"
      end
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/silent_regression start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :silent_regression, SilentRegressionWeb.Endpoint, server: true
end

config :silent_regression, SilentRegressionWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  case System.get_env("PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V1") do
    nil ->
      :ok

    _encoded_key ->
      key_v1 = decode_32_byte_key!.("PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V1")
      encoded_key_v2 = System.get_env("PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V2")

      ciphers =
        if encoded_key_v2 do
          key_v2 = decode_32_byte_key!.("PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V2")

          if key_v1 == key_v2 do
            raise "provider credential encryption key versions must use different key material"
          end

          [
            default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V2", key: key_v2, iv_length: 12},
            retired_v1: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key_v1, iv_length: 12}
          ]
        else
          [default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key_v1, iv_length: 12}]
        end

      config :silent_regression, SilentRegression.Vault,
        json_library: Jason,
        ciphers: ciphers
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :silent_regression, SilentRegressionWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/silent_regression_web/router\.ex$"E,
        ~r"lib/silent_regression_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  provider_credential_encryption_key_v1 =
    decode_32_byte_key!.("PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V1")

  provider_credential_encryption_key_v2 =
    case System.get_env("PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V2") do
      nil -> nil
      _encoded_key -> decode_32_byte_key!.("PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V2")
    end

  provider_credential_ciphers =
    if provider_credential_encryption_key_v2 do
      if provider_credential_encryption_key_v1 == provider_credential_encryption_key_v2 do
        raise "provider credential encryption key versions must use different key material"
      end

      [
        default:
          {Cloak.Ciphers.AES.GCM,
           tag: "AES.GCM.V2", key: provider_credential_encryption_key_v2, iv_length: 12},
        retired_v1:
          {Cloak.Ciphers.AES.GCM,
           tag: "AES.GCM.V1", key: provider_credential_encryption_key_v1, iv_length: 12}
      ]
    else
      [
        default:
          {Cloak.Ciphers.AES.GCM,
           tag: "AES.GCM.V1", key: provider_credential_encryption_key_v1, iv_length: 12}
      ]
    end

  config :silent_regression, SilentRegression.Vault,
    json_library: Jason,
    ciphers: provider_credential_ciphers

  rate_limit_hmac_key = decode_32_byte_key!.("RATE_LIMIT_HMAC_KEY")
  deletion_receipt_hmac_key = decode_32_byte_key!.("DELETION_RECEIPT_HMAC_KEY")

  config :silent_regression, :rate_limit_hmac_key, rate_limit_hmac_key
  config :silent_regression, :deletion_receipt_hmac_key, deletion_receipt_hmac_key

  resend_api_key =
    System.get_env("RESEND_API_KEY") ||
      raise "environment variable RESEND_API_KEY is missing"

  mail_from =
    System.get_env("MAIL_FROM") ||
      raise "environment variable MAIL_FROM is missing"

  mail_from_name = System.get_env("MAIL_FROM_NAME", "Silent Regression")

  config :swoosh, :api_client, Swoosh.ApiClient.Req

  config :silent_regression, SilentRegression.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: resend_api_key

  config :silent_regression, :notification_email_from, {mail_from_name, mail_from}

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :silent_regression, SilentRegression.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || raise "environment variable PHX_HOST is missing"

  config :silent_regression, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :silent_regression, SilentRegressionWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :silent_regression, SilentRegressionWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :silent_regression, SilentRegressionWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :silent_regression, SilentRegression.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
