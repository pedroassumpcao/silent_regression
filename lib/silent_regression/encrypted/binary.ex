defmodule SilentRegression.Encrypted.Binary do
  @moduledoc """
  Local Ecto type seam for encrypted binary fields.

  Product schemas depend on this module rather than directly on Cloak so the
  storage implementation can be changed without rewriting every schema.
  """

  use Cloak.Ecto.Binary, vault: SilentRegression.Vault

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(ciphertext) when is_binary(ciphertext) do
    case SilentRegression.Vault.decrypt(ciphertext) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      _other -> :error
    end
  end

  def load(_ciphertext), do: :error
end
