defmodule Tama.Dex.Cassette do
  @moduledoc """
  Builds and verifies cassettes: portable, prebuilt index files in the
  `tama-cassette/1` format, each holding one cassette.

  A producer's CI builds a cassette from its profile documents, usually with
  `mix tama.dex.cassette`, and publishes it with its SHA-256. A host
  installs it with `Tama.Dex.import/3` from a local file it supplies.
  tama-dex never downloads cassettes.

  A cassette holds the index's storage tables for its one cassette, a
  manifest (format, cassette name and version, tama-dex version, index
  schema version, SQLite version, profile and content digest) and each
  source's canonical document with its digest. It stores no wall-clock time.

  ## Identity

  The content digest covers the format, the cassette name and version, the
  index schema version and each source's document digest. Building the same
  documents again gives the same content digest, even where SQLite writes
  different bytes, so the content digest identifies a cassette and the file
  SHA-256 pins one file.

  ## Trust

  `verify/2` treats a cassette as untrusted. Its prebuilt rows are copied
  into an index only when the host pins the file's SHA-256 (see
  `Tama.Dex.import/3`). Otherwise the index is rebuilt from the embedded
  documents after their digests and profile validity are checked.
  """

  alias Exqlite.Sqlite3
  alias Tama.Dex.Cassette.Format
  alias Tama.Dex.Cassette.Reader
  alias Tama.Dex.Index.Connection
  alias Tama.Dex.Index.SQL
  alias Tama.Dex.Index.Store
  alias Tama.Dex.Profile

  @max_version_bytes 64

  @type manifest :: %{
          format: String.t(),
          name: String.t(),
          version: String.t(),
          tama_dex_version: String.t(),
          index_schema_version: integer(),
          sqlite_version: String.t(),
          profile: String.t(),
          content_digest: String.t(),
          sha256: String.t(),
          sources: [%{source: String.t(), digest: String.t(), operations: non_neg_integer()}]
        }

  @typedoc """
  Why a cassette was rejected. Names and sources read from the file are
  bounded.

  - `{:file, posix}`: the file can't be read.
  - `:too_large`: over 64 MiB, checked before the file is opened.
  - `:sha256_mismatch`: the file doesn't match the host's pin.
  - `:not_a_cassette`: not a SQLite file in rollback-journal mode, or
    corrupt.
  - `{:unexpected_schema, names}`: triggers, views, or tables and indexes
    other than the expected ones, checked before any row is read.
  - `:invalid_manifest`: a missing or malformed manifest, or no documents.
  - `{:document_digest_mismatch, source}`: an embedded document doesn't
    match its digest.
  - `{:invalid_document, source, issues}`: an embedded document isn't a
    valid profile document.
  - `{:duplicate_operation, conflicts}`: sources sharing operation IDs.
  - `:content_digest_mismatch`: the manifest's content digest is wrong.
  """
  @type verify_error ::
          {:file, File.posix()}
          | :too_large
          | :sha256_mismatch
          | :not_a_cassette
          | {:unexpected_schema, [String.t()]}
          | :invalid_manifest
          | {:document_digest_mismatch, String.t()}
          | {:invalid_document, String.t(), [Profile.Issue.t()]}
          | {:duplicate_operation, [map()]}
          | :content_digest_mismatch

  @type build_error ::
          :no_documents
          | :too_large
          | {:invalid_document, non_neg_integer(), [Profile.Issue.t()]}
          | {:duplicate_source, String.t()}
          | {:duplicate_operation, [%{source: String.t(), operation_ids: [String.t()]}]}

  @doc """
  Builds a cassette file at `path` from profile documents.

  Every document is validated first, and sources or operation IDs repeated
  within the cassette are rejected, before anything is written. The file is
  written to a temporary file in the same directory, compacted with
  `VACUUM` and renamed into place, replacing any file at `path`. A file
  larger than `verify/2` accepts is discarded instead, leaving `path`
  untouched.

  ## Options

  - `:name` (required): the cassette name, matching `^[a-z][a-z0-9_]{0,63}$`.
  - `:version` (required): the cassette version, at most 64 bytes, usually
    the producer's release version.
  - `:max_bytes`: a lower size limit than the 64 MiB `verify/2` accepts.

  Returns `{:ok, %{path, cassette, version, digest, sha256, sources}}`,
  where `digest` is the content digest, `sha256` the file's SHA-256, and
  each source has `source` and `operations` (a count). Fails with
  `{:error, :no_documents}` for an empty list,
  `{:error, {:invalid_document, position, issues}}` (position counts from
  0), `{:error, {:duplicate_source, source}}`,
  `{:error, {:duplicate_operation, conflicts}}`, or `{:error, :too_large}`
  when the file would be over the size limit. Raises `ArgumentError` for
  a missing or invalid name, version or path.
  """
  @spec build([term()], Path.t(), keyword()) :: {:ok, map()} | {:error, build_error()}
  def build(documents, path, opts) when is_list(documents) do
    name = Tama.Dex.cassette!(Keyword.get(opts, :name))
    version = version!(Keyword.get(opts, :version))
    path = path!(path)
    max = min(max_bytes!(opts), Reader.max_bytes())

    with :ok <- non_empty(documents),
         {:ok, validated} <- validate(documents),
         :ok <- unique_sources(validated),
         :ok <- unique_operations(validated) do
      write(validated, path, name, version, max)
    end
  end

  @doc """
  Verifies a cassette file without installing it.

  Checks, in order: the size (64 MiB at most) before opening, the file
  SHA-256 against `:sha256` when given, the SQLite header, the schema
  objects (no triggers or views, and exactly the expected tables and
  indexes), the database's integrity, the manifest, every embedded
  document's digest and profile validity, and the content digest. The file
  is read once, into memory, and every check reads that copy, so a file
  replaced during verification can't pass with other contents. SQLite opens
  the copy as a private in-memory database, with extension loading off and
  queries only.

  ## Options

  - `:sha256`: the expected lowercase hex SHA-256 of the file.
  - `:max_bytes`: a lower size limit.

  Returns `{:ok, manifest}`, with the file's `sha256` and its `sources`,
  or `{:error, reason}` (see `t:verify_error/0`).
  """
  @spec verify(Path.t(), keyword()) :: {:ok, manifest()} | {:error, verify_error()}
  def verify(path, opts \\ []) do
    path = path!(path)

    case Reader.verify(path,
           sha256: sha256!(Keyword.get(opts, :sha256)),
           max_bytes: max_bytes!(opts)
         ) do
      {:ok, verified} ->
        sources =
          Enum.map(verified.documents, fn document ->
            %{
              source: document.source,
              digest: document.digest,
              operations: length(document.operations)
            }
          end)

        {:ok, Map.merge(verified.manifest, %{sha256: verified.sha256, sources: sources})}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec sha256!(term()) :: String.t() | nil
  def sha256!(nil), do: nil

  def sha256!(pin) when is_binary(pin) do
    pin = String.downcase(pin)

    if Regex.match?(~r/^[0-9a-f]{64}$/, pin) do
      pin
    else
      raise ArgumentError, ":sha256 must be a hex SHA-256 of 64 characters"
    end
  end

  def sha256!(_pin), do: raise(ArgumentError, ":sha256 must be a hex SHA-256 of 64 characters")

  @doc false
  @spec path!(term()) :: String.t()
  def path!(path) when is_binary(path) and path != "", do: Path.expand(path)

  def path!(path),
    do: raise(ArgumentError, "a cassette path must be a string, got: #{inspect(path)}")

  defp max_bytes!(opts) do
    case Keyword.get(opts, :max_bytes, Reader.max_bytes()) do
      max when is_integer(max) and max > 0 -> max
      max -> raise ArgumentError, ":max_bytes must be a positive integer, got: #{inspect(max)}"
    end
  end

  defp version!(version) do
    if is_binary(version) and version != "" and byte_size(version) <= @max_version_bytes and
         String.valid?(version) do
      version
    else
      raise ArgumentError,
            "a cassette :version of 1 to #{@max_version_bytes} bytes is required, got: #{inspect(version)}"
    end
  end

  # Build

  defp non_empty([]), do: {:error, :no_documents}
  defp non_empty(_documents), do: :ok

  defp validate(documents) do
    documents
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {document, position}, {:ok, validated} ->
      case Profile.validate(document) do
        {:ok, document} -> {:cont, {:ok, [document | validated]}}
        {:error, issues} -> {:halt, {:error, {:invalid_document, position, issues}}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp unique_sources(documents) do
    case documents |> Enum.map(& &1.source) |> duplicates() do
      [] -> :ok
      [source | _rest] -> {:error, {:duplicate_source, source}}
    end
  end

  defp duplicates(list), do: list -- Enum.uniq(list)

  defp unique_operations(documents) do
    case Format.duplicate_operations(documents) do
      [] -> :ok
      conflicts -> {:error, {:duplicate_operation, conflicts}}
    end
  end

  defp write(documents, path, name, version, max) do
    documents = Enum.sort_by(documents, & &1.source)

    digest =
      Format.content_digest(
        name,
        version,
        Connection.schema_version(),
        Enum.map(documents, &{&1.source, &1.digest})
      )

    temporary =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    try do
      write_file(temporary, documents, name, version, digest)

      if File.stat!(temporary).size > max do
        {:error, :too_large}
      else
        File.rename!(temporary, path)
        {:ok, sha256} = Reader.sha256(path)

        {:ok,
         %{
           path: path,
           cassette: name,
           version: version,
           digest: digest,
           sha256: sha256,
           sources: Enum.map(documents, &%{source: &1.source, operations: length(&1.operations)})
         }}
      end
    after
      File.rm(temporary)
    end
  end

  defp write_file(temporary, documents, name, version, digest) do
    {:ok, conn} = Sqlite3.open(temporary)

    try do
      _result = Sqlite3.enable_load_extension(conn, false)
      SQL.execute!(conn, "PRAGMA foreign_keys = ON")

      SQL.transaction(conn, fn ->
        Connection.create_tables(conn)
        Format.create_tables(conn)
        write_rows(conn, documents, name, version, digest)
        {:commit, :ok}
      end)

      SQL.execute!(conn, "VACUUM")
    after
      Sqlite3.close(conn)
    end
  end

  defp write_rows(conn, documents, name, version, digest) do
    SQL.run!(
      conn,
      """
      INSERT INTO cassettes (cassette, kind, version, content_digest, loaded_at)
      VALUES (?, 'imported', ?, ?, ?)
      """,
      [name, version, digest, Format.epoch()]
    )

    for document <- documents do
      Store.write_source(conn, name, document, Format.epoch())

      SQL.run!(
        conn,
        "INSERT INTO cassette_documents (source, digest, document) VALUES (?, ?, ?)",
        [document.source, document.digest, document.canonical_json]
      )
    end

    [[sqlite_version]] = SQL.query!(conn, "SELECT sqlite_version()")

    SQL.run!(
      conn,
      """
      INSERT INTO cassette_manifest (
        format, name, version, tama_dex_version, index_schema_version, sqlite_version,
        profile, content_digest
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        Format.format(),
        name,
        version,
        tama_dex_version(),
        Connection.schema_version(),
        sqlite_version,
        Profile.profile(),
        digest
      ]
    )
  end

  defp tama_dex_version do
    case Application.spec(:tama_dex, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end
end
