defmodule SilentRegression.ProviderCredentials.KeyRotation do
  @moduledoc """
  Inventories and re-encrypts provider credentials under the active Cloak key.

  Ciphertext tags and counts are safe operational metadata. Plaintext is used
  only inside Cloak/Ecto during migration and is never returned or logged.
  """

  alias Cloak.Ecto.Migrator
  alias Cloak.Tags.Decoder
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.Vault

  def inventory do
    ciphertexts = encrypted_secrets()

    {tags, unreadable_count} =
      Enum.reduce(ciphertexts, {%{}, 0}, fn ciphertext, {counts, unreadable} ->
        case ciphertext_tag(ciphertext) do
          {:ok, tag} -> {Map.update(counts, tag, 1, &(&1 + 1)), unreadable}
          :error -> {counts, unreadable + 1}
        end
      end)

    decryptable_count =
      Enum.count(ciphertexts, fn ciphertext ->
        match?({:ok, _plaintext}, Vault.decrypt(ciphertext))
      end)

    %{
      active_tag: active_tag(),
      total_count: length(ciphertexts),
      tag_counts: tags,
      decryptable_count: decryptable_count,
      unreadable_count: unreadable_count
    }
  end

  def migrate_to_active_key do
    Migrator.migrate(Repo, ProviderCredential)

    case inventory() do
      %{total_count: count, decryptable_count: count, unreadable_count: 0} = inventory
      when map_size(inventory.tag_counts) == 0 ->
        {:ok, inventory}

      %{total_count: count, decryptable_count: count, unreadable_count: 0} = inventory ->
        if inventory.tag_counts == %{inventory.active_tag => count} do
          {:ok, inventory}
        else
          {:error, {:unexpected_ciphertext_tags, inventory}}
        end

      inventory ->
        {:error, {:unreadable_ciphertexts, inventory}}
    end
  end

  def active_tag do
    config = Application.fetch_env!(:silent_regression, Vault)

    case Keyword.fetch!(config, :ciphers) do
      [{_label, {_cipher, options}} | _rest] -> Keyword.fetch!(options, :tag)
      _other -> raise "SilentRegression.Vault must configure at least one cipher"
    end
  end

  defp encrypted_secrets do
    Repo.query!("SELECT encrypted_secret FROM provider_credentials ORDER BY id").rows
    |> Enum.map(fn [ciphertext] -> ciphertext end)
  end

  defp ciphertext_tag(ciphertext) do
    case Decoder.decode(ciphertext) do
      %{tag: tag} when is_binary(tag) -> {:ok, tag}
      _other -> :error
    end
  rescue
    _exception -> :error
  end
end
