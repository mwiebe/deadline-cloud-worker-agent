# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

from typing import Any

import pytest

from openjd.model._v1.types import (
    JobParameterType,
    JobParameterValue,
    TaskParameterType,
    TaskParameterValue,
)

from deadline_worker_agent.sessions.job_entities.job_details import (
    job_parameters_from_api_response,
    task_parameters_from_api_response,
)


class TestJobParametersFromApiResponse:
    @pytest.mark.parametrize(
        "param_name, param_dict, expected_type, expected_value",
        [
            ("stringParam", {"string": "value"}, JobParameterType.STRING, "value"),
            ("pathParam", {"path": "/path/to/file"}, JobParameterType.PATH, "/path/to/file"),
            ("intParam", {"int": "42"}, JobParameterType.INT, "42"),
            ("floatParam", {"float": "3.14"}, JobParameterType.FLOAT, "3.14"),
        ],
    )
    def test_supported_types(self, param_name, param_dict, expected_type, expected_value):
        # GIVEN
        params = {param_name: param_dict}

        # WHEN
        result = job_parameters_from_api_response(params)

        # THEN
        assert len(result) == 1
        assert isinstance(result[param_name], JobParameterValue)
        assert result[param_name].type == expected_type
        assert result[param_name].value == expected_value

    def test_chunk_int_rejected(self) -> None:
        """Job parameters never carry CHUNK_INT — chunked-integer values
        are task-only. Receiving one in a job-parameter API response is
        a service-side error and must be surfaced, not silently coerced.
        """
        # GIVEN — a malformed payload typed as Any to bypass the
        # statically rejected ChunkIntParameter so we can exercise the
        # runtime guard.
        params: dict[str, Any] = {"chunkIntParam": {"chunkInt": "1-5"}}

        # WHEN / THEN
        with pytest.raises(ValueError, match="unknown form"):
            job_parameters_from_api_response(params)

    def test_unknown_form_rejected(self) -> None:
        # GIVEN — typed as Any so mypy doesn't reject the deliberately
        # malformed value before pytest can.
        params: dict[str, Any] = {"weirdParam": {"bogus": "x"}}

        # WHEN / THEN
        with pytest.raises(ValueError, match="unknown form"):
            job_parameters_from_api_response(params)


class TestTaskParametersFromApiResponse:
    @pytest.mark.parametrize(
        "param_name, param_dict, expected_type, expected_value",
        [
            ("stringParam", {"string": "value"}, TaskParameterType.STRING, "value"),
            ("pathParam", {"path": "/path/to/file"}, TaskParameterType.PATH, "/path/to/file"),
            ("intParam", {"int": "42"}, TaskParameterType.INT, "42"),
            ("floatParam", {"float": "3.14"}, TaskParameterType.FLOAT, "3.14"),
            ("chunkIntParam", {"chunkInt": "1-5"}, TaskParameterType.CHUNK_INT, "1-5"),
        ],
    )
    def test_supported_types(self, param_name, param_dict, expected_type, expected_value):
        # GIVEN
        params = {param_name: param_dict}

        # WHEN
        result = task_parameters_from_api_response(params)

        # THEN
        assert len(result) == 1
        assert isinstance(result[param_name], TaskParameterValue)
        assert result[param_name].type == expected_type
        assert result[param_name].value == expected_value

    def test_unknown_form_rejected(self) -> None:
        # GIVEN — typed as Any so mypy doesn't reject the deliberately
        # malformed value before pytest can.
        params: dict[str, Any] = {"weirdParam": {"bogus": "x"}}

        # WHEN / THEN
        with pytest.raises(ValueError, match="unknown form"):
            task_parameters_from_api_response(params)
