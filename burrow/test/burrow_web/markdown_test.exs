defmodule BurrowWeb.MarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BurrowWeb.Markdown

  test "reads an answer's blocks" do
    text = """
    ## Latest: **1.2.13**

    Web push works the same.[1] Run `mix deps.get`.

    1. Register a worker.[2]
    2. Create keys
       once.
       - nested
    3. Send.

    - a *b* [c](https://c.example)

    ```elixir
    def x, do: 1
    ```

    | Version | Date |
    | --- | --- |
    | 1.2.13 | Oct 20 |

    > quoted
    ---
    """

    assert Markdown.parse(text) == [
             {:h, 2, [text: "Latest: ", b: "1.2.13"]},
             {:p,
              [
                text: "Web push works the same.",
                cite: 1,
                text: " Run ",
                code: "mix deps.get",
                text: "."
              ]},
             {:ol, 1,
              [
                {[text: "Register a worker.", cite: 2], []},
                {[text: "Create keys once."], [[text: "nested"]]},
                {[text: "Send."], []}
              ]},
             {:ul,
              [{[{:text, "a "}, {:i, "b"}, {:text, " "}, {:link, "c", "https://c.example"}], []}]},
             {:code, "elixir", "def x, do: 1"},
             {:table, [[text: "Version"], [text: "Date"]],
              [[[text: "1.2.13"], [text: "Oct 20"]]]},
             {:quote, [text: "quoted"]},
             :hr
           ]
  end

  test "makes no markup of the text, and cites only known sources" do
    html =
      render_component(&Markdown.markdown/1,
        text: "<script>alert(1)</script> see [1] and [2] at https://example.com/x.",
        cites: MapSet.new([1]),
        turn: "t1",
        cited: {"t1", 1}
      )

    assert html =~ "&lt;script&gt;"
    assert html =~ ~s(phx-value-n="1")
    assert html =~ ~s(aria-pressed="true")
    refute html =~ ~s(phx-value-n="2")
    assert html =~ "[2]"
    assert html =~ ~s(href="https://example.com/x")
    # A citation sits right after its text.
    assert html =~ ~r/see <button[^>]*>1<\/button> and/
  end
end
