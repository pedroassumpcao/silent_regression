defmodule SilentRegression.Vault do
  @moduledoc """
  Runtime vault for application-level encryption of provider credentials.

  The first configured cipher encrypts new values. Retired ciphers remain in
  the keyring while their ciphertext is migrated to the current version.
  """

  use Cloak.Vault, otp_app: :silent_regression
end
