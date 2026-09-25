#!/usr/bin/env python3
"""Keep subscription groups and rules while loading nodes through a provider."""

import copy
import re
import sys

import yaml


class ConfigLoader(yaml.SafeLoader):
    """Treat YAML 1.1 words such as 'off' as strings, as Mihomo does."""


ConfigLoader.yaml_implicit_resolvers = copy.deepcopy(yaml.SafeLoader.yaml_implicit_resolvers)
for first_character, resolvers in ConfigLoader.yaml_implicit_resolvers.items():
    ConfigLoader.yaml_implicit_resolvers[first_character] = [
        entry for entry in resolvers if entry[0] != "tag:yaml.org,2002:bool"
    ]
ConfigLoader.add_implicit_resolver(
    "tag:yaml.org,2002:bool",
    re.compile(r"^(?:true|True|TRUE|false|False|FALSE)$"),
    list("tTfF"),
)


def exact_names(names):
    def escape(name):
        return re.sub(r"([\\.^$|?*+()\[\]{}])", r"\\\1", name)

    return "^(?:" + "|".join(escape(name) for name in sorted(names)) + ")$"


def add_provider_to_group(group, node_names):
    members = group.get("proxies", [])
    if not isinstance(members, list):
        raise ValueError(f"group {group.get('name')} has invalid proxies")

    selected = {name for name in members if name in node_names}
    if not selected:
        return

    remaining = [name for name in members if name not in node_names]
    if remaining:
        group["proxies"] = remaining
    else:
        group.pop("proxies", None)

    providers = group.setdefault("use", [])
    if "node" not in providers:
        providers.append("node")

    excluded = node_names - selected
    if not excluded:
        return

    if len(excluded) < len(selected):
        expression = exact_names(excluded)
        existing = group.get("exclude-filter")
        group["exclude-filter"] = f"(?:{existing})|(?:{expression})" if existing else expression
    else:
        expression = exact_names(selected)
        group["filter"] = expression


def compose(base, subscription):
    nodes = subscription.get("proxies")
    groups = subscription.get("proxy-groups")
    rules = subscription.get("rules")
    if not isinstance(nodes, list) or not nodes:
        raise ValueError("subscription has no proxies")
    if not isinstance(groups, list) or not groups:
        raise ValueError("subscription has no proxy-groups")
    if not isinstance(rules, list) or not rules:
        raise ValueError("subscription has no rules")

    node_names = {node["name"] for node in nodes}
    config = copy.deepcopy(base)
    config.pop("proxies", None)
    config["proxy-groups"] = copy.deepcopy(groups)
    config["rules"] = copy.deepcopy(rules)
    if "rule-providers" in subscription:
        config["rule-providers"] = copy.deepcopy(subscription["rule-providers"])

    for group in config["proxy-groups"]:
        add_provider_to_group(group, node_names)

    return config


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: compose_subscription.py BASE SUBSCRIPTION OUTPUT")
    with open(sys.argv[1], encoding="utf-8") as stream:
        base = yaml.load(stream, Loader=ConfigLoader)
    with open(sys.argv[2], encoding="utf-8") as stream:
        subscription = yaml.load(stream, Loader=ConfigLoader)
    result = compose(base, subscription)
    with open(sys.argv[3], "w", encoding="utf-8") as stream:
        yaml.safe_dump(result, stream, allow_unicode=True, sort_keys=False, width=1000)


if __name__ == "__main__":
    main()
