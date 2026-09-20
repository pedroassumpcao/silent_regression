defmodule SilentRegression.WorkspaceLifecycle.DeletionLedger do
  @moduledoc """
  Signed, content-free deletion receipts for isolated restore reconciliation.

  The ledger identifies a workspace only by the existing keyed fingerprint. It
  contains no slug, name, email, prompt, output, or credential data.
  """

  import Ecto.Query

  alias SilentRegression.Repo
  alias SilentRegression.WorkspaceLifecycle.DeletionReceipt

  @schema_version 1
  @request_types ~w(closure_retention explicit_request)
  @statuses ~w(pending completed)

  def export(opts \\ []) do
    exported_at =
      Keyword.get(opts, :at, DateTime.utc_now(:second))
      |> DateTime.truncate(:second)

    entries =
      DeletionReceipt
      |> where([receipt], receipt.status in [:pending, :completed])
      |> order_by([receipt], asc: receipt.requested_at, asc: receipt.request_id)
      |> Repo.all()
      |> Enum.map(&entry_map/1)

    payload = %{
      "schema_version" => @schema_version,
      "exported_at" => DateTime.to_iso8601(exported_at),
      "entries" => entries
    }

    Map.put(payload, "signature", sign(payload))
  end

  def verify(
        %{
          "schema_version" => @schema_version,
          "exported_at" => exported_at,
          "entries" => entries,
          "signature" => signature
        } = ledger
      )
      when is_binary(exported_at) and is_list(entries) and is_binary(signature) do
    payload = Map.delete(ledger, "signature")

    with true <- secure_signature?(payload, signature),
         {:ok, _exported_at} <- parse_datetime(exported_at),
         {:ok, parsed} <- parse_entries(entries) do
      {:ok, parsed}
    else
      false -> {:error, :invalid_ledger_signature}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_ledger), do: {:error, :invalid_ledger}

  def digest(ledger) when is_map(ledger) do
    ledger
    |> canonical_payload()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp entry_map(receipt) do
    %{
      "request_id" => receipt.request_id,
      "workspace_fingerprint" => Base.url_encode64(receipt.workspace_fingerprint, padding: false),
      "request_type" => Atom.to_string(receipt.request_type),
      "status" => Atom.to_string(receipt.status),
      "requested_at" => DateTime.to_iso8601(receipt.requested_at),
      "purge_due_at" => DateTime.to_iso8601(receipt.purge_due_at),
      "completed_at" => format_datetime(receipt.completed_at)
    }
  end

  defp parse_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, parsed} ->
      case parse_entry(entry) do
        {:ok, item} -> {:cont, {:ok, [item | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_entry(%{
         "request_id" => request_id,
         "workspace_fingerprint" => encoded_fingerprint,
         "request_type" => request_type,
         "status" => status,
         "requested_at" => requested_at,
         "purge_due_at" => purge_due_at,
         "completed_at" => completed_at
       })
       when request_type in @request_types and status in @statuses do
    with {:ok, request_id} <- Ecto.UUID.cast(request_id),
         {:ok, fingerprint} <- decode_fingerprint(encoded_fingerprint),
         {:ok, requested_at} <- parse_datetime(requested_at),
         {:ok, purge_due_at} <- parse_datetime(purge_due_at),
         {:ok, completed_at} <- parse_optional_datetime(completed_at),
         :ok <- validate_completion(status, completed_at) do
      {:ok,
       %{
         request_id: request_id,
         workspace_fingerprint: fingerprint,
         request_type: String.to_existing_atom(request_type),
         status: String.to_existing_atom(status),
         requested_at: requested_at,
         purge_due_at: purge_due_at,
         completed_at: completed_at
       }}
    else
      _other -> {:error, :invalid_ledger_entry}
    end
  end

  defp parse_entry(_entry), do: {:error, :invalid_ledger_entry}

  defp decode_fingerprint(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, fingerprint} when byte_size(fingerprint) == 32 -> {:ok, fingerprint}
      _other -> {:error, :invalid_fingerprint}
    end
  end

  defp decode_fingerprint(_encoded), do: {:error, :invalid_fingerprint}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.truncate(datetime, :second)}
      _other -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_datetime}

  defp parse_optional_datetime(nil), do: {:ok, nil}
  defp parse_optional_datetime(value), do: parse_datetime(value)

  defp validate_completion("completed", %DateTime{}), do: :ok
  defp validate_completion("pending", nil), do: :ok
  defp validate_completion(_status, _completed_at), do: {:error, :invalid_completion}

  defp secure_signature?(payload, signature) do
    expected = sign(payload)

    byte_size(expected) == byte_size(signature) and
      Plug.Crypto.secure_compare(expected, signature)
  end

  defp sign(payload) do
    key = Application.fetch_env!(:silent_regression, :deletion_receipt_hmac_key)

    :crypto.mac(:hmac, :sha256, key, "deletion-ledger-v1\n" <> canonical_payload(payload))
    |> Base.url_encode64(padding: false)
  end

  defp canonical_payload(payload) do
    Jason.encode!(payload)
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(datetime), do: DateTime.to_iso8601(datetime)
end
