"""Document-intake service that exists to be scanned: it uses every library
pinned in requirements.txt, all at versions with known CVEs."""
import io
from importlib.metadata import version

import banks
import python_multipart  # noqa: F401  (multipart form parsing for the upload API)
import PyPDF2
import pypdf
import sqlparse
from authlib.common.security import generate_token
from flask import Flask, jsonify, request
from jinja2.sandbox import SandboxedEnvironment
from jwcrypto import jwk, jwt

PACKAGES = ["flask", "authlib", "banks", "jinja2", "jwcrypto", "pypdf",
            "pypdf2", "python-multipart", "sqlparse"]

app = Flask(__name__)
signing_key = jwk.JWK.generate(kty="oct", size=256)
templates = SandboxedEnvironment()


@app.get("/healthz")
def healthz():
    return jsonify({p: version(p) for p in PACKAGES})


@app.post("/token")
def issue_token():
    claims = {"sub": request.json["user"], "jti": generate_token(16)}
    tok = jwt.JWT(header={"alg": "HS256"}, claims=claims)
    tok.make_signed_token(signing_key)
    return jsonify(token=tok.serialize())


@app.post("/token/verify")
def verify_token():
    return jsonify(claims=jwt.JWT(key=signing_key, jwt=request.json["token"]).claims)


@app.post("/render")
def render():
    return templates.from_string(request.json["template"]).render(request.json.get("vars", {}))


@app.post("/prompt")
def prompt():
    return banks.Prompt(request.json["template"]).text(request.json.get("vars", {}))


@app.post("/sql/format")
def format_sql():
    return sqlparse.format(request.json["sql"], reindent=True, keyword_case="upper")


@app.post("/pdf/text")
def pdf_text():
    data = request.files["file"].read()
    if request.args.get("legacy"):
        pages = PyPDF2.PdfReader(io.BytesIO(data)).pages
    else:
        pages = pypdf.PdfReader(io.BytesIO(data)).pages
    return jsonify(pages=[p.extract_text() for p in pages])
