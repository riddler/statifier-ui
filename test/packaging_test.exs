defmodule StatifierUI.PackagingTest do
  # Guards the hex package tarball's contents against ADR-0009.
  #
  # ADR-0009 ("JavaScript ships as source") decides that this package's
  # JavaScript is delivered as source under `assets/`, and that `assets/`
  # "becomes public API". A directory that is public API but missing from
  # `package()`'s `files:` list in `mix.exs` is not published at all, and
  # nothing in the toolchain notices: `mix hex.build` prints the files it
  # packages and says nothing about the ones it left behind.
  #
  # That is the failure this file exists to make impossible. sui-2ke found
  # `assets` missing from `files:` while the directory did not yet exist, so
  # the defect was latent rather than live - the first commit to ship JS would
  # have shipped it into a tarball that silently omitted it.
  #
  # The assertion is deliberately conditional on the directory existing. Hex
  # refuses to build a package whose `files:` names a directory that is not on
  # disk ("Missing files: assets", hex 2.5.0), so listing `assets` before there
  # is an `assets/` would break `mix hex.publish` today in order to prevent a
  # breakage later. Instead the guard tracks reality: the moment a branch adds
  # the first file under `assets/`, this test goes red unless that same commit
  # adds `assets` to `files:`.
  use ExUnit.Case, async: true

  # Top-level directories that an accepted ADR declares are published with the
  # package. Add to this list when a record makes another directory part of the
  # distributed surface; it is not a list of directories that happen to exist.
  @published_by_adr [
    {"assets", "ADR-0009 (JavaScript ships as source)"}
  ]

  describe "package files: against the ADRs" do
    test "every directory an ADR declares published is in files: once it exists" do
      files = Mix.Project.config()[:package][:files]

      for {dir, adr} <- @published_by_adr, File.dir?(dir) do
        assert dir in files, """
        #{dir}/ exists on disk and #{adr} declares it published with the \
        package, but mix.exs's package() files: list does not name it:

            #{inspect(files)}

        Hex packages only what files: names, and reports nothing about what it \
        omits, so the tarball would ship without #{dir}/ and the first sign \
        would be a host that cannot resolve it. Add "#{dir}" to files: in the \
        same commit that adds #{dir}/.
        """
      end
    end

    test "the ADR-declared directories are tracked, not inferred from disk" do
      # A regression guard on the guard: if @published_by_adr is ever emptied
      # (or quietly narrowed to whatever happens to exist), the test above
      # passes vacuously forever.
      assert {"assets", "ADR-0009 (JavaScript ships as source)"} in @published_by_adr
    end
  end

  describe "README relative links" do
    # hex.pm renders the README from the package tarball, so a relative link
    # there resolves inside the tarball and answers 404 unless the target
    # ships; HexDocs rewrites a relative link only when the target is an
    # extra. One relative link works on GitHub, HexDocs and hex.pm alike only
    # when its target is in both lists. A file that is in neither (an ADR,
    # for one) is linked by absolute GitHub URL instead.
    test "every relative link target is in package files: and in extras" do
      config = Mix.Project.config()
      files = config[:package][:files]
      extras = Enum.map(config[:docs][:extras], &extra_path/1)

      targets = readme_relative_targets()
      assert targets != [], "found no relative links in README.md; the scan is broken"

      for target <- targets do
        assert target in extras,
               "README.md links #{target} relatively, but it is not in docs() extras: #{inspect(extras)}"

        assert Enum.any?(files, &(target == &1 or String.starts_with?(target, &1 <> "/"))),
               "README.md links #{target} relatively, but package() files: does not ship it: #{inspect(files)}"
      end
    end
  end

  defp readme_relative_targets do
    ~r/\]\(([^)\s]+)\)/
    |> Regex.scan(File.read!("README.md"), capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&String.match?(&1, ~r{^(https?:|mailto:|#)}))
    |> Enum.map(&(&1 |> String.split("#") |> hd()))
    |> Enum.uniq()
  end

  defp extra_path({path, _opts}), do: to_string(path)
  defp extra_path(path), do: to_string(path)
end
