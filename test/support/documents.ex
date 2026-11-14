defmodule Tama.Dex.TestSupport.Documents do
  @moduledoc false

  # Builds small valid profile documents for tests.

  @fixtures Path.expand("../fixtures", __DIR__)

  @doc "A fixture document, decoded."
  def fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  @doc """
  A valid document for `source` holding one read operation per ID.

  Options: `:version` (the `info.version`), `:summary` (a function of the
  ID) and `:property` (an extra input property name, to vary the schemas).
  """
  def document(source, ids, opts \\ []) do
    summary = Keyword.get(opts, :summary, &"Operation #{&1}")
    property = Keyword.get(opts, :property, "name")

    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => "#{source} operations",
        "version" => Keyword.get(opts, :version, "1.0.0")
      },
      "x-tama-profile" => "tama-operations/1",
      "x-tama-source" => source,
      "paths" =>
        Map.new(ids, fn id ->
          {"/operations/#{id}", %{"post" => operation(id, summary.(id), property)}}
        end)
    }
  end

  defp operation(id, summary, property) do
    %{
      "operationId" => id,
      "summary" => summary,
      "description" => "Runs #{id}.",
      "tags" => ["test"],
      "x-tama-scopes" => ["test.read"],
      "x-tama-destructive" => false,
      "requestBody" => %{
        "required" => true,
        "content" => %{
          "application/json" => %{
            "schema" => %{
              "type" => "object",
              "properties" => %{
                property => %{"type" => "string", "description" => "The #{property}."}
              }
            }
          }
        }
      },
      "responses" => %{
        "200" => %{
          "description" => "Result",
          "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}
        }
      }
    }
  end
end
