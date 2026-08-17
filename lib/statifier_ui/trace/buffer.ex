defmodule StatifierUI.Trace.Buffer do
  @moduledoc """
  A fixed-capacity, drop-oldest store of `%StatifierUI.Trace.Message{}`
  values - the memory-safety mechanism a chatty session needs so a notebook
  does not grow without bound (decision 8 of the plan).

  Backed by `:queue` rather than a list: `push/2` at capacity has to drop
  from the far end, and a list would make that `O(n)` on every message once
  full. `size/1` is tracked on the struct rather than derived, because
  `:queue.len/1` is itself `O(n)`.

  There is no drop notification. Every message carries a per-session
  monotonic `seq` starting at `0`, so a consumer detects loss by reading the
  first buffered message's `seq` directly - a synthetic drop message would
  itself consume a `seq` and corrupt the very counter it would be reporting
  on. `dropped/1` exists for a status line, not to replace that.
  """

  alias StatifierUI.Trace.Message

  @type t :: %__MODULE__{
          capacity: pos_integer(),
          size: non_neg_integer(),
          dropped: non_neg_integer(),
          entries: :queue.queue(Message.t())
        }

  @enforce_keys [:capacity, :size, :dropped, :entries]
  defstruct [:capacity, :size, :dropped, :entries]

  @doc """
  Builds an empty buffer holding at most `capacity` messages.

  `capacity` is a programmer argument, not an input value derived from
  external data, so a non-positive capacity raises `ArgumentError` rather
  than returning an error tuple.
  """
  @spec new(capacity :: pos_integer()) :: t()
  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{capacity: capacity, size: 0, dropped: 0, entries: :queue.new()}
  end

  def new(capacity) do
    raise ArgumentError, "capacity must be a positive integer, got: #{inspect(capacity)}"
  end

  @doc """
  Appends `message`, dropping the oldest entry when `buffer` is already at
  capacity.
  """
  @spec push(t(), Message.t()) :: t()
  def push(%__MODULE__{size: size, capacity: capacity} = buffer, %Message{} = message)
      when size < capacity do
    %{buffer | entries: :queue.in(message, buffer.entries), size: size + 1}
  end

  def push(%__MODULE__{} = buffer, %Message{} = message) do
    {{:value, _oldest}, entries} = :queue.out(buffer.entries)

    %{buffer | entries: :queue.in(message, entries), dropped: buffer.dropped + 1}
  end

  @doc "Returns `buffer`'s messages oldest-first."
  @spec to_list(t()) :: [Message.t()]
  def to_list(%__MODULE__{entries: entries}), do: :queue.to_list(entries)

  @doc "Returns the number of messages currently held."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "Returns the number of messages lost to capacity since the buffer was created or last cleared."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(%__MODULE__{dropped: dropped}), do: dropped

  @doc "Empties `buffer`, preserving `capacity` and resetting `dropped` to `0`."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{capacity: capacity}), do: new(capacity)
end
