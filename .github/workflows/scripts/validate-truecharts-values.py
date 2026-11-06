#!/usr/bin/env python3
"""Validate TrueCharts HelmRelease values against the schema each chart version ships.

For every HelmRelease whose chart comes from the `truecharts` HelmRepository:
  1. pull the chart at the exact version pinned in the HelmRelease,
  2. deep-merge the chart's default values.yaml with spec.values the way Helm does
     (maps merge, lists and scalars replace, an explicit null deletes the key),
  3. validate the result against the chart's values.schema.json, fetching any remote
     $ref it points at (TrueCharts charts $ref the published common schema).

This is the same check helm-controller performs at upgrade time, run at PR time instead.
Flux ${VAR} post-build substitutions are replaced with a placeholder string first.

Usage:
  validate-truecharts-values.py FILE [FILE ...]   validate the given helm-release.yaml files
  validate-truecharts-values.py --all             validate every helm-release.yaml under clusters/

Exit status is 1 if any HelmRelease fails validation or its chart cannot be fetched.
"""

import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

import yaml
from jsonschema import Draft7Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT7

REPO = os.environ.get("TRUECHARTS_REPO", "oci://oci.trueforge.org/truecharts")
SOURCE_NAME = os.environ.get("TRUECHARTS_SOURCE", "truecharts")
SUBST = re.compile(r"\$\{[A-Za-z0-9_]+(?:[:=-][^}]*)?\}")

_charts = {}
_remote = {}
_workdir = tempfile.mkdtemp(prefix="tc-schema-")


def annotate(level, path, msg):
    """Emit a GitHub annotation when running in Actions, plain text otherwise."""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::{level} file={path},title=TrueCharts schema::{msg}")
    else:
        print(f"{level.upper()}: {path}: {msg}")


def retrieve(uri):
    """Fetch remote $ref targets (http/https only), cached per run."""
    if not uri.startswith(("https://", "http://")):
        raise ValueError(f"refusing to resolve non-HTTP $ref {uri}")
    if uri not in _remote:
        with urllib.request.urlopen(uri, timeout=60) as resp:
            _remote[uri] = json.load(resp)
    return Resource.from_contents(_remote[uri], default_specification=DRAFT7)


def chart(name, version):
    """Pull chart@version once and return (default values, schema or None)."""
    key = (name, version)
    if key not in _charts:
        dest = os.path.join(_workdir, f"{name}-{version}")
        subprocess.run(
            ["helm", "pull", f"{REPO}/{name}", "--version", version,
             "--untar", "--untardir", dest],
            check=True, capture_output=True, text=True,
        )
        root = os.path.join(dest, name)
        with open(os.path.join(root, "values.yaml")) as f:
            values = yaml.safe_load(f) or {}
        schema_path = os.path.join(root, "values.schema.json")
        schema = None
        if os.path.exists(schema_path):
            with open(schema_path) as f:
                schema = json.load(f)
        _charts[key] = (values, schema)
    return _charts[key]


def merge(base, over):
    """Helm-style coalesce: maps merge recursively, null deletes, everything else replaces."""
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            if v is None:
                out.pop(k, None)
            elif k in out:
                out[k] = merge(out[k], v)
            else:
                out[k] = v
        return out
    return over


def helmreleases(path):
    with open(path) as f:
        text = SUBST.sub("PLACEHOLDER", f.read())
    for doc in yaml.safe_load_all(text):
        if not isinstance(doc, dict) or doc.get("kind") != "HelmRelease":
            continue
        spec = (doc.get("spec") or {}).get("chart", {}).get("spec")
        if not spec or (spec.get("sourceRef") or {}).get("name") != SOURCE_NAME:
            continue
        yield doc["metadata"]["name"], spec["chart"], str(spec["version"]), doc["spec"].get("values") or {}


def main(argv):
    if argv == ["--all"]:
        files = sorted(glob.glob("clusters/**/helm-release.yaml", recursive=True))
    else:
        files = [f for f in argv if f.endswith("helm-release.yaml") and os.path.exists(f)]

    checked = failed = skipped = 0
    summary = []
    for path in files:
        for name, chart_name, version, values in helmreleases(path):
            try:
                defaults, schema = chart(chart_name, version)
            except subprocess.CalledProcessError as e:
                failed += 1
                annotate("error", path, f"{name}: cannot pull {chart_name}@{version}: {e.stderr.strip()[:300]}")
                summary.append(f"| {name} | {chart_name}@{version} | ❌ pull failed |")
                continue
            if schema is None:
                skipped += 1
                annotate("notice", path, f"{name}: {chart_name}@{version} ships no values.schema.json, skipped")
                summary.append(f"| {name} | {chart_name}@{version} | ⏭ no schema |")
                continue
            validator = Draft7Validator(schema, registry=Registry(retrieve=retrieve))
            errors = sorted(validator.iter_errors(merge(defaults, values)), key=lambda e: list(e.absolute_path))
            checked += 1
            if errors:
                failed += 1
                for e in errors[:20]:
                    where = ".".join(str(p) for p in e.absolute_path) or "<root>"
                    annotate("error", path, f"{name} ({chart_name}@{version}): {where}: {e.message[:300]}")
                summary.append(f"| {name} | {chart_name}@{version} | ❌ {len(errors)} error(s) |")
            else:
                summary.append(f"| {name} | {chart_name}@{version} | ✅ |")

    if not summary:
        print("No TrueCharts HelmReleases in scope, nothing to validate.")
    report = ["| HelmRelease | Chart | Result |", "|---|---|---|", *summary,
              "", f"Validated {checked}, skipped {skipped}, failed {failed}."]
    print("\n".join(report))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("## TrueCharts values schema\n\n" + "\n".join(report) + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
