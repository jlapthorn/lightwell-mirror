import pytest
from jinja2.exceptions import SecurityError

from app import app, env, render_preview


@pytest.fixture
def client():
    return app.test_client()


def test_preview_renders_template(client):
    r = client.post("/preview", json={
        "template": "Hi {{ customer.name }}, order {{ order.id }} "
                    "({{ order['items'] | join(', ') }}) totals {{ '%.2f' % order.total }}."})
    assert r.status_code == 200
    assert r.json["body"] == "Hi Ada Lovelace, order A-1042 (Widget, Gadget) totals 42.50."


def test_output_is_autoescaped():
    assert render_preview("{{ '<b>' }}") == "&lt;b&gt;"


def test_sandbox_blocks_private_attributes(client):
    # A blocked attribute renders as empty; using it raises SecurityError.
    assert render_preview("{{ customer.__class__ }}") == ""
    with pytest.raises(SecurityError):
        render_preview("{{ customer.__class__.__name__ }}")
    r = client.post("/preview", json={"template": "{{ customer.__class__.__name__ }}"})
    assert r.status_code == 400
    assert "blocked by sandbox" in r.json["error"]


def test_attr_filter_is_sandboxed():
    """Regression test for CVE-2025-27516 (GHSA-cpwx-vrp4-4pq7).

    The sandbox hands templates a restricted wrapper instead of the raw
    str.format method. In vulnerable Jinja2 releases the |attr filter
    skipped that step, giving templates the unrestricted method. Both ways
    of reaching the attribute must return the same sandboxed object.
    """
    via_dot = env.compile_expression('"{0}".format')()
    via_attr = env.compile_expression('"{0}" | attr("format")')()
    assert type(via_attr) is type(via_dot), (
        f"|attr returned {type(via_attr).__name__}, dot access returned "
        f"{type(via_dot).__name__}: |attr bypasses the sandbox")
