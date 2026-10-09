#!/usr/bin/env python3
"""What a devbox preview env IS — names, topics and the env-repo files.

The ONE place that knows the naming rules, so create, delete and the proof
can't disagree about what belongs to an env. devbox.sh calls it; tests call it
directly.

    env_gen.py names  --env preview-x
    env_gen.py topics --env preview-x --topics-file topics.txt
    env_gen.py files  --env preview-x --template-dir <env-repo>/envs/prod-like \\
                      --resolved resolved.json --out <env-repo>/envs/preview-x

A preview env named preview-x gets:
    namespace        apps-preview-x
    MySQL / Mongo    ecommerce_preview_x      (on the shared servers)
    Kafka            preview-x.<topic>        (topics, DLTs, consumer groups)
    CDC connector    mongodb-source-connector-preview-x, watching ITS Mongo db,
                     publishing preview-x.ecommerce_db.ecommerce_preview_x.event
    Redis            its own, as `redis` in its namespace

Everything else is copied from the template env (prod-like): image tags,
per-service springConfig/env. Previews start SMALL — no HPAs, smaller
requests, no ingress (phase 3c adds browser access) — and those are ordinary
values in the generated files, so a commit can grow any of them.
"""
import argparse
import json
import pathlib
import re
import sys

import yaml

NAME_RE = re.compile(r"^preview-[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$")

# prod-like's shared names these are derived from (deploy/secrets, topics.txt,
# 04-kafka-connect-register/seed.sh).
BASE_MYSQL_DB = "ecommerce_dev"
BASE_MONGO_DB = "ecommerce_inventory"
BASE_CDC_PREFIX = "ecommerce_db"
BASE_CDC_TOPIC = f"{BASE_CDC_PREFIX}.{BASE_MONGO_DB}.event"
BASE_CONNECTOR = "mongodb-source-connector"

# Smaller than prod-like on purpose (decision 0011, Q4) — starting values only.
SMALL_REQUESTS = {"cpu": "50m", "memory": "384Mi"}


def names(env: str) -> dict:
    if not NAME_RE.match(env):
        raise SystemExit(f"env name '{env}' must match {NAME_RE.pattern} (e.g. preview-cart)")
    db = env.replace("-", "_")
    db = f"ecommerce_{db}"
    cdc_prefix = f"{env}.{BASE_CDC_PREFIX}"
    return {
        "env": env,
        "namespace": f"apps-{env}",
        "mysqlDb": db,
        "mongoDb": db,
        "prefix": f"{env}.",
        "connector": f"{BASE_CONNECTOR}-{env}",
        "connectorTopicPrefix": cdc_prefix,
        "cdcTopic": f"{cdc_prefix}.{db}.event",
    }


def env_topic(n: dict, base: str) -> str:
    """prod-like topic name → this env's. The CDC topic isn't a plain prefix:
    the connector builds it from ITS prefix and ITS database."""
    if base == BASE_CDC_TOPIC or base.startswith(BASE_CDC_TOPIC + "."):
        return n["cdcTopic"] + base[len(BASE_CDC_TOPIC):]
    return n["prefix"] + base


def topics(n: dict, topics_file: pathlib.Path) -> list:
    out = []
    for line in topics_file.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        name, partitions, cleanup = line.split()
        out.append((env_topic(n, name), partitions, cleanup))
    return out


def _set(tree: dict, dotted_prefix: list, key: str, value):
    node = tree
    for part in dotted_prefix:
        node = node.setdefault(part, {})
    node[key] = value


def spring_config(n: dict, resolved: dict) -> dict:
    """The env-wide springConfig: every resolved key that names shared state,
    rewritten to this env's. Keys are collected across all services (their
    values agree — the resolver output is checked below), so each service gets
    the full set; an unused key is harmless."""
    cfg, seen = {}, {}

    def put(prefix, key, value):
        full = ".".join(prefix + [key])
        if full in seen and seen[full] != value:
            raise SystemExit(f"conflicting resolved values for {full}: {seen[full]!r} vs {value!r}")
        seen[full] = value
        _set(cfg, prefix, key, value)

    for _svc, props in sorted(resolved.items()):
        for k, v in sorted(props.items()):
            for group in ("topics", "group-id"):
                p = f"application.kafka.{group}."
                if k.startswith(p):
                    # The map key keeps its dots: ONE key under topics/group-id.
                    value = env_topic(n, v) if group == "topics" else n["prefix"] + v
                    put(["application", "kafka", group], k[len(p):], value)
            if re.fullmatch(r"spring\.datasource(\.(master|slave1|slave2))?\.url", k):
                parts = k.split(".")
                put(parts[:-1], "url", v.replace(f"/{BASE_MYSQL_DB}?", f"/{n['mysqlDb']}?"))
            # NOT spring.data.mongodb.uri: it carries the password, and this
            # file is committed. MongoProperties prefers `database` over the
            # URI's path, so overriding the database alone is enough.
            if k == "spring.data.mongodb.database":
                put(["spring", "data", "mongodb"], "database", n["mongoDb"])
            if k == "spring.data.redis.host":
                put(["spring", "data", "redis"], "host", "redis")
    # Secrets live in Vault, never in the env repo. A URL with userinfo
    # (scheme://user:pass@host) here would be committed in plain text.
    for full, value in seen.items():
        if isinstance(value, str) and re.search(r"://[^/@\s]+:[^/@\s]*@", value):
            raise SystemExit(f"refusing to write {full}: its value embeds credentials")
    return cfg


HEADER = """# {what} — generated by `make devbox-env-create` from envs/{template}.
# Edit freely and commit: this file is now the truth for {env}.
"""


def files(n: dict, template_dir: pathlib.Path, resolved: dict, out: pathlib.Path):
    env_yaml = yaml.safe_load((template_dir / "env.yaml").read_text())
    env_yaml["global"]["namespaces"]["apps"] = n["namespace"]
    env_yaml.setdefault("defaults", {})["springConfig"] = spring_config(n, resolved)

    (out / "services").mkdir(parents=True, exist_ok=False)
    (out / "env.yaml").write_text(
        HEADER.format(what=f"Env-wide settings for {n['env']}", template=template_dir.name, env=n["env"])
        + "# defaults.springConfig points every service at THIS env's databases, topics,\n"
        + "# consumer groups and Redis (rendered as SPRING_APPLICATION_JSON, which\n"
        + "# overrides the shared Vault config). Secrets still come from Vault.\n"
        + yaml.safe_dump(env_yaml, sort_keys=False, default_flow_style=False))

    for f in sorted((template_dir / "services").glob("*.yaml")):
        svc = f.stem
        doc = yaml.safe_load(f.read_text())
        block = doc["apps"][svc]
        if svc != "frontend":
            # null DELETES the chart default in Helm's value merge: no HPA, no
            # Ingress. Previews are API-only until phase 3c.
            block["hpa"] = None
            block["ingress"] = None
            block["resources"] = {"requests": dict(SMALL_REQUESTS)}
        else:
            block["ingress"] = None
        (out / "services" / f.name).write_text(
            HEADER.format(what=f"{svc} in {n['env']}", template=template_dir.name, env=n["env"])
            + "# Started small (no hpa/ingress, smaller requests) — change and commit to grow it.\n"
            + yaml.safe_dump(doc, sort_keys=False, default_flow_style=False))

    (out / "services" / "redis.yaml").write_text(
        f"# {n['env']}'s own Redis (stock counters, pendingOrders, tokens, locks).\n"
        "# Rendered by the apps chart's env-redis.yaml; apps reach it as `redis`.\n"
        + yaml.safe_dump({"envRedis": {"enabled": True}}, sort_keys=False))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["names", "topics", "files"])
    ap.add_argument("--env", required=True)
    ap.add_argument("--topics-file", type=pathlib.Path)
    ap.add_argument("--template-dir", type=pathlib.Path)
    ap.add_argument("--resolved", type=pathlib.Path)
    ap.add_argument("--out", type=pathlib.Path)
    a = ap.parse_args()
    n = names(a.env)
    if a.cmd == "names":
        json.dump(n, sys.stdout)
        print()
    elif a.cmd == "topics":
        for t in topics(n, a.topics_file):
            print(" ".join(t))
    else:
        files(n, a.template_dir, json.loads(a.resolved.read_text()), a.out)


if __name__ == "__main__":
    main()
