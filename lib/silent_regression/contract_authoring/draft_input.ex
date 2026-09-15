defmodule SilentRegression.ContractAuthoring.DraftInput do
  @moduledoc false

  alias SilentRegression.ContractAuthoring.Templates
  alias SilentRegression.Contracts
  alias SilentRegression.Monitors.JsonValue

  @composite_types ~w(all any not)
  @assistance_modes %{
    "self_serve" => :self_serve,
    "founder_assisted" => :founder_assisted,
    "codex_assisted" => :codex_assisted
  }

  def normalize(attrs, identity) when is_map(attrs) do
    with {:ok, template_key} <- template_key(value(attrs, :template_key)),
         {:ok, assistance_mode} <- assistance_mode(value(attrs, :assistance_mode)),
         {:ok, root} <- normalize_root(value(attrs, :root)),
         :ok <- validate_authoring_shape(root),
         {:ok, contract} <- parse_contract(identity, root),
         {:ok, template_usage} <- Templates.usage(template_key, contract.root) do
      {:ok,
       %{
         root: contract.root,
         template_key: template_key,
         template_usage: template_usage,
         assistance_mode: assistance_mode,
         contract_fingerprint: contract.fingerprint
       }}
    else
      {:error, :unknown_template} -> {:error, :template_key, "is not a supported template"}
      {:error, :invalid_assistance_mode} -> {:error, :assistance_mode, "is not supported"}
      {:error, :invalid_root} -> {:error, :rules, "must contain a valid flat rule list"}
      {:error, %{"message" => message}} -> {:error, :rules, message}
    end
  end

  def normalize(_attrs, _identity), do: {:error, :rules, "are invalid"}

  defp template_key(key) when is_binary(key) do
    case Templates.fetch(key) do
      {:ok, _template} -> {:ok, key}
      {:error, :unknown_template} -> {:error, :unknown_template}
    end
  end

  defp template_key(_key), do: {:error, :unknown_template}

  defp assistance_mode(mode) when is_atom(mode), do: assistance_mode(Atom.to_string(mode))

  defp assistance_mode(mode) when is_binary(mode) do
    case Map.fetch(@assistance_modes, mode) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_assistance_mode}
    end
  end

  defp assistance_mode(_mode), do: {:error, :invalid_assistance_mode}

  defp normalize_root(root) do
    case JsonValue.normalize(root) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :invalid_root}
    end
  end

  defp validate_authoring_shape(%{
         "id" => "contract",
         "type" => "all",
         "rules" => rules
       })
       when is_list(rules) and rules != [] do
    if Enum.all?(rules, &(is_map(&1) and &1["type"] not in @composite_types)),
      do: :ok,
      else: {:error, :invalid_root}
  end

  defp validate_authoring_shape(_root), do: {:error, :invalid_root}

  defp parse_contract(identity, root) do
    Contracts.parse_contract(%{
      "schema_version" => 1,
      "contract_id" => identity.contract_id,
      "contract_version" => identity.contract_version,
      "monitor_id" => identity.monitor_id,
      "root" => root
    })
  end

  defp value(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end
end
