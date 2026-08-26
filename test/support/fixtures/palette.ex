defmodule StatifierUI.Test.Support.Fixtures.Palette do
  @moduledoc """
  A stand-in palette of fragment types for the `StatifierUI.Fixtures.Bundle`
  discovery tests.

  Each module here answers a `fixtures/0` callback the way a host's block
  type would, and between them they cover every branch discovery has: the
  Elixir spelling, the JSON spelling, a sidecar path, a fragment with no
  examples at all, a malformed bundle, and a callback that raises. No
  statechart package defines these modules - the point of the convention is
  that a bundle loader needs nothing but a zero-arity function.
  """

  defmodule Score do
    @moduledoc "A fragment supplying its bundle in the Elixir spelling."

    @doc "Executable examples for this fragment."
    @spec fixtures() :: map()
    def fixtures do
      %{
        datasets: %{
          "hot-lead" => %{"record" => %{"pages_viewed" => 14}},
          "cold-lead" => %{"record" => %{"pages_viewed" => 1}}
        },
        expressions: %{
          "needs_review" => %{
            "source" => "record.pages_viewed < 5",
            "expect" => %{"hot-lead" => false, "cold-lead" => true}
          }
        }
      }
    end
  end

  defmodule Notify do
    @moduledoc "A fragment supplying its bundle in the JSON (sidecar) spelling."

    @doc "Executable examples for this fragment."
    @spec fixtures() :: map()
    def fixtures do
      %{
        "version" => 1,
        "datasets" => %{"opted-in" => %{"user" => %{"opted_in" => true}}},
        "expressions" => %{
          "may_notify" => %{
            "source" => "user.opted_in",
            "expect" => %{"opted-in" => true}
          }
        }
      }
    end
  end

  defmodule Plain do
    @moduledoc "A fragment that ships no examples: no `fixtures/0` at all."
  end

  defmodule Malformed do
    @moduledoc "A fragment whose bundle names a top-level key the convention has no room for."

    @doc "A bundle with a typo'd key, which the Elixir spelling rejects rather than ignores."
    @spec fixtures() :: map()
    def fixtures, do: %{datsets: %{"typo" => %{}}}
  end

  defmodule Exploding do
    @moduledoc "A fragment whose callback raises, which must not take the palette down with it."

    @doc "Raises, on purpose."
    @spec fixtures() :: no_return()
    def fixtures, do: raise(RuntimeError, "examples are broken")
  end
end
