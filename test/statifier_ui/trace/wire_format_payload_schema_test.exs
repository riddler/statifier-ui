defmodule StatifierUI.Trace.WireFormatPayloadSchemaTest do
  @moduledoc """
  Ties `docs/wire-format.md`'s `session.start` payload tables to what
  `StatifierUI.Trace.Manifest` actually builds.

  `wire_format_spec_test.exs` guards the *type index* - that the documented
  message type names are the ones the code emits. This module guards the
  layer under it: the per-table field/type/presence schemas. It parses the
  markdown tables rather than restating them, so the document stays the one
  place a field is written down, and a field added to the producer without a
  doc row (or a doc row with no emitted field) fails here.

  **The presence column is the part under test.** Field names drift loudly;
  presence drifts quietly, and the `sui-o5c` verify walk found two prose
  claims about the `data` table that no test could have caught. A row marked
  `always` must appear on every sample row of its table; a row marked
  `present only when ...` or `omitted ...` must appear on at least one sample
  row and be absent from at least one, so a conditional row that has quietly
  become unconditional (or vice versa) fails rather than passing vacuously.

  The samples below exist to make both arms of every conditional reachable;
  a documented field no sample can exercise fails as `never observed`, which
  is a gap in this file rather than in the document.
  """

  use ExUnit.Case, async: true

  alias StatifierUI.Trace.Manifest
  alias StatifierUI.Trace.Projection

  @wire_format_path Path.join([__DIR__, "..", "..", "..", "docs", "wire-format.md"])

  @section_heading "## `session.start`"
  @section_end "## The nine `trace.*` schemas"

  # Every optional payload field written, every conditional row-level field
  # present: a transition with a `cond`, executable content, and `<data>`
  # elements written three ways (`expr`, bare, child content).
  @rich """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0" datamodel="predicator">
      <datamodel>
          <data id="x" expr="1" />
          <data id="bare" />
          <data id="child">42</data>
      </datamodel>
      <state id="a">
          <onentry>
              <log expr="1" />
          </onentry>
          <transition event="go" target="b" cond="x == 1" />
      </state>
      <state id="b" />
  </scxml>
  """

  # The other arm: no caller-supplied context, no guard, no executable
  # content, no datamodel - so every conditional field is absent somewhere.
  @plain """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <transition target="b" />
      </state>
      <state id="b" />
  </scxml>
  """

  describe "docs/wire-format.md session.start payload schemas" do
    setup do
      %{schema: parse_session_start_schema(), samples: sample_payloads()}
    end

    test "the section parses into exactly the tables this file knows how to check",
         %{schema: schema} do
      assert schema |> Map.keys() |> Enum.sort() ==
               ~w(contents data location payload states transitions),
             "docs/wire-format.md's `session.start` section no longer parses into the " <>
               "tables this file checks. Every other test here iterates the parsed " <>
               "schema, so an unrecognized table would be skipped rather than checked."

      for {table, fields} <- schema do
        refute fields == %{}, "the #{table} table parsed to no fields"
      end
    end

    test "every documented table's fields are exactly the fields the producer emits",
         %{schema: schema, samples: samples} do
      for {table, fields} <- schema do
        rows = table_rows(table, samples)

        refute rows == [],
               "no sample #{table} rows: this test file cannot judge the #{table} table"

        documented = fields |> Map.keys() |> MapSet.new()
        emitted = rows |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

        assert MapSet.difference(emitted, documented) |> MapSet.size() == 0,
               "the #{table} table of docs/wire-format.md documents no row for " <>
                 "#{inspect(MapSet.to_list(MapSet.difference(emitted, documented)))}, " <>
                 "which the producer emits"

        assert MapSet.difference(documented, emitted) |> MapSet.size() == 0,
               "the #{table} table of docs/wire-format.md documents " <>
                 "#{inspect(MapSet.to_list(MapSet.difference(documented, emitted)))}, " <>
                 "which no sample message carries"
      end
    end

    test "every field the document calls 'always' is on every sample row",
         %{schema: schema, samples: samples} do
      for {table, fields} <- schema,
          {field, :always} <- fields,
          row <- table_rows(table, samples) do
        assert Map.has_key?(row, field),
               "docs/wire-format.md calls #{table}.#{field} always-present, but a " <>
                 "sample row carries only #{inspect(Enum.sort(Map.keys(row)))}"
      end
    end

    test "every field the document calls conditional is observed both present and absent",
         %{schema: schema, samples: samples} do
      for {table, fields} <- schema, {field, :conditional} <- fields do
        rows = table_rows(table, samples)
        {present, absent} = Enum.split_with(rows, &Map.has_key?(&1, field))

        refute present == [],
               "docs/wire-format.md documents #{table}.#{field}, but no sample row " <>
                 "carries it - either the producer no longer emits it, or this test's " <>
                 "samples cannot reach the condition"

        refute absent == [],
               "docs/wire-format.md calls #{table}.#{field} conditional, but every " <>
                 "sample row carries it - the field has become unconditional and the " <>
                 "presence cell is stale"
      end
    end

    test "every location object carries exactly the six documented fields",
         %{schema: schema, samples: samples} do
      documented = schema |> Map.fetch!("location") |> Map.keys() |> MapSet.new()
      locations = Enum.flat_map(samples, &collect_locations/1)

      refute locations == [], "no sample location objects"

      for location <- locations do
        assert MapSet.new(Map.keys(location)) == documented,
               "a location object carries #{inspect(Enum.sort(Map.keys(location)))}, " <>
                 "but docs/wire-format.md documents #{inspect(Enum.sort(MapSet.to_list(documented)))}"
      end
    end
  end

  # -- samples ------------------------------------------------------------------

  # The payload of one unprojected rich message, one bare message, and the
  # rich message projected - the third solely so the `projection` header has
  # somewhere to be observed present.
  @spec sample_payloads() :: [map()]
  defp sample_payloads do
    {:ok, rich} =
      @rich
      |> compile!()
      |> Manifest.build("sess_rich",
        source: @rich,
        fixtures: %{"version" => 1},
        parent_session: "sess_parent",
        invokeid: "invoke_1"
      )

    {:ok, plain} = @plain |> compile!() |> Manifest.build("sess_plain")

    projected = Projection.project(rich, Projection.profile!("wire_format_payload_schema_test"))

    Enum.map([rich, plain, projected], & &1.payload)
  end

  @spec compile!(String.t()) :: Statifier.Machine.t()
  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  # The payload itself is the single "row" of the top-level table; every
  # other table's rows are the array it names.
  @spec table_rows(String.t(), [map()]) :: [map()]
  defp table_rows("payload", payloads), do: payloads
  defp table_rows("location", payloads), do: Enum.flat_map(payloads, &collect_locations/1)

  defp table_rows(table, payloads) when table in ~w(states transitions contents data),
    do: Enum.flat_map(payloads, &Map.fetch!(&1, table))

  # A table the parser could not name - the empty list makes the caller's
  # own "no sample rows" assertion the failure, rather than a KeyError.
  defp table_rows(_table, _payloads), do: []

  # Every location object anywhere in a payload, found by structure rather
  # than by an enumerated list of positions, so a location carried somewhere
  # new is checked without this test being told about it.
  @spec collect_locations(term()) :: [map()]
  defp collect_locations(%{"start_line" => _start_line} = location), do: [location]

  defp collect_locations(map) when is_map(map),
    do: map |> Map.values() |> Enum.flat_map(&collect_locations/1)

  defp collect_locations(list) when is_list(list), do: Enum.flat_map(list, &collect_locations/1)
  defp collect_locations(_other), do: []

  # -- the document -------------------------------------------------------------

  # Parses the `session.start` section into
  # `%{table_name => %{field_name => :always | :conditional}}`. Tables are
  # identified by the bolded line that introduces them; the section's first
  # table has no such line and is the top-level payload table.
  @spec parse_session_start_schema() :: %{String.t() => %{String.t() => :always | :conditional}}
  defp parse_session_start_schema do
    [_before, rest] =
      @wire_format_path |> File.read!() |> String.split(@section_heading, parts: 2)

    [section, _after] = String.split(rest, @section_end, parts: 2)

    section
    |> String.split("\n")
    |> Enum.reduce({%{}, "payload", nil}, &read_line/2)
    |> then(fn {schema, _label, _table} -> schema end)
  end

  @spec read_line(String.t(), {map(), String.t(), String.t() | nil}) ::
          {map(), String.t(), String.t() | nil}
  defp read_line("|" <> _rest = line, {schema, label, table}) do
    case {table, parse_row(line)} do
      # The header and its `|---|` separator open a table under the pending label.
      {nil, ["Field", "Type" | _rest]} ->
        {schema, label, label}

      {nil, _cells} ->
        {schema, label, nil}

      {_open, [field, _type | presence]} ->
        {put_field(schema, table, field, presence), label, table}
    end
  end

  defp read_line("**" <> _rest = line, {schema, _label, _table}),
    do: {schema, table_label(line), nil}

  defp read_line("", {schema, label, _table}), do: {schema, label, nil}
  defp read_line(_line, {schema, label, table}), do: {schema, label, table}

  @spec parse_row(String.t()) :: [String.t()]
  defp parse_row(line) do
    line
    |> String.trim()
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  @spec put_field(map(), String.t(), String.t(), [String.t()]) :: map()
  defp put_field(schema, _table, "---" <> _rest, _presence), do: schema

  defp put_field(schema, table, field, presence) do
    Map.update(
      schema,
      table,
      %{field => presence(presence)},
      &Map.put(&1, field, presence(presence))
    )
  end

  # A two-column table (the location object) has no presence column: every
  # one of its fields is present whenever the object is.
  @spec presence([String.t()]) :: :always | :conditional
  defp presence([]), do: :always

  defp presence([cell]) do
    cond do
      String.starts_with?(cell, "always") -> :always
      String.starts_with?(cell, "present only when") -> :conditional
      String.starts_with?(cell, "omitted") -> :conditional
      true -> flunk("unclassifiable presence cell in docs/wire-format.md: #{inspect(cell)}")
    end
  end

  # The bolded line introducing a table names it in backticks (**`states`**);
  # the location object's line names it in prose. Any other bolded line just
  # clears the pending label, and a table under one fails the schema check
  # above by carrying no recognized name.
  @spec table_label(String.t()) :: String.t()
  defp table_label("**A location object**" <> _rest), do: "location"

  defp table_label(line) do
    case Regex.run(~r/^\*\*`([a-z_]+)`\*\*/, line, capture: :all_but_first) do
      [name] -> name
      nil -> "unlabelled"
    end
  end
end
