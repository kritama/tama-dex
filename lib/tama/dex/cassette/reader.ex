defmodule Tama.Dex.Cassette.Reader do
  @moduledoc false

  # Verifies cassette files, which are untrusted input.
  #
  # The size is checked before the file is opened. The file is then read
  # once, bounded, into an in-memory snapshot, and every later check reads
  # that snapshot: the SHA-256 and the SQLite header, then SQLite itself,
  # which deserializes the snapshot into a private in-memory database. So a
  # file replaced after it was hashed can't pass the pin with other rows.
  # SQLite runs with extension loading and schema functions off and queries
  # only, and its `sqlite_master` is compared against the expected objects
  # before any row is read. Every embedded document is then re-digested and
  # validated against the profile. The operation rows are never trusted
  # here: import copies them only under a matching host pin.

  alias Exqlite.Sqlite3
  alias Tama.Dex.Cassette.Format
  alias Tama.Dex.Index.Connection
  alias Tama.Dex.Index.Job
  alias Tama.Dex.Index.SQL
  alias Tama.Dex.JSON
  alias Tama.Dex.Profile
  alias Tama.Dex.Text

  @max_bytes 64 * 1024 * 1024
  @max_names 8
  @cassette_name ~r/^[a-z][a-z0-9_]{0,63}$/
  @digest ~r/^[0-9a-f]{64}$/
  @max_version_bytes 64

  @type reason ::
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

  @doc "The largest cassette file accepted."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The checks a background import makes before returning: size, SHA-256,
  header, schema objects and manifest. Returns the file SHA-256 and the
  manifest.
  """
  @spec precheck(String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def precheck(path, opts) do
    with {:ok, snapshot} <- read_file(path, opts) do
      with_connection(snapshot, &prechecked(&1, snapshot.sha256), fn _conn, checked ->
        {:ok, checked}
      end)
    end
  end

  @doc """
  Verifies a cassette in full. Returns the manifest, the validated
  documents ordered by source and the file SHA-256.

  Options: `:sha256` (a pin), `:max_bytes` (a lower size limit), `:limits`
  (the profile limits documents are validated under) and `:job` (a tracked
  import, whose deadline is checked between documents).
  """
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def verify(path, opts), do: with_verified(path, opts, fn _conn, verified -> {:ok, verified} end)

  @doc """
  Verifies a cassette as `verify/2` does, then calls `fun.(conn, verified)`
  with the cassette's query-only connection still open, so its rows are read
  from the snapshot that was verified. Returns `fun`'s result, or
  `{:error, reason}`.
  """
  @spec with_verified(String.t(), keyword(), (SQL.conn(), map() -> result)) ::
          result | {:error, reason()}
        when result: term()
  def with_verified(path, opts, fun) do
    with {:ok, snapshot} <- read_file(path, opts) do
      with_connection(snapshot, &verified(&1, snapshot.sha256, opts), fun)
    end
  end

  defp prechecked(conn, sha256) do
    with :ok <- check_cassette_objects(conn),
         {:ok, manifest} <- read_manifest(conn) do
      {:ok, %{sha256: sha256, manifest: manifest}}
    end
  end

  defp verified(conn, sha256, opts) do
    with :ok <- check_cassette_objects(conn),
         :ok <- quick_check(conn),
         {:ok, manifest} <- read_manifest(conn),
         :ok <- check_index_objects(conn, manifest),
         {:ok, documents} <- read_documents(conn, manifest, opts),
         :ok <- check_content_digest(manifest, documents) do
      {:ok, %{manifest: manifest, documents: documents, sha256: sha256}}
    end
  end

  # File checks

  defp read_file(path, opts) do
    max = min(Keyword.get(opts, :max_bytes, @max_bytes), @max_bytes)

    with :ok <- check_size(path, max),
         {:ok, bytes} <- read_bounded(path, max),
         sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
         :ok <- check_pin(sha256, Keyword.get(opts, :sha256)),
         :ok <- check_header(bytes) do
      {:ok, %{bytes: bytes, sha256: sha256}}
    end
  end

  # Reads at most one byte past `max`, so a file that grew after its size
  # was checked is still refused without reading it all.
  defp read_bounded(path, max) do
    case File.open(path, [:read, :binary, :raw], &:file.read(&1, max + 1)) do
      {:ok, {:ok, bytes}} when byte_size(bytes) <= max -> {:ok, bytes}
      {:ok, {:ok, _bytes}} -> {:error, :too_large}
      {:ok, :eof} -> {:ok, <<>>}
      {:ok, {:error, posix}} -> {:error, {:file, posix}}
      {:error, posix} -> {:error, {:file, posix}}
    end
  end

  defp check_size(path, max) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, :too_large}
      {:ok, %File.Stat{}} -> {:error, :not_a_cassette}
      {:error, posix} -> {:error, {:file, posix}}
    end
  end

  @doc "The lowercase hex SHA-256 of a file."
  @spec sha256(String.t()) :: {:ok, String.t()} | {:error, {:file, File.posix()}}
  def sha256(path) do
    case File.open(path, [:read, :binary, :raw], &hash(&1, :crypto.hash_init(:sha256))) do
      {:ok, digest} -> {:ok, Base.encode16(digest, case: :lower)}
      {:error, posix} -> {:error, {:file, posix}}
    end
  end

  defp hash(file, state) do
    case IO.binread(file, 1024 * 1024) do
      :eof -> :crypto.hash_final(state)
      data when is_binary(data) -> hash(file, :crypto.hash_update(state, data))
    end
  end

  defp check_pin(_sha256, nil), do: :ok
  defp check_pin(sha256, sha256), do: :ok
  defp check_pin(_sha256, _pin), do: {:error, :sha256_mismatch}

  # A SQLite file in rollback-journal mode, as `Tama.Dex.Cassette.build/3`
  # writes it. A cassette is never in WAL mode.
  defp check_header(
         <<"SQLite format 3", 0, _page::binary-size(2), 1, 1, _rest::binary-size(80),
           _pages::binary>>
       ),
       do: :ok

  defp check_header(_bytes), do: {:error, :not_a_cassette}

  # Connection

  # Runs `check` on the open cassette, treating SQLite errors as a corrupt
  # file, then `then` with the checked result. Errors from `then` are its
  # own.
  defp with_connection(snapshot, check, then) do
    case open(snapshot.bytes) do
      {:ok, conn} ->
        try do
          case checked(check, conn) do
            {:ok, checked} -> then.(conn, checked)
            {:error, _reason} = error -> error
          end
        after
          Sqlite3.close(conn)
        end

      :error ->
        {:error, :not_a_cassette}
    end
  end

  defp checked(check, conn) do
    check.(conn)
  rescue
    SQL.Error -> {:error, :not_a_cassette}
  end

  # A private in-memory database holding a copy of the snapshot.
  defp open(bytes) do
    {:ok, conn} = Sqlite3.open(":memory:")
    _result = Sqlite3.enable_load_extension(conn, false)

    case Sqlite3.deserialize(conn, "main", bytes) do
      :ok ->
        SQL.execute!(conn, "PRAGMA trusted_schema = OFF")
        SQL.execute!(conn, "PRAGMA query_only = ON")
        {:ok, conn}

      {:error, _reason} ->
        Sqlite3.close(conn)
        :error
    end
  end

  # Schema objects

  defp objects(conn) do
    conn
    |> SQL.query!("SELECT type, name, tbl_name, sql FROM sqlite_master")
    |> Enum.map(&Format.object/1)
  end

  # No triggers or views, and the manifest and document tables exactly as
  # this code defines them.
  defp check_cassette_objects(conn) do
    objects = objects(conn)
    expected = Format.cassette_objects()

    unexpected =
      Enum.filter(objects, fn {type, _name, _table, _sql} = object ->
        type in ["trigger", "view"] or
          (cassette_table?(object) and object not in expected)
      end)

    missing = expected -- objects

    case unexpected ++ missing do
      [] -> :ok
      objects -> unexpected_schema(objects)
    end
  end

  defp cassette_table?({_type, _name, table, _sql}),
    do: table in ["cassette_manifest", "cassette_documents"]

  # A cassette of this index schema version must hold exactly the expected
  # objects, since import may copy its rows. Any other version is read only
  # through its manifest and documents.
  defp check_index_objects(conn, %{index_schema_version: version}) do
    if version == Connection.schema_version() do
      objects = Enum.sort(objects(conn))
      expected = Format.expected_objects()

      case (objects -- expected) ++ (expected -- objects) do
        [] -> :ok
        objects -> unexpected_schema(objects)
      end
    else
      :ok
    end
  end

  defp unexpected_schema(objects) do
    names =
      objects
      |> Enum.map(fn {_type, name, _table, _sql} -> name(name) end)
      |> Enum.uniq()
      |> Enum.take(@max_names)

    {:error, {:unexpected_schema, names}}
  end

  defp name(name) when is_binary(name) do
    if String.valid?(name), do: Text.bound(name, 64), else: "(invalid name)"
  end

  defp name(_name), do: "(invalid name)"

  defp quick_check(conn) do
    case SQL.query!(conn, "PRAGMA quick_check") do
      [["ok"]] -> :ok
      _problems -> {:error, :not_a_cassette}
    end
  end

  # Manifest

  defp read_manifest(conn) do
    conn
    |> SQL.query!("""
    SELECT format, name, version, tama_dex_version, index_schema_version, sqlite_version,
           profile, content_digest
    FROM cassette_manifest
    """)
    |> manifest()
  end

  defp manifest([[format, name, version, tama_dex, schema, sqlite, profile, digest]]) do
    texts = [format, name, version, tama_dex, sqlite, profile, digest]

    if Enum.all?(texts, &text?/1) and format == Format.format() and
         profile == Profile.profile() and is_integer(schema) and
         Regex.match?(@cassette_name, name) and Regex.match?(@digest, digest) and
         version != "" and byte_size(version) <= @max_version_bytes do
      {:ok,
       %{
         format: format,
         name: name,
         version: version,
         tama_dex_version: Text.bound(tama_dex, @max_version_bytes),
         index_schema_version: schema,
         sqlite_version: Text.bound(sqlite, @max_version_bytes),
         profile: profile,
         content_digest: digest
       }}
    else
      {:error, :invalid_manifest}
    end
  end

  defp manifest(_rows), do: {:error, :invalid_manifest}

  defp text?(value), do: is_binary(value) and String.valid?(value)

  # Documents

  defp read_documents(conn, manifest, opts) do
    job = Keyword.get(opts, :job)
    limits = Keyword.get(opts, :limits, [])

    rows =
      SQL.query!(conn, "SELECT source, digest, document FROM cassette_documents ORDER BY source")

    result =
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, documents} ->
        Job.checkpoint(job)

        case document(row, manifest, limits) do
          {:ok, document} -> {:cont, {:ok, [document | documents]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, documents} <- result do
      documents = Enum.reverse(documents)

      cond do
        documents == [] ->
          {:error, :invalid_manifest}

        (conflicts = Format.duplicate_operations(documents)) != [] ->
          {:error, {:duplicate_operation, conflicts}}

        true ->
          {:ok, documents}
      end
    end
  end

  defp document([source, digest, text], manifest, limits) do
    with true <- text?(source) and text?(digest) and is_binary(text),
         ^digest <- JSON.sha256(text),
         {:ok, decoded} <- Jason.decode(text),
         {:ok, document} <- validate(source, decoded, limits),
         true <-
           document.source == source and document.digest == digest and
             document.profile == manifest.profile do
      {:ok, document}
    else
      {:error, {:invalid_document, _source, _issues}} = error -> error
      _mismatch -> {:error, {:document_digest_mismatch, name(source)}}
    end
  end

  defp validate(source, decoded, limits) do
    case Profile.validate(decoded, limits: limits) do
      {:ok, document} -> {:ok, document}
      {:error, issues} -> {:error, {:invalid_document, name(source), issues}}
    end
  end

  defp check_content_digest(manifest, documents) do
    digest =
      Format.content_digest(
        manifest.name,
        manifest.version,
        manifest.index_schema_version,
        Enum.map(documents, &{&1.source, &1.digest})
      )

    if digest == manifest.content_digest, do: :ok, else: {:error, :content_digest_mismatch}
  end
end
