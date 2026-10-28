# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

"""ENV_PARAMS (OpenJD RFC 0010) values carried in a resolved symbol table.

The service sends the effective environment parameter values that a Step
supplies to a Job Environment inside that environment entity's
``resolvedSymbolTable``, as ``Env.Param.<name>`` entries (typed, PATH values
not path-mapped). openjd-sessions takes them separately, as the
``parameters`` of ``Session.enter_environment``, and binds ``Env.Param.*`` and
``Env.RawParam.*`` itself. This module splits the two parts apart.

Pure Python on purpose: the Python session runtime uses it to detect (and
refuse) ENV_PARAMS environments, and must not load the native extension at
import time (see test_import_purity.py).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

__all__ = [
    "ENV_PARAM_PREFIX",
    "ENV_RAW_PARAM_PREFIX",
    "SplitSymbolTable",
    "has_env_params",
    "split_env_params",
]

ENV_PARAM_PREFIX = "Env.Param."
ENV_RAW_PARAM_PREFIX = "Env.RawParam."


@dataclass(frozen=True)
class SplitSymbolTable:
    """A resolved symbol table split into its base part and its ENV_PARAMS values."""

    base_json: str | None
    """The table without ``Env.Param.*`` / ``Env.RawParam.*`` entries, or None if none was served."""

    env_param_values_json: str | None
    """The ``Env.Param.*`` entries keyed by their bare parameter names, in the
    SerializedSymbolTable JSON transport form. None when the table has none."""


def _entries(json_str: str | None) -> list[dict[str, Any]] | None:
    """Return the table's entries, or None if the text is not a well-formed entry list.

    A malformed table is not reported here. The caller passes it through
    unchanged, so the existing resolvedSymbolTable parse reports it the same way
    as for any other job.
    """
    if json_str is None:
        return None
    try:
        data = json.loads(json_str)
    except ValueError:
        return None
    if not isinstance(data, list) or not all(
        isinstance(entry, dict) and isinstance(entry.get("name"), str) for entry in data
    ):
        return None
    return data


def _is_env_param_entry(entry: dict[str, Any]) -> bool:
    name: str = entry["name"]
    return name.startswith(ENV_PARAM_PREFIX) or name.startswith(ENV_RAW_PARAM_PREFIX)


def has_env_params(json_str: str | None) -> bool:
    """True when the table carries at least one ``Env.Param.*`` entry."""
    entries = _entries(json_str)
    return entries is not None and any(
        entry["name"].startswith(ENV_PARAM_PREFIX) for entry in entries
    )


def split_env_params(json_str: str | None) -> SplitSymbolTable:
    """Split ``Env.Param.*`` entries out of a resolved symbol table.

    ``Env.RawParam.*`` entries are dropped: the session derives them from the
    ``Env.Param.*`` values it is given. A table without ENV_PARAMS entries, and
    a malformed one, come back unchanged as ``base_json``.
    """
    entries = _entries(json_str)
    if entries is None or not any(_is_env_param_entry(entry) for entry in entries):
        return SplitSymbolTable(base_json=json_str, env_param_values_json=None)

    base = [entry for entry in entries if not _is_env_param_entry(entry)]
    values = [
        {**entry, "name": entry["name"][len(ENV_PARAM_PREFIX) :]}
        for entry in entries
        if entry["name"].startswith(ENV_PARAM_PREFIX)
    ]
    return SplitSymbolTable(
        base_json=json.dumps(base, separators=(",", ":")),
        env_param_values_json=json.dumps(values, separators=(",", ":")) if values else None,
    )
