defmodule SilentRegression.Providers.Adapter do
  @moduledoc """
  Provider-neutral contract for credential validation.

  Implementations return bounded, content-free provenance and never expose
  provider response bodies, request headers, or submitted credentials.
  """

  alias SilentRegression.Providers.{CredentialValidation, Failure}

  @callback request_provenance() :: %{
              required(:api_endpoint) => String.t(),
              required(:api_version) => String.t(),
              required(:http_method) => String.t()
            }

  @callback validate_credential(String.t(), keyword()) ::
              {:ok, CredentialValidation.t()} | {:error, Failure.t()}
end
