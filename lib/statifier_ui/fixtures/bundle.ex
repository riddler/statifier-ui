defmodule StatifierUI.Fixtures.Bundle do
  @moduledoc """
  A fixture bundle that travels with one reusable chart fragment rather than
  with a whole chart: the ADR-0003/ADR-0006 bundle plus the fragment's name
  and a record of where it was loaded from.

  ADR-0003 pairs a bundle with a *chart* - `payment.scxml` carries
  `payment.fixtures.json` beside it. An embedder composing charts from a
  palette of reusable fragments has no such file to sit beside: the fragment
  is a module in the host's code or an entry in a palette, and the chart it
  eventually lands in does not exist yet. This module is the same contract
  addressed by fragment name instead of by chart path, so each palette entry
  can carry its own executable examples and surface a per-fragment "test this
  step" panel.

  Nothing here is a new fixture shape. A bundle's `fixtures` field is exactly
  the `StatifierUI.Fixtures` struct both ADR-0003 delivery paths already
  produce, and every spelling below routes through `StatifierUI.Fixtures.new/1`
  or `StatifierUI.Fixtures.Sidecar.from_json/2` for validation. What this
  record adds is identity (which fragment these examples belong to),
  provenance (which module or file they came from), and discovery (finding
  every fragment's bundle across a palette or a directory).

  ## The convention

  A fragment supplies its bundle in one of four spellings, and `load/3`
  accepts all four:

  | Spelling | Recognized by | Validated through |
  |---|---|---|
  | `%StatifierUI.Fixtures{}` | the struct | already validated at construction |
  | `%{scenarios: ..., events: ..., datasets: ..., expressions: ...}` | **atom** top-level keys | `StatifierUI.Fixtures.new/1` |
  | `%{"version" => 1, "datasets" => ...}` | **string** top-level keys | `StatifierUI.Fixtures.Sidecar.from_json/2` |
  | `"path/to/step.fixtures.json"` | a binary path | `StatifierUI.Fixtures.Sidecar.load/1` |

  The atom-vs-string top-level key is the whole discriminator, and it is not
  an accident of implementation: atom keys are the Elixir spelling a host
  writes by hand in a module, string keys are the JSON spelling that survives
  a file, and ADR-0003 requires both paths to converge on one struct rather
  than one path to be primary. A map mixing the two is rejected as
  `{:mixed_bundle_keys, name}` instead of guessed at.

  **Unknown top-level keys are treated differently by spelling, deliberately.**
  The JSON spelling keeps the sidecar's ignore-unknown-keys discipline
  (ADR-0006): a file written by a newer producer must still load. The Elixir
  spelling rejects an unknown atom key as `{:unknown_bundle_key, name, key}`,
  because an atom key in a host's own module is compiled code the author is
  looking at, and a silently ignored `:datsets` typo there is a bundle that
  reports zero datasets and no reason why. Forward compatibility is a
  property of a wire format, not of a function call.

  A fragment that ships no examples at all is not an error anywhere in this
  module. `discover/2` reports it as `without`, never as a failure.

  ## Discovery

  Two discovery paths, mirroring the two delivery paths:

    * `discover/2` walks a palette - a map or list of `{name, module}` pairs -
      and loads each module's bundle callback (`fixtures/0` by default,
      `:callback` to name another). This is the host-application path.
    * `discover_dir/2` walks a directory of `*.fixtures.json` files and names
      each bundle after its file (`authorize.fixtures.json` becomes `"authorize"`).
      This is the corpus and CLI path, and it is what lets a palette of
      fragments travel as files with no host code around them.

  Neither raises and neither is all-or-nothing: one fragment's malformed
  bundle is reported against that fragment's name and the rest still load,
  because a palette is exactly the setting where the alternative - one bad
  entry hiding every good one - is least useful.

  This module names no block, palette, or fragment type of its own and takes
  no dependency on any package that defines one. It calls a zero-arity
  callback on whatever modules it is handed, which is all a bundle convention
  needs to be.

  ## Rendering

  `StatifierUI.Fixtures.Bundle.Markdown` renders a bundle as its truth table
  plus its expectation results - the per-fragment test panel - and
  `StatifierUI.Kino.test_panel/2` wraps that for a Livebook cell.
  """

  alias StatifierUI.Fixtures
  alias StatifierUI.Fixtures.Sidecar

  @bundle_keys [:scenarios, :events, :datasets, :expressions]

  @typedoc "The fragment a bundle belongs to: a palette entry name or a file basename."
  @type name :: String.t()

  @typedoc """
  Where a bundle came from. `{:module, mod}` for a palette entry's callback,
  `{:sidecar, path}` for a file, `:inline` for a term handed straight to
  `load/3`.
  """
  @type origin :: {:module, module()} | {:sidecar, Path.t()} | :inline

  @type t :: %__MODULE__{
          name: name(),
          fixtures: Fixtures.t(),
          origin: origin(),
          diagnostics: [Fixtures.diagnostic()]
        }

  @enforce_keys [:name, :fixtures, :origin]
  defstruct [:name, :fixtures, :origin, diagnostics: []]

  @typedoc """
  What `discover/2` and `discover_dir/2` found.

  `bundles` are the ones that loaded, sorted by name. `without` names the
  entries that ship no bundle at all - an absence, not a failure. `errors`
  pairs a name with the reason its bundle did not load.
  """
  @type discovery :: %{
          bundles: [t()],
          without: [name()],
          errors: [{name(), term()}]
        }

  @doc """
  Builds a bundle named `name` from `term`, in any of the four spellings
  above.

  Options:

    * `:origin` - the `t:origin/0` to record. Defaults to `:inline`, or to
      `{:sidecar, path}` when `term` is a path.

  Never raises. A term in none of the four spellings is
  `{:error, {:unrecognized_bundle, name, term}}`.

  ## Examples

      iex> {:ok, bundle} =
      ...>   StatifierUI.Fixtures.Bundle.load("myapp.authorize", %{
      ...>     datasets: %{"approved" => %{"amount" => 90}},
      ...>     expressions: %{"large" => %{"source" => "amount > 50"}}
      ...>   })
      iex> bundle.name
      "myapp.authorize"
      iex> StatifierUI.Fixtures.dataset_names(bundle.fixtures)
      ["approved"]

  """
  @spec load(name(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(name, term, opts \\ [])

  def load(name, %Fixtures{} = fixtures, opts) when is_binary(name) do
    {:ok, build(name, fixtures, Keyword.get(opts, :origin, :inline))}
  end

  def load(name, path, opts) when is_binary(name) and is_binary(path) do
    case Sidecar.load(path) do
      {:ok, fixtures} ->
        {:ok, build(name, fixtures, Keyword.get(opts, :origin, {:sidecar, path}))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def load(name, map, opts) when is_binary(name) and is_map(map) do
    origin = Keyword.get(opts, :origin, :inline)

    case key_style(map) do
      :atom -> from_elixir_map(name, map, origin)
      :string -> from_json_map(name, map, origin)
      :empty -> {:ok, build(name, %Fixtures{}, origin)}
      :mixed -> {:error, {:mixed_bundle_keys, name}}
    end
  end

  def load(name, term, _opts) when is_binary(name),
    do: {:error, {:unrecognized_bundle, name, term}}

  @doc """
  Like `load/3` but raises `ArgumentError` on failure.

  For a host that wants a malformed bundle to fail loudly at wiring time
  rather than be carried around as an error tuple.
  """
  @spec load!(name(), term(), keyword()) :: t()
  def load!(name, term, opts \\ []) do
    case load(name, term, opts) do
      {:ok, bundle} ->
        bundle

      {:error, reason} ->
        raise ArgumentError, "could not load fixture bundle #{inspect(name)}: #{inspect(reason)}"
    end
  end

  @doc """
  Loads the bundle every entry of `palette` ships.

  `palette` is a map or list of `{name, module}` pairs - a palette of
  fragment types, however the caller happens to hold it. For each entry, when
  the module exports the bundle callback it is called and its return value
  goes through `load/3`; when it does not, the entry is reported under
  `without`.

  Options:

    * `:callback` - the zero-arity function to call. Defaults to `:fixtures`.

  Never raises: a module whose callback itself raises is reported as
  `{:bundle_callback_raised, exception}` against its name, because one
  fragment's broken examples must not take down the panel for every other
  fragment in the palette.
  """
  @spec discover(%{optional(name()) => module()} | [{name(), module()}], keyword()) ::
          discovery()
  def discover(palette, opts \\ []) do
    callback = Keyword.get(opts, :callback, :fixtures)
    load_opts = Keyword.delete(opts, :callback)

    palette
    |> Enum.sort_by(fn {name, _module} -> name end)
    |> Enum.reduce(empty_discovery(), fn {name, module}, acc ->
      collect(acc, name, discover_entry(name, module, callback, load_opts))
    end)
    |> sort_discovery()
  end

  @doc """
  Loads every `*.fixtures.json` file directly inside `dir`, naming each
  bundle after its file: `authorize.fixtures.json` becomes `"authorize"`.

  The directory is not walked recursively - a palette directory is a flat
  list of fragments, and a nested one is a second palette, not a deeper part
  of this one.

  A missing or unreadable directory is `{:error, reason}`; a directory that
  exists and holds no sidecars is an empty discovery, which is a legitimate
  answer rather than a failure.
  """
  @spec discover_dir(Path.t(), keyword()) :: {:ok, discovery()} | {:error, term()}
  def discover_dir(dir, opts \\ []) do
    case File.ls(dir) do
      {:ok, entries} ->
        {:ok, discover_files(dir, entries, opts)}

      {:error, reason} ->
        {:error, {:bundle_dir_unreadable, dir, reason}}
    end
  end

  @doc """
  Derives a bundle name from a sidecar filename:
  `"authorize.fixtures.json"` becomes `"authorize"`.

  The inverse of `StatifierUI.Fixtures.Sidecar.sidecar_path/1` for the
  fragment case, where the name is the identity and the path is derived from
  it rather than the other way round.

  ## Examples

      iex> StatifierUI.Fixtures.Bundle.name_from_path("palette/authorize.fixtures.json")
      "authorize"

  """
  @spec name_from_path(Path.t()) :: name()
  def name_from_path(path) do
    path |> Path.basename() |> String.replace_suffix(".fixtures.json", "")
  end

  @doc """
  Every bundle in `discovery`, keyed by name.

  A convenience for a consumer that holds a palette by name and wants the
  matching bundle without scanning the list.
  """
  @spec by_name(discovery()) :: %{optional(name()) => t()}
  def by_name(%{bundles: bundles}), do: Map.new(bundles, &{&1.name, &1})

  @doc """
  Whether the bundle carries anything at all to evaluate.

  A bundle with no expressions has no truth table and no expectations to
  run; a renderer says so once rather than drawing an empty matrix and an
  empty results list.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{fixtures: fixtures}) do
    Fixtures.expression_names(fixtures) == [] and Fixtures.dataset_names(fixtures) == []
  end

  # -- Building -------------------------------------------------------------

  @spec build(name(), Fixtures.t(), origin()) :: t()
  defp build(name, %Fixtures{diagnostics: diagnostics} = fixtures, origin) do
    %__MODULE__{name: name, fixtures: fixtures, origin: origin, diagnostics: diagnostics}
  end

  # The Elixir spelling. Unknown atom keys are rejected rather than ignored -
  # see the moduledoc for why forward compatibility is a wire-format property
  # and not a function-call one.
  @spec from_elixir_map(name(), map(), origin()) :: {:ok, t()} | {:error, term()}
  defp from_elixir_map(name, map, origin) do
    case Enum.find(Map.keys(map), &(&1 not in @bundle_keys)) do
      nil ->
        case Fixtures.new(Map.to_list(map)) do
          {:ok, fixtures} -> {:ok, build(name, fixtures, origin)}
          {:error, reason} -> {:error, {:invalid_bundle, name, reason}}
        end

      key ->
        {:error, {:unknown_bundle_key, name, key}}
    end
  end

  # The JSON spelling. `"version"` is supplied when the map omits it: a term
  # handed to `load/3` in code is not a file that could have been written by
  # a different producer, so demanding the version field there would reject
  # bundles for a reason that only applies on disk.
  @spec from_json_map(name(), map(), origin()) :: {:ok, t()} | {:error, term()}
  defp from_json_map(name, map, origin) do
    json = Map.put_new(map, "version", 1)

    case Sidecar.from_json(json, sidecar_opts(origin)) do
      {:ok, fixtures} -> {:ok, build(name, fixtures, origin)}
      {:error, reason} -> {:error, {:invalid_bundle, name, reason}}
    end
  end

  @spec sidecar_opts(origin()) :: keyword()
  defp sidecar_opts({:sidecar, path}), do: [source: path]
  defp sidecar_opts(_origin), do: []

  # A bundle map's top-level keys are all atoms or all strings. An empty map
  # is neither, and is a bundle with nothing in it rather than an ambiguity.
  @spec key_style(map()) :: :atom | :string | :empty | :mixed
  defp key_style(map) do
    keys = Map.keys(map)

    cond do
      keys == [] -> :empty
      Enum.all?(keys, &is_atom/1) -> :atom
      Enum.all?(keys, &is_binary/1) -> :string
      true -> :mixed
    end
  end

  # -- Discovery ------------------------------------------------------------

  @spec discover_entry(name(), module(), atom(), keyword()) ::
          {:ok, t()} | {:error, term()} | :none
  defp discover_entry(name, module, callback, load_opts) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, callback, 0) do
      call_callback(name, module, callback, load_opts)
    else
      _not_available -> :none
    end
  end

  # The callback is host code. It is a pure function by contract, but a
  # contract is not a guarantee, and one fragment's raising callback must not
  # deny every other fragment in the palette its panel.
  @spec call_callback(name(), module(), atom(), keyword()) :: {:ok, t()} | {:error, term()}
  defp call_callback(name, module, callback, load_opts) do
    term = apply(module, callback, [])
    load(name, term, Keyword.put_new(load_opts, :origin, {:module, module}))
  rescue
    exception -> {:error, {:bundle_callback_raised, exception}}
  end

  @spec discover_files(Path.t(), [Path.t()], keyword()) :: discovery()
  defp discover_files(dir, entries, opts) do
    entries
    |> Enum.filter(&String.ends_with?(&1, ".fixtures.json"))
    |> Enum.sort()
    |> Enum.reduce(empty_discovery(), fn entry, acc ->
      path = Path.join(dir, entry)
      collect(acc, name_from_path(entry), load(name_from_path(entry), path, opts))
    end)
    |> sort_discovery()
  end

  @spec empty_discovery() :: discovery()
  defp empty_discovery, do: %{bundles: [], without: [], errors: []}

  @spec collect(discovery(), name(), {:ok, t()} | {:error, term()} | :none) :: discovery()
  defp collect(acc, _name, {:ok, bundle}), do: %{acc | bundles: [bundle | acc.bundles]}
  defp collect(acc, name, {:error, reason}), do: %{acc | errors: [{name, reason} | acc.errors]}
  defp collect(acc, name, :none), do: %{acc | without: [name | acc.without]}

  @spec sort_discovery(discovery()) :: discovery()
  defp sort_discovery(discovery) do
    %{
      bundles: Enum.sort_by(discovery.bundles, & &1.name),
      without: Enum.sort(discovery.without),
      errors: Enum.sort_by(discovery.errors, &elem(&1, 0))
    }
  end
end
