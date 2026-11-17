from nativehtmlkit_appshell.contract import validate_manifest
from nativehtmlkit_appshell.render import render_view

M = {"api_version":1,"id":"org.example.html","title":"X","version":"0.1.0",
     "pages":[{"id":"overview","title":"Overview"}],
     "commands":[{"id":"save","title":"Save","risk":"write","confirmation":"Confirm"}]}


def test_escaping_and_action_dispatch():
    view = {"title":"X","blocks":[
        {"kind":"heading","text":"<script>alert(1)</script>"},
        {"kind":"input","name":"thing","label":"' onfocus=evil()","value":"\" <b>"},
        {"kind":"checkbox","name":"is_ok","label":"Okay","checked":False},
        {"kind":"button","text":"Save","command":"save","params":{"x":"y"}}]}
    result=render_view(view, validate_manifest(M), generation=7)
    assert '<script>' not in result.html
    assert '&lt;script&gt;' in result.html
    assert 'onfocus=evil()' in result.html  # only inside quoted, escaped attribute
    assert 'as-button-7-' in result.html
    assert result.fields['thing'][1] == 'input'
    assert next(iter(result.buttons.values())) == ('save', {'x':'y'})


def test_table_scalar_escaping():
    view={"title":"T","blocks":[{"kind":"table","columns":[{"key":"x","title":"X"}],
                                      "rows":[{"x":"<iframe>"}]}]}
    result=render_view(view, validate_manifest(M))
    assert '<iframe>' not in result.html
    assert '&lt;iframe&gt;' in result.html
