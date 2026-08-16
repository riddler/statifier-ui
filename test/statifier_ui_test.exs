defmodule StatifierUITest do
  use ExUnit.Case, async: true

  doctest StatifierUI

  describe "version/0" do
    test "reports the version mix.exs declares" do
      assert StatifierUI.version() == Mix.Project.config()[:version]
    end
  end
end
