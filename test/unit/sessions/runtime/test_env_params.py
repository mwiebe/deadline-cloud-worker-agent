# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

"""Unit tests for ENV_PARAMS (RFC 0010) handling in the session runtimes.

The real-session behavior (values bound in onEnter/onExit, PATH mapping) is in
test/unit/sessions/test_env_params_end_to_end.py. These tests pin the plumbing.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Generator
from unittest.mock import MagicMock, patch

import pytest
from openjd.expr import SerializedSymbolTable
from openjd.model._v1.job import EnvironmentParameterValues

from deadline_worker_agent.sessions._extensions import (
    ENV_PARAMS_EXTENSION,
    RUNTIME_CAPABILITY_EXTENSIONS,
    session_extensions,
)
from deadline_worker_agent.sessions.job_entities.environment_details import EnvironmentDetails
from deadline_worker_agent.sessions.runtime import (
    EnvironmentParametersUnsupportedError,
    ResolvedSymbolTableError,
    SessionRuntimeConfig,
)
from deadline_worker_agent.sessions.runtime import python as python_module
from deadline_worker_agent.sessions.runtime import rust as rust_module
from deadline_worker_agent.sessions.runtime._env_params import has_env_params, split_env_params
from deadline_worker_agent.sessions.runtime.python import PythonSessionRuntime
from deadline_worker_agent.sessions.runtime.rust import RustSessionRuntime

_JOB_NAME = {"name": "Job.Name", "type": "string", "value": "J"}
_FLAVOR = {"name": "Env.Param.Flavor", "type": "string", "value": "red"}
_COUNT = {"name": "Env.Param.Count", "type": "int", "value": "2"}
_RAW = {"name": "Env.RawParam.Flavor", "type": "string", "value": "red"}


def _table(*entries: dict[str, str]) -> str:
    return json.dumps(list(entries))


class TestSplitEnvParams:
    def test_none_passes_through(self) -> None:
        split = split_env_params(None)
        assert split.base_json is None
        assert split.env_param_values_json is None

    def test_table_without_env_params_is_returned_unchanged(self) -> None:
        table = _table(_JOB_NAME)
        split = split_env_params(table)
        assert split.base_json is table
        assert split.env_param_values_json is None

    def test_env_params_are_split_out_with_bare_names(self) -> None:
        split = split_env_params(_table(_JOB_NAME, _FLAVOR, _COUNT))
        assert json.loads(split.base_json or "") == [_JOB_NAME]
        assert json.loads(split.env_param_values_json or "") == [
            {"name": "Flavor", "type": "string", "value": "red"},
            {"name": "Count", "type": "int", "value": "2"},
        ]

    def test_raw_params_are_dropped_because_the_session_derives_them(self) -> None:
        split = split_env_params(_table(_JOB_NAME, _FLAVOR, _RAW))
        assert json.loads(split.base_json or "") == [_JOB_NAME]
        assert [e["name"] for e in json.loads(split.env_param_values_json or "")] == ["Flavor"]

    def test_raw_params_only_leaves_no_values(self) -> None:
        split = split_env_params(_table(_JOB_NAME, _RAW))
        assert json.loads(split.base_json or "") == [_JOB_NAME]
        assert split.env_param_values_json is None

    @pytest.mark.parametrize("table", ["{not json", '{"a": 1}', "[1, 2]", '[{"type": "int"}]'])
    def test_malformed_table_passes_through_for_the_normal_parse_to_report(
        self, table: str
    ) -> None:
        split = split_env_params(table)
        assert split.base_json == table
        assert split.env_param_values_json is None

    def test_has_env_params(self) -> None:
        assert has_env_params(_table(_JOB_NAME, _FLAVOR))
        assert not has_env_params(_table(_JOB_NAME, _RAW))
        assert not has_env_params(_table(_JOB_NAME))
        assert not has_env_params(None)
        assert not has_env_params("{not json")


@pytest.fixture()
def runtime_config(tmp_path: Path) -> SessionRuntimeConfig:
    return SessionRuntimeConfig(
        session_id="session-1",
        job_parameter_values={},
        path_mapping_rules=None,
        retain_working_dir=False,
        user=None,
        action_callback=lambda session_id, status: None,
        os_env_vars=None,
        session_root_directory=tmp_path,
        supported_extensions=("ENV_PARAMS", "EXPR"),
    )


_RAW_ENV: dict[str, Any] = {"name": "Tool", "variables": {"F": "{{Env.Param.Flavor}}"}}


class TestRustRuntimeEnvParams:
    @pytest.fixture()
    def session(self) -> Generator[MagicMock, None, None]:
        with patch.object(rust_module, "OpenJDRustSession", autospec=True) as mock_cls:
            yield mock_cls.return_value

    def test_enter_passes_env_param_values_and_base_table(
        self, runtime_config: SessionRuntimeConfig, session: MagicMock
    ) -> None:
        RustSessionRuntime(runtime_config).enter_environment(
            environment=dict(_RAW_ENV),
            identifier="JOB:job-1:Tool@step-1",
            resolved_symbol_table_json=_table(_JOB_NAME, _FLAVOR, _COUNT),
        )

        kwargs = session.enter_environment.call_args.kwargs
        assert kwargs["environment"].name == "Tool"
        assert kwargs["identifier"] == "JOB:job-1:Tool@step-1"
        base = kwargs["resolved_symtab"].to_symtab()
        assert base.get("Job.Name").item() == "J"
        assert "Env" not in base
        parameters = kwargs["parameters"]
        assert isinstance(parameters, EnvironmentParameterValues)
        assert parameters.environment == "Tool"
        assert parameters.document is None or parameters.document.is_job_template
        values = parameters.values.to_symtab()
        assert values.get("Flavor").item() == "red"
        assert values.get("Count").item() == 2

    def test_enter_accepts_pydantic_environment_with_env_params(
        self, runtime_config: SessionRuntimeConfig, session: MagicMock
    ) -> None:
        """A Step Environment parsed by pydantic still gets its values bound."""
        environment = EnvironmentDetails.from_boto(
            {
                "jobId": "job-1",
                "environmentId": "STEP:step-1:Tool",
                "schemaVersion": "jobtemplate-2023-09",
                "template": dict(_RAW_ENV),
                "extensions": ["EXPR"],
            }
        ).environment
        assert not isinstance(environment, dict)

        RustSessionRuntime(runtime_config).enter_environment(
            environment=environment,
            resolved_symbol_table_json=_table(_FLAVOR),
        )

        assert session.enter_environment.call_args.kwargs["parameters"].environment == "Tool"

    def test_enter_without_env_params_does_not_pass_parameters(
        self, runtime_config: SessionRuntimeConfig, session: MagicMock
    ) -> None:
        RustSessionRuntime(runtime_config).enter_environment(
            environment={"name": "Plain", "variables": {"A": "b"}},
            resolved_symbol_table_json=_table(_JOB_NAME),
        )

        assert "parameters" not in session.enter_environment.call_args.kwargs

    def test_enter_fails_on_unparseable_values(
        self, runtime_config: SessionRuntimeConfig, session: MagicMock
    ) -> None:
        bad = {"name": "Env.Param.Count", "type": "no-such-type", "value": "2"}
        runtime = RustSessionRuntime(runtime_config)
        with patch.object(
            rust_module.SerializedSymbolTable,
            "from_json_str",
            side_effect=[SerializedSymbolTable.from_json_str(_table(_JOB_NAME)), ValueError("x")],
        ):
            with pytest.raises(ResolvedSymbolTableError, match="Env.Param"):
                runtime.enter_environment(
                    environment=dict(_RAW_ENV),
                    resolved_symbol_table_json=_table(_JOB_NAME, bad),
                )
        session.enter_environment.assert_not_called()

    def test_exit_strips_env_params_from_the_table(
        self, runtime_config: SessionRuntimeConfig, session: MagicMock
    ) -> None:
        RustSessionRuntime(runtime_config).exit_environment(
            identifier="JOB:job-1:Tool@step-1",
            resolved_symbol_table_json=_table(_JOB_NAME, _FLAVOR),
        )

        kwargs = session.exit_environment.call_args.kwargs
        assert "parameters" not in kwargs
        assert "Env" not in kwargs["resolved_symtab"].to_symtab()


class TestPythonRuntimeEnvParams:
    @pytest.fixture()
    def session(self) -> Generator[MagicMock, None, None]:
        with patch.object(python_module, "OpenJDSession", autospec=True) as mock_cls:
            yield mock_cls.return_value

    def test_refuses_raw_environment(
        self, runtime_config: SessionRuntimeConfig, session: MagicMock
    ) -> None:
        with pytest.raises(EnvironmentParametersUnsupportedError, match="'Tool'.*Rust"):
            PythonSessionRuntime(runtime_config).enter_environment(environment=dict(_RAW_ENV))
        session.enter_environment.assert_not_called()

    def test_refuses_table_with_env_params(
        self, runtime_config: SessionRuntimeConfig, session: MagicMock
    ) -> None:
        environment = MagicMock()
        environment.name = "Step"
        with pytest.raises(EnvironmentParametersUnsupportedError, match="'Step'"):
            PythonSessionRuntime(runtime_config).enter_environment(
                environment=environment, resolved_symbol_table_json=_table(_JOB_NAME, _FLAVOR)
            )
        session.enter_environment.assert_not_called()


class TestEnvironmentDetailsEnvParams:
    def _payload(self, extensions: list[str]) -> Any:
        return {
            "jobId": "job-1",
            "environmentId": "JOB:job-1:Tool@step-1",
            "schemaVersion": "jobtemplate-2023-09",
            "template": {
                **_RAW_ENV,
                "envParameterDefinitions": [{"name": "Flavor", "type": "STRING"}],
            },
            "extensions": extensions,
            "resolvedSymbolTable": _table(_JOB_NAME, _FLAVOR),
        }

    def test_env_params_job_keeps_the_wire_form(self) -> None:
        payload = self._payload(["ENV_PARAMS", "EXPR"])
        details = EnvironmentDetails.from_boto(payload)
        assert details.environment == payload["template"]
        assert details.environment is not payload["template"]
        assert details.resolved_symbol_table_json == payload["resolvedSymbolTable"]

    def test_other_jobs_still_use_the_pydantic_model(self) -> None:
        with pytest.raises(Exception, match="envParameterDefinitions"):
            EnvironmentDetails.from_boto(self._payload(["EXPR"]))


def test_runtime_capabilities_include_env_params() -> None:
    assert ENV_PARAMS_EXTENSION in RUNTIME_CAPABILITY_EXTENSIONS
    assert ENV_PARAMS_EXTENSION in session_extensions(None)
    assert ENV_PARAMS_EXTENSION in session_extensions(["ENV_PARAMS"])
    assert ENV_PARAMS_EXTENSION not in session_extensions([])
