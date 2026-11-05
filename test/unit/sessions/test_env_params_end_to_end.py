# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

"""End-to-end coverage for ENV_PARAMS (OpenJD RFC 0010) environments.

This drives the worker's real chain for entering and exiting a parameterized
Job Environment --

    BatchGetJobEntity payload (per-Step environment entity)
      -> EnvironmentDetails.from_boto     (real; keeps the wire-form dict)
      -> EnterEnvironmentAction.start     (real action)
      -> Session.enter_environment        (stood in for; see _EnvOnlySession)
      -> RustSessionRuntime               (real adapter)
      -> openjd.sessions._v1.Session      (real Rust session, real subprocess)

-- and asserts on the files the environment's actions wrote. The service sends
the Step's effective values as ``Env.Param.<name>`` entries of the entity's
``resolvedSymbolTable`` (prototype contract, notes/env-params-box-plan.md §6.3).
"""

from __future__ import annotations

import dataclasses
import json
import os
import shlex
import time
import uuid
from pathlib import Path
from typing import Any, cast
from unittest.mock import Mock

import pytest
from openjd.sessions import ActionState, PathFormat, PathMappingRule

from deadline_worker_agent.api_models import EnvironmentDetailsData
from deadline_worker_agent.sessions.actions.enter_env import EnterEnvironmentAction
from deadline_worker_agent.sessions.actions.exit_env import ExitEnvironmentAction
from deadline_worker_agent.sessions.job_entities.environment_details import EnvironmentDetails
from deadline_worker_agent.sessions.runtime import (
    EnvironmentParametersUnsupportedError,
    SessionRuntime,
    SessionRuntimeConfig,
)
from deadline_worker_agent.sessions.runtime.python import PythonSessionRuntime
from deadline_worker_agent.sessions.runtime.rust import RustSessionRuntime

pytestmark = pytest.mark.skipif(os.name != "posix", reason="the actions run bash")

_ACTION_TIMEOUT = 30.0
_JOB_ID = "job-" + "1" * 32
_STEP_ID = "step-" + "2" * 32
_ENV_ID = f"JOB:{_JOB_ID}:Tool@{_STEP_ID}"


class _EnvOnlySession:
    """Stands in for ``deadline_worker_agent.sessions.Session``.

    Its enter/exit methods forward to the runtime (pinned separately by
    test_session.py), so this reproduces that one hop and lets the real runtime
    and the real openjd session do the work.
    """

    def __init__(self, runtime: SessionRuntime) -> None:
        self._runtime = runtime
        self._session_env_id: str | None = None
        self._table: str | None = None

    def enter_environment(
        self, *, job_env_id: str, resolved_symbol_table_json: str | None = None, **kwargs: Any
    ) -> None:
        self._session_env_id = self._runtime.enter_environment(
            identifier=job_env_id, resolved_symbol_table_json=resolved_symbol_table_json, **kwargs
        )
        self._table = resolved_symbol_table_json

    def exit_environment(
        self, *, job_env_id: str, resolved_symbol_table_json: str | None = None, **kwargs: Any
    ) -> None:
        assert self._session_env_id is not None
        self._runtime.exit_environment(
            identifier=self._session_env_id,
            resolved_symbol_table_json=resolved_symbol_table_json or self._table,
            **kwargs,
        )


def _write(path: Path, text: str) -> dict[str, Any]:
    return {
        "command": "bash",
        "args": ["-c", f"printf %s {shlex.quote(text)} > {shlex.quote(str(path))}"],
    }


def _details(out: Path, *, table: list[dict[str, str]]) -> EnvironmentDetails:
    """The per-Step entity the prototype Data Plane serves for Job Environment ``Tool``."""
    template = {
        "name": "Tool",
        "variables": {"TOOL_FLAVOR": "{{Env.Param.Flavor}}", "TOOL_COUNT": "{{Env.Param.Count}}"},
        "script": {
            "actions": {
                "onEnter": _write(
                    out / "enter.txt",
                    "{{Env.Param.Flavor}}:{{Env.Param.Count}}:{{Env.Param.Dir}}:"
                    "{{Env.RawParam.Dir}}:{{Job.Name}}",
                ),
                "onExit": _write(out / "exit.txt", "{{Env.Param.Flavor}}:{{Env.Param.Count}}"),
            }
        },
    }
    payload: EnvironmentDetailsData = {
        "jobId": _JOB_ID,
        "environmentId": _ENV_ID,
        "schemaVersion": "jobtemplate-2023-09",
        "template": template,
        "extensions": ["ENV_PARAMS", "EXPR"],
        "resolvedSymbolTable": json.dumps(table),
    }
    return EnvironmentDetails.from_boto(payload)


_TABLE = [
    {"name": "Job.Name", "type": "string", "value": "env_params_check"},
    {"name": "Env.Param.Flavor", "type": "string", "value": "red"},
    {"name": "Env.Param.Count", "type": "int", "value": "2"},
    {"name": "Env.Param.Dir", "type": "path", "value": "/mnt/src/tools"},
]


def _config(session_root: Path, extensions: tuple[str, ...]) -> SessionRuntimeConfig:
    session_root.mkdir(parents=True, exist_ok=True)
    return SessionRuntimeConfig(
        session_id=f"session-{uuid.uuid4().hex}",
        job_parameter_values={},
        path_mapping_rules=[
            PathMappingRule(
                source_path_format=PathFormat.POSIX,
                source_path=Path("/mnt/src"),
                destination_path=Path("/local/dst"),
            )
        ],
        retain_working_dir=False,
        user=None,
        action_callback=lambda session_id, status: None,
        os_env_vars=None,
        session_root_directory=session_root,
        supported_extensions=extensions,
    )


def _wait(runtime: SessionRuntime) -> ActionState:
    deadline = time.monotonic() + _ACTION_TIMEOUT
    while True:
        status = runtime.action_status
        if status is not None and status.state != ActionState.RUNNING:
            return status.state
        if time.monotonic() > deadline:
            pytest.fail(f"action did not finish within {_ACTION_TIMEOUT}s (last status: {status})")
        time.sleep(0.05)


class TestEnvParamsEndToEnd:
    def test_rust_runtime_binds_env_params_on_enter_and_exit(self, tmp_path: Path) -> None:
        """Env.Param.* resolves from the served table in onEnter (PATH mapped,
        RawParam unmapped) and again in onExit, without the exit action carrying
        the values: the session keeps them from enter."""
        out = tmp_path / "out"
        out.mkdir()
        details = _details(out, table=_TABLE)
        assert isinstance(details.environment, dict)

        runtime = RustSessionRuntime(_config(tmp_path / "sessions", ("ENV_PARAMS", "EXPR")))
        # Typed as Any: it stands in for the real Session (see _EnvOnlySession).
        session: Any = _EnvOnlySession(runtime)
        try:
            EnterEnvironmentAction(id="sessionaction-1", job_env_id=_ENV_ID, details=details).start(
                session=session,
                executor=Mock(),  # type: ignore[arg-type]
            )
            assert _wait(runtime) == ActionState.SUCCESS
            assert (out / "enter.txt").read_text() == (
                "red:2:/local/dst/tools:/mnt/src/tools:env_params_check"
            )

            ExitEnvironmentAction(id="sessionaction-2", environment_id=_ENV_ID).start(
                session=session,
                executor=Mock(),  # type: ignore[arg-type]
            )
            assert _wait(runtime) == ActionState.SUCCESS
            assert (out / "exit.txt").read_text() == "red:2"
        finally:
            runtime.cleanup()

    def test_python_runtime_refuses_env_params_environment(self, tmp_path: Path) -> None:
        """The legacy runtime has no ENV_PARAMS; it fails before running anything."""
        out = tmp_path / "out"
        out.mkdir()
        details = _details(out, table=_TABLE)

        runtime = PythonSessionRuntime(_config(tmp_path / "sessions", ("ENV_PARAMS", "EXPR")))
        try:
            with pytest.raises(EnvironmentParametersUnsupportedError, match="'Tool'"):
                EnterEnvironmentAction(
                    id="sessionaction-1", job_env_id=_ENV_ID, details=details
                ).start(
                    session=cast(Any, _EnvOnlySession(runtime)),
                    executor=Mock(),  # type: ignore[arg-type]
                )
            assert not (out / "enter.txt").exists()
        finally:
            runtime.cleanup()


def _config_with_rules(
    session_root: Path, rules: list[PathMappingRule], callback: Any = None
) -> SessionRuntimeConfig:
    config = _config(session_root, ("ENV_PARAMS", "EXPR"))
    changes: dict[str, Any] = {"path_mapping_rules": rules}
    if callback is not None:
        changes["action_callback"] = callback
    return dataclasses.replace(config, **changes)


def _rule(source: str, destination: str) -> PathMappingRule:
    return PathMappingRule(
        source_path_format=PathFormat.POSIX,
        source_path=Path(source),
        destination_path=Path(destination),
    )


class TestRustRuntimeOnBindingsC0333380:
    """Behavior of the Rust session that changed with the bindings built on
    openjd-rs-ep c0333380 (openjd-expr 0.13), as the worker sees it."""

    def test_invalid_rule_at_construction_is_a_value_error(self, tmp_path: Path) -> None:
        """The scheduler fails a session's actions for ValueError and keeps running,
        so a rule the Rust session rejects must arrive as ValueError."""
        with pytest.raises(ValueError, match="must be an absolute POSIX path") as excinfo:
            RustSessionRuntime(
                _config_with_rules(tmp_path / "sessions", [_rule("relative/src", "/local/dst")])
            )
        assert type(excinfo.value) is ValueError
        assert excinfo.value.__cause__ is not None

    def test_invalid_added_rule_is_a_value_error_and_keeps_the_rules(self, tmp_path: Path) -> None:
        """A bad job attachment rule fails the action with the message, and the
        session keeps mapping with the rules it had."""
        out = tmp_path / "out"
        out.mkdir()
        runtime = RustSessionRuntime(
            _config_with_rules(tmp_path / "sessions", [_rule("/mnt/src", "/local/dst")])
        )
        session: Any = _EnvOnlySession(runtime)
        try:
            with pytest.raises(ValueError, match="path mapping rule 1: source_path 'relative'"):
                runtime.extend_path_mapping_rules([_rule("relative", "/local/ja")])
            EnterEnvironmentAction(
                id="sessionaction-1", job_env_id=_ENV_ID, details=_details(out, table=_TABLE)
            ).start(session=session, executor=Mock())  # type: ignore[arg-type]
            assert _wait(runtime) == ActionState.SUCCESS
            assert (out / "enter.txt").read_text().split(":")[2] == "/local/dst/tools"
        finally:
            runtime.cleanup()

    def test_added_rule_for_the_same_location_wins(self, tmp_path: Path) -> None:
        """Rule precedence changed: between rules for the same source path the
        last one given applies, so a job attachment rule added after the
        storage profile rules overrides them. A PATH env param shows it."""
        out = tmp_path / "out"
        out.mkdir()
        runtime = RustSessionRuntime(
            _config_with_rules(tmp_path / "sessions", [_rule("/mnt/src", "/local/storage")])
        )
        session: Any = _EnvOnlySession(runtime)
        try:
            runtime.extend_path_mapping_rules([_rule("/mnt/src", "/local/attachments")])
            EnterEnvironmentAction(
                id="sessionaction-1", job_env_id=_ENV_ID, details=_details(out, table=_TABLE)
            ).start(session=session, executor=Mock())  # type: ignore[arg-type]
            assert _wait(runtime) == ActionState.SUCCESS
            assert (out / "enter.txt").read_text().split(":")[2:4] == [
                "/local/attachments/tools",
                "/mnt/src/tools",
            ]
        finally:
            runtime.cleanup()

    def test_refused_exit_reports_failed_not_the_previous_status(self, tmp_path: Path) -> None:
        """An action the Rust session refuses before it starts ends FAILED with its
        own message. Before c84c217 the previous action's SUCCESS was reported."""
        out = tmp_path / "out"
        out.mkdir()
        updates: list[ActionState] = []
        runtime = RustSessionRuntime(
            _config_with_rules(
                tmp_path / "sessions",
                [_rule("/mnt/src", "/local/dst")],
                callback=lambda session_id, status: updates.append(status.state),
            )
        )
        session: Any = _EnvOnlySession(runtime)
        try:
            EnterEnvironmentAction(
                id="sessionaction-1", job_env_id=_ENV_ID, details=_details(out, table=_TABLE)
            ).start(session=session, executor=Mock())  # type: ignore[arg-type]
            assert _wait(runtime) == ActionState.SUCCESS
            updates.clear()

            runtime.exit_environment(identifier="not-an-entered-environment")
            assert _wait(runtime) == ActionState.FAILED
            status = runtime.action_status
            assert status is not None and status.fail_message
            assert "not-an-entered-environment" in status.fail_message
            assert updates[-1] == ActionState.FAILED
            assert ActionState.SUCCESS not in updates
        finally:
            runtime.cleanup()

    def test_create_job_only_keys_in_the_entity_body_are_ignored(self, tmp_path: Path) -> None:
        """The Data Plane strips activation, exclusiveGroup and enableIf from the
        per-Step entity body. If one arrives anyway, the worker's decode
        ignores it and the Environment is entered as usual."""
        out = tmp_path / "out"
        out.mkdir()
        details = _details(out, table=_TABLE)
        assert isinstance(details.environment, dict)
        details.environment["exclusiveGroup"] = "SoftwareProvider"
        details.environment["activation"] = "BY_DEFAULT"

        runtime = RustSessionRuntime(
            _config_with_rules(tmp_path / "sessions", [_rule("/mnt/src", "/local/dst")])
        )
        session: Any = _EnvOnlySession(runtime)
        try:
            EnterEnvironmentAction(id="sessionaction-1", job_env_id=_ENV_ID, details=details).start(
                session=session,
                executor=Mock(),  # type: ignore[arg-type]
            )
            assert _wait(runtime) == ActionState.SUCCESS
            assert (out / "enter.txt").read_text().startswith("red:2:/local/dst/tools")
        finally:
            runtime.cleanup()
