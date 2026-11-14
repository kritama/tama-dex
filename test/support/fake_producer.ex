defmodule Tama.Dex.TestSupport.FakeProducer do
  @moduledoc false

  # Stands in for a producer library such as opsmaru_incus. It publishes a
  # profile document as data and runs its own operations, taking host-only
  # arguments. It must not reference any tama_dex module.

  def document do
    %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "Acme operations", "version" => "0.1.0"},
      "x-tama-profile" => "tama-operations/1",
      "x-tama-source" => "acme",
      "paths" => %{
        "/operations/acme_widget_get" => %{
          "post" => %{
            "operationId" => "acme_widget_get",
            "summary" => "Get a widget",
            "description" => "Get a widget by ID.",
            "x-tama-scopes" => ["acme.read"],
            "x-tama-destructive" => false,
            "requestBody" => %{
              "required" => true,
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{"id" => %{"type" => "string"}},
                    "required" => ["id"]
                  }
                }
              }
            },
            "responses" => %{
              "200" => %{
                "description" => "The widget",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "type" => "object",
                      "properties" => %{
                        "id" => %{"type" => "string"},
                        "name" => %{"type" => "string"}
                      },
                      "required" => ["id", "name"]
                    }
                  }
                }
              },
              "default" => %{
                "description" => "An error",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "type" => "object",
                      "properties" => %{"reason" => %{"type" => "string"}},
                      "required" => ["reason"]
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  def run("acme_widget_get", %{"id" => id}, opts) do
    authorizer = Keyword.fetch!(opts, :authorizer)

    if authorizer.allow?(Keyword.fetch!(opts, :caller), Keyword.fetch!(opts, :scopes)) do
      {:ok, %{"id" => id, "name" => "Widget #{id}"}}
    else
      {:error, %{"reason" => "forbidden"}}
    end
  end
end

defmodule Tama.Dex.TestSupport.AcmeAdapter do
  @moduledoc false

  # A host adapter: translates a Tama.Dex.Call into the producer's call.

  @behaviour Tama.Dex.Executor

  alias Tama.Dex.TestSupport.FakeProducer

  @impl Tama.Dex.Executor
  def execute(%Tama.Dex.Call{} = call, input) do
    FakeProducer.run(call.operation_id, input,
      authorizer: Keyword.fetch!(call.opts, :authorizer),
      caller: call.context,
      scopes: call.scopes
    )
  end
end

defmodule Tama.Dex.TestSupport.AcmeAuthorizer do
  @moduledoc false

  def allow?(%{allowed: allowed}, scopes), do: allowed and "acme.read" in scopes
end
