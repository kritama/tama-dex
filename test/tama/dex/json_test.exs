defmodule Tama.Dex.JSONTest do
  use ExUnit.Case, async: true

  alias Tama.Dex.JSON
  alias Tama.Dex.Profile.Issue

  test "pointers escape ~ and / and resolve back" do
    document = %{"a/b" => %{"c~d" => [10, 20, %{"e" => true}]}}
    pointer = JSON.pointer(["a/b", "c~d", 2, "e"])

    assert pointer == "/a~1b/c~0d/2/e"
    assert JSON.resolve(document, pointer) == {:ok, true}
    assert JSON.resolve(document, "") == {:ok, document}
    assert JSON.pointer([]) == ""
  end

  test "pointers that lead nowhere do not resolve" do
    document = %{"list" => [1, 2], "value" => "x"}

    assert JSON.resolve(document, "/missing") == :error
    assert JSON.resolve(document, "/list/2") == :error
    assert JSON.resolve(document, "/list/-1") == :error
    assert JSON.resolve(document, "/list/one") == :error
    assert JSON.resolve(document, "/value/inner") == :error
    assert JSON.resolve(document, "relative") == :error
  end

  test "canonical JSON sorts keys at every level" do
    assert JSON.encode!(%{"b" => [%{"z" => 1, "a" => 2}], "a" => nil}) ==
             ~s({"a":null,"b":[{"a":2,"z":1}]})
  end

  test "issue messages are cut to 256 bytes on a character boundary" do
    message = String.duplicate("a", 252) <> String.duplicate("é", 10)
    issue = Issue.new("", :invalid_field, message)

    assert byte_size(issue.message) <= 256
    assert String.valid?(issue.message)
    assert String.ends_with?(issue.message, "...")

    ascii = Issue.new("", :invalid_field, String.duplicate("a", 300))
    assert ascii.message == String.duplicate("a", 253) <> "..."
  end
end
