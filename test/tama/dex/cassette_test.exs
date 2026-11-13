defmodule Tama.Dex.CassetteTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Tama.Dex.TestSupport.Cassettes
  import Tama.Dex.TestSupport.Documents

  alias Exqlite.Sqlite3
  alias Tama.Dex.Cassette
  alias Tama.Dex.Cassette.Reader
  alias Tama.Dex.Index.SQL
  alias Tama.Dex.JSON
  alias Tama.Dex.TestSupport.FakeProducer

  @moduletag :tmp_dir

  defp rows(path, sql) do
    {:ok, conn} = Sqlite3.open(path, mode: :readonly)

    try do
      SQL.query!(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end

  describe "build/3" do
    test "writes one cassette holding every source", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")

      assert built.cassette == "opsmaru_incus"
      assert built.version == "0.2.0"
      assert built.path == Path.join(dir, "opsmaru_incus-0.2.0.tama-cassette")

      assert built.sources == [
               %{source: "opsmaru_incus", operations: 4},
               %{source: "opsmaru_native", operations: 1}
             ]

      assert built.sha256 == sha256!(built.path)
      assert built.digest =~ ~r/^[0-9a-f]{64}$/

      assert [
               [
                 "tama-cassette/1",
                 "opsmaru_incus",
                 "0.2.0",
                 _tama_dex,
                 1,
                 _sqlite,
                 profile,
                 digest
               ]
             ] =
               rows(built.path, "SELECT * FROM cassette_manifest")

      assert profile == "tama-operations/1"
      assert digest == built.digest

      assert rows(built.path, "SELECT DISTINCT cassette FROM operations") == [["opsmaru_incus"]]
      assert rows(built.path, "SELECT count(*) FROM operations_fts") == [[5]]

      assert rows(built.path, "SELECT source FROM cassette_documents ORDER BY source") ==
               [["opsmaru_incus"], ["opsmaru_native"]]
    end

    test "stores no wall-clock time", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")

      assert rows(built.path, "SELECT DISTINCT loaded_at FROM cassettes") == [
               ["1970-01-01T00:00:00Z"]
             ]

      assert rows(built.path, "SELECT DISTINCT loaded_at FROM sources") == [
               ["1970-01-01T00:00:00Z"]
             ]
    end

    test "the same documents give the same content digest", %{tmp_dir: dir} do
      first = incus!(dir, "0.2.0")
      File.rename!(first.path, first.path <> ".first")
      second = incus!(dir, "0.2.0")

      assert first.digest == second.digest

      assert {:ok, %{content_digest: digest}} = Cassette.verify(first.path <> ".first")
      assert digest == second.digest

      refute incus!(dir, "0.2.1").digest == first.digest
    end

    test "leaves no temporary file, and replaces an existing file", %{tmp_dir: dir} do
      incus!(dir, "0.2.0")
      incus!(dir, "0.2.0")

      assert File.ls!(dir) == ["opsmaru_incus-0.2.0.tama-cassette"]
    end

    test "rejects invalid documents and repeats before writing", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.tama-cassette")
      valid = document("acme", ["acme_get"])

      assert {:error, {:invalid_document, 1, [_issue | _rest]}} =
               Cassette.build([valid, %{"openapi" => "3.1.0"}], path, name: "acme", version: "1")

      assert {:error, {:duplicate_source, "acme"}} =
               Cassette.build([valid, document("acme", ["acme_list"])], path,
                 name: "acme",
                 version: "1"
               )

      assert {:error, {:duplicate_operation, [%{source: "other", operation_ids: ["acme_get"]}]}} =
               Cassette.build([valid, document("other", ["acme_get", "other_get"])], path,
                 name: "acme",
                 version: "1"
               )

      assert File.ls!(dir) == []
    end

    test "rejects an empty document list", %{tmp_dir: dir} do
      path = Path.join(dir, "empty.tama-cassette")

      assert Cassette.build([], path, name: "acme", version: "1") == {:error, :no_documents}
      assert File.ls!(dir) == []
    end

    test "rejects a file verification would refuse, keeping the destination", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")
      sha256 = sha256!(built.path)

      assert Cassette.build([document("acme", ["acme_get"])], built.path,
               name: "acme",
               version: "1",
               max_bytes: 1024
             ) == {:error, :too_large}

      assert File.ls!(dir) == ["opsmaru_incus-0.2.0.tama-cassette"]
      assert sha256!(built.path) == sha256
    end

    test "requires a valid name and version", %{tmp_dir: dir} do
      path = Path.join(dir, "acme.tama-cassette")
      documents = [document("acme", ["acme_get"])]

      assert_raise ArgumentError, fn -> Cassette.build(documents, path, version: "1") end

      assert_raise ArgumentError, fn ->
        Cassette.build(documents, path, name: "Acme", version: "1")
      end

      assert_raise ArgumentError, fn -> Cassette.build(documents, path, name: "acme") end

      assert_raise ArgumentError, fn ->
        Cassette.build(documents, path, name: "acme", version: String.duplicate("1", 65))
      end
    end
  end

  describe "verify/2" do
    test "returns the manifest of a valid cassette", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")

      assert {:ok, manifest} = Cassette.verify(built.path, sha256: built.sha256)

      assert %{
               format: "tama-cassette/1",
               name: "opsmaru_incus",
               version: "0.2.0",
               index_schema_version: 1,
               profile: "tama-operations/1",
               sha256: sha256,
               sources: [
                 %{source: "opsmaru_incus", operations: 4},
                 %{source: "opsmaru_native", operations: 1}
               ]
             } = manifest

      assert manifest.content_digest == built.digest
      assert sha256 == built.sha256
      assert {:ok, _manifest} = Cassette.verify(built.path, sha256: String.upcase(built.sha256))
    end

    test "reads the file once, so replacing it afterwards changes nothing", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")
      other = bulk!(dir, "other", 3)

      assert {:ok, ids} =
               Reader.with_verified(built.path, [sha256: built.sha256], fn
                 conn, verified ->
                   # Swap in another cassette after the pinned bytes were read.
                   File.cp!(other.path, built.path)

                   ids = SQL.query!(conn, "SELECT operation_id FROM operations ORDER BY 1")
                   {:ok, {verified.sha256, ids}}
               end)

      assert {sha256, [["incus_image_delete"] | _rest] = rows} = ids
      assert sha256 == built.sha256
      assert length(rows) == 5
      assert sha256!(built.path) == other.sha256
    end

    test "rejects a file that doesn't match its pin", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")

      assert Cassette.verify(built.path, sha256: String.duplicate("0", 64)) ==
               {:error, :sha256_mismatch}

      assert_raise ArgumentError, fn -> Cassette.verify(built.path, sha256: "abc") end
    end

    test "rejects an oversized file before opening it", %{tmp_dir: dir} do
      path = Path.join(dir, "huge.tama-cassette")
      {:ok, file} = :file.open(String.to_charlist(path), [:write, :raw])
      {:ok, _position} = :file.position(file, 64 * 1024 * 1024)
      :ok = :file.write(file, "x")
      :ok = :file.close(file)

      assert Cassette.verify(path) == {:error, :too_large}

      built = incus!(dir, "0.2.0")
      assert Cassette.verify(built.path, max_bytes: 1024) == {:error, :too_large}
    end

    test "rejects files that aren't cassettes", %{tmp_dir: dir} do
      text = Path.join(dir, "text.tama-cassette")
      File.write!(text, String.duplicate("not sqlite ", 20))

      assert Cassette.verify(text) == {:error, :not_a_cassette}
      assert Cassette.verify(Path.join(dir, "missing")) == {:error, {:file, :enoent}}
      assert Cassette.verify(dir) == {:error, :not_a_cassette}

      wal = Path.join(dir, "wal.tama-cassette")
      tamper!(wal, ["PRAGMA journal_mode = WAL", "CREATE TABLE t (x)"])
      assert Cassette.verify(wal) == {:error, :not_a_cassette}

      empty = Path.join(dir, "empty.tama-cassette")
      tamper!(empty, "CREATE TABLE t (x)")
      assert {:error, {:unexpected_schema, _names}} = Cassette.verify(empty)
    end

    test "rejects a trigger or view before reading any row", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")

      trigger =
        tamper!(built.path, """
        CREATE TRIGGER grant AFTER INSERT ON operations BEGIN
          UPDATE operations SET scopes = '[]';
        END
        """)

      assert Cassette.verify(trigger) == {:error, {:unexpected_schema, ["grant"]}}

      view = incus!(dir, "0.2.1").path
      tamper!(view, "CREATE VIEW everything AS SELECT * FROM operations")
      assert Cassette.verify(view) == {:error, {:unexpected_schema, ["everything"]}}
    end

    test "rejects extra tables and altered definitions", %{tmp_dir: dir} do
      extra = tamper!(incus!(dir, "0.2.0").path, "CREATE TABLE extra (x)")
      assert Cassette.verify(extra) == {:error, {:unexpected_schema, ["extra"]}}

      altered =
        tamper!(incus!(dir, "0.2.1").path, [
          "DROP TABLE cassette_documents",
          "CREATE TABLE cassette_documents (source TEXT, digest TEXT, document TEXT)"
        ])

      # The new table also lacks the primary key's index.
      assert Cassette.verify(altered) ==
               {:error,
                {:unexpected_schema,
                 ["cassette_documents", "sqlite_autoindex_cassette_documents_1"]}}
    end

    test "rejects an altered embedded document", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")

      tamper!(built.path, [
        {"UPDATE cassette_documents SET document = replace(document, 'incus.delete', 'incus.read') WHERE source = ?",
         ["opsmaru_incus"]}
      ])

      assert Cassette.verify(built.path) ==
               {:error, {:document_digest_mismatch, "opsmaru_incus"}}
    end

    test "rejects a re-digested document that isn't valid", %{tmp_dir: dir} do
      built = incus!(dir, "0.2.0")
      text = ~s({"openapi":"3.1.0"})
      digest = JSON.sha256(text)

      tamper!(built.path, [
        {"UPDATE cassette_documents SET document = ?, digest = ? WHERE source = ?",
         [text, digest, "opsmaru_native"]}
      ])

      assert {:error, {:invalid_document, "opsmaru_native", [_issue | _rest]}} =
               Cassette.verify(built.path)
    end

    test "rejects a malformed manifest or content digest", %{tmp_dir: dir} do
      digest = tamper!(incus!(dir, "1").path, "UPDATE cassette_manifest SET version = 'other'")
      assert Cassette.verify(digest) == {:error, :content_digest_mismatch}

      format =
        tamper!(incus!(dir, "2").path, "UPDATE cassette_manifest SET format = 'tama-cassette/2'")

      assert Cassette.verify(format) == {:error, :invalid_manifest}

      name = tamper!(incus!(dir, "3").path, "UPDATE cassette_manifest SET name = 'Bad Name'")
      assert Cassette.verify(name) == {:error, :invalid_manifest}

      two =
        tamper!(
          incus!(dir, "4").path,
          "INSERT INTO cassette_manifest SELECT * FROM cassette_manifest"
        )

      assert Cassette.verify(two) == {:error, :invalid_manifest}

      none = tamper!(incus!(dir, "5").path, "DELETE FROM cassette_documents")
      assert Cassette.verify(none) == {:error, :invalid_manifest}
    end
  end

  describe "mix tama.dex.cassette" do
    test "builds one cassette from module functions and files", %{tmp_dir: dir} do
      native = Path.join(dir, "acme-native.json")
      File.write!(native, Jason.encode!(document("acme_native", ["acme_native_status"])))
      output = Path.join(dir, "acme-1.0.0.tama-cassette")

      out =
        capture_io(fn ->
          Mix.Tasks.Tama.Dex.Cassette.run([
            "--name",
            "acme",
            "--version",
            "1.0.0",
            "--document",
            "#{inspect(FakeProducer)}.document",
            "--file",
            native,
            "--output",
            output
          ])
        end)

      assert {:ok, manifest} = Cassette.verify(output)
      assert manifest.name == "acme"
      assert Enum.map(manifest.sources, & &1.source) == ["acme", "acme_native"]
      assert out =~ "content digest: #{manifest.content_digest}"
      assert out =~ "sha256: #{manifest.sha256}"
    end

    test "fails clearly on bad arguments", %{tmp_dir: dir} do
      output = Path.join(dir, "acme.tama-cassette")
      base = ["--name", "acme", "--version", "1", "--output", output]
      bad_json = Path.join(dir, "bad.json")
      File.write!(bad_json, "{")

      for {args, message} <- [
            {base, ~r/at least one/},
            {["--version", "1", "--output", output, "--file", bad_json], ~r/--name is required/},
            {base ++ ["--file", bad_json], ~r/is not JSON/},
            {base ++ ["--file", Path.join(dir, "missing.json")], ~r/can't be read/},
            {base ++ ["--document", "NoSuch.Module.fun"], ~r/not a zero-arity function/},
            {base ++ ["--document", "nodot"], ~r/not a zero-arity function/},
            {base ++ ["--bogus"], ~r/unexpected arguments/}
          ] do
        assert_raise Mix.Error, message, fn -> Mix.Tasks.Tama.Dex.Cassette.run(args) end
      end

      invalid = Path.join(dir, "invalid.json")
      File.write!(invalid, ~s({"openapi": "3.1.0"}))

      assert_raise Mix.Error, ~r/invalid.json is not a valid profile document/, fn ->
        Mix.Tasks.Tama.Dex.Cassette.run(base ++ ["--file", invalid])
      end

      refute File.exists?(output)
    end
  end
end
