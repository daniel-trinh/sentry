defmodule SentryTest do
  use ExUnit.Case

  test "the truth" do
    IEx.Helpers.r(Sentry)
    assert 1 + 1 == 2
  end
end