defmodule Mix.Tasks.Tama.Dex.Cassette do
  @shortdoc "Builds a tama-cassette/1 file from profile documents"

  @moduledoc """
  Builds a cassette from profile documents, for a producer's CI.

      mix tama.dex.cassette --name acme --version 1.0.0 \\
        --document Acme.Operations.openapi \\
        --file priv/acme-native.json \\
        --output acme-1.0.0.tama-cassette

  ## Options

  - `--name` (required): the cassette name.
  - `--version` (required): the cassette version, usually the release
    version.
  - `--document Mod.fun`: a zero-arity function in the project's code that
    returns a profile document. Repeatable.
  - `--file path`: a profile document as a JSON file. Repeatable.
  - `--output path` (required): where to write the cassette.

  At least one `--document` or `--file` is required. The project is
  compiled first, so `--document` functions can be called. The task prints
  the content digest and the file's SHA-256 to publish with the cassette.
  See `Tama.Dex.Cassette.build/3`.
  """

  use Mix.Task

  alias Tama.Dex.Cassette

  @switches [
    name: :string,
    version: :string,
    document: :keep,
    file: :keep,
    output: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise(
        "unexpected arguments: #{Enum.map_join(rest ++ Enum.map(invalid, &elem(&1, 0)), " ", & &1)}"
      )
    end

    name = required!(opts, :name)
    version = required!(opts, :version)
    output = required!(opts, :output)
    functions = Keyword.get_values(opts, :document)
    files = Keyword.get_values(opts, :file)

    if functions == [] and files == [] do
      Mix.raise("give at least one --document Mod.fun or --file path")
    end

    if functions != [], do: Mix.Task.run("compile")

    documents = Enum.map(functions, &call!/1) ++ Enum.map(files, &read!/1)

    case Cassette.build(documents, output, name: name, version: version) do
      {:ok, built} ->
        Mix.shell().info("""
        Wrote #{built.path}
        cassette: #{built.cassette} #{built.version}
        sources: #{Enum.map_join(built.sources, ", ", &"#{&1.source} (#{&1.operations})")}
        content digest: #{built.digest}
        sha256: #{built.sha256}\
        """)

      {:error, reason} ->
        Mix.raise("cassette not built: #{describe(reason, functions ++ files)}")
    end
  end

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> Mix.raise("--#{key} is required")
    end
  end

  defp call!(spec) do
    with [module, function] <- split(spec),
         module = Module.concat([module]),
         {:module, ^module} <- Code.ensure_loaded(module),
         function = String.to_atom(function),
         true <- function_exported?(module, function, 0) do
      apply(module, function, [])
    else
      _invalid -> Mix.raise("--document #{spec} is not a zero-arity function, such as Mod.fun")
    end
  end

  defp split(spec) do
    case String.split(spec, ".") do
      [_single] -> :error
      parts -> [Enum.join(Enum.drop(parts, -1), "."), List.last(parts)]
    end
  end

  defp read!(path) do
    with {:ok, text} <- File.read(path),
         {:ok, document} <- Jason.decode(text) do
      document
    else
      {:error, %Jason.DecodeError{}} -> Mix.raise("--file #{path} is not JSON")
      {:error, reason} -> Mix.raise("--file #{path} can't be read: #{:file.format_error(reason)}")
    end
  end

  defp describe({:invalid_document, position, issues}, inputs) do
    details = Enum.map_join(Enum.take(issues, 5), "; ", &"#{&1.pointer} #{&1.message}")
    "#{Enum.at(inputs, position)} is not a valid profile document: #{details}"
  end

  defp describe({:duplicate_source, source}, _inputs), do: "source #{source} is given twice"

  defp describe({:duplicate_operation, conflicts}, _inputs) do
    "operation IDs repeat across sources: " <>
      Enum.map_join(conflicts, "; ", &"#{&1.source} #{Enum.join(&1.operation_ids, ", ")}")
  end
end
