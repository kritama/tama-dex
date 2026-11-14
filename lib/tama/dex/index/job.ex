defmodule Tama.Dex.Index.Job do
  @moduledoc false

  # The context of a tracked write: a load or import of one cassette.
  #
  # A tracked write reports progress to the index, which keeps the index's
  # readiness, and checks its deadline between steps. Deadlines are
  # cooperative: `checkpoint/1` throws once the deadline has passed, the
  # surrounding transaction rolls back, and `guard/1` turns the throw into
  # `{:unchanged, {:error, :deadline}}`. A step already running finishes
  # first, so a call returns at its first checkpoint after the deadline.

  @enforce_keys [:cassette]
  defstruct [:cassette, :index, :deadline]

  @type t :: %__MODULE__{
          cassette: String.t(),
          index: pid() | nil,
          deadline: integer() | nil
        }

  @doc "The monotonic deadline in milliseconds for a `timeout` option, or `nil`."
  @spec deadline(timeout() | nil) :: integer() | nil
  def deadline(nil), do: nil
  def deadline(:infinity), do: nil

  def deadline(timeout) when is_integer(timeout) and timeout > 0,
    do: System.monotonic_time(:millisecond) + timeout

  def deadline(timeout) do
    raise ArgumentError,
          ":timeout must be a positive integer of milliseconds, got: #{inspect(timeout)}"
  end

  @doc "Whether a deadline has passed."
  @spec expired?(integer() | nil) :: boolean()
  def expired?(nil), do: false
  def expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  @doc "Throws when the job's deadline has passed."
  @spec checkpoint(t() | nil) :: :ok
  def checkpoint(%__MODULE__{deadline: deadline}) when is_integer(deadline) do
    if expired?(deadline), do: throw({__MODULE__, :deadline}), else: :ok
  end

  def checkpoint(_job), do: :ok

  @doc "Reports progress: `done` of `total` sources."
  @spec progress(t() | nil, non_neg_integer(), non_neg_integer()) :: :ok
  def progress(%__MODULE__{index: index, cassette: cassette}, done, total) when is_pid(index) do
    send(index, {:progress, cassette, done, total})
    :ok
  end

  def progress(_job, _done, _total), do: :ok

  @doc "Runs a write, returning `{:unchanged, {:error, :deadline}}` when it passed its deadline."
  @spec guard((-> result)) :: result | {:unchanged, {:error, :deadline}} when result: term()
  def guard(fun) do
    fun.()
  catch
    :throw, {__MODULE__, :deadline} -> {:unchanged, {:error, :deadline}}
  end
end
