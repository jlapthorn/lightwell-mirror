"""Customer notification service.

Support staff write their own e-mail/SMS templates in a web form, and this
service previews them against sample order data. Because the templates are
written by users, they are rendered in Jinja2's SandboxedEnvironment, which
is meant to stop a template from reaching Python internals.

Run:  flask --app app run
"""

import jinja2
from flask import Flask, jsonify, request
from jinja2.exceptions import SecurityError, TemplateSyntaxError
from jinja2.sandbox import SandboxedEnvironment

app = Flask(__name__)
app.config["SECRET_KEY"] = "demo-only-not-a-real-secret"

env = SandboxedEnvironment(autoescape=True)

SAMPLE = {
    "customer": {"name": "Ada Lovelace", "tier": "gold"},
    "order": {"id": "A-1042", "items": ["Widget", "Gadget"], "total": 42.5},
}


def render_preview(source: str) -> str:
    return env.from_string(source).render(**SAMPLE)


@app.post("/preview")
def preview():
    source = (request.get_json(silent=True) or {}).get("template", "")
    try:
        return jsonify(body=render_preview(source))
    except SecurityError as e:
        return jsonify(error=f"blocked by sandbox: {e}"), 400
    except TemplateSyntaxError as e:
        return jsonify(error=f"template error: {e}"), 400


@app.get("/healthz")
def healthz():
    return jsonify(status="ok", jinja2=jinja2.__version__)
