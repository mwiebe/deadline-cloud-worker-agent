# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

from __future__ import annotations
from dataclasses import dataclass
from typing import Any, cast

from openjd.model import parse_model, TemplateSpecificationVersion, UnsupportedSchema
from openjd.model.v2023_09 import Environment as Environment_2023_09
from openjd.sessions import EnvironmentModel

from ...api_models import EnvironmentDetailsData
from .._extensions import ENV_PARAMS_EXTENSION, resolve_supported_extensions
from ..runtime._abc import RawEnvironment
from .job_entity_type import JobEntityType
from .validation import Field, validate_object


@dataclass
class EnvironmentDetails:
    """Details required to activate and deactivate environments"""

    ENTITY_TYPE = JobEntityType.ENVIRONMENT_DETAILS.value
    """The JobEntityType handled by this class"""

    environment: EnvironmentModel | RawEnvironment
    """The environment.

    A v2023_09 pydantic model, except for jobs that declare the ENV_PARAMS
    extension: those keep the OpenJD wire-form dict (RawEnvironment), because
    the legacy pydantic model does not implement ENV_PARAMS and rejects its
    keys. The Rust session runtime decodes the dict natively; the Python
    runtime refuses it.
    """

    resolved_symbol_table_json: str | None = None
    """Pre-resolved symbol table JSON from the service, forwarded to the Rust session runtime."""

    @classmethod
    def from_boto(cls, environment_details_data: EnvironmentDetailsData) -> EnvironmentDetails:
        """Converts an environmentDetails entity received from BatchGetJobEntity API response into
        an EnvironmentDetails instance

        Parameters
        ----------
        environment_details_data : EnvironmentDetailsData
            Environment details JSON object as received from BatchGetJobEntity.

        Returns
        -------
        EnvironmentDetails:
            A converted EnvironmentDetails instance.

        Raises
        ------
        RuntimeError:
            If the environment's Open Job Description schema version not unsupported
        """

        schema_version = TemplateSpecificationVersion(environment_details_data["schemaVersion"])

        environment: EnvironmentModel | RawEnvironment
        if schema_version in (
            TemplateSpecificationVersion.JOBTEMPLATE_v2023_09,
            TemplateSpecificationVersion.ENVIRONMENT_v2023_09,
        ):
            supported_extensions = resolve_supported_extensions(environment_details_data)
            if ENV_PARAMS_EXTENSION in supported_extensions:
                # Validated by the Rust session runtime's native decode when the
                # environment is entered (deserialize_step), not here.
                environment = dict(environment_details_data["template"])
            else:
                environment = parse_model(
                    model=Environment_2023_09,
                    obj=environment_details_data["template"],
                    supported_extensions=supported_extensions,
                )
        else:
            raise UnsupportedSchema(schema_version.value)

        return EnvironmentDetails(
            environment=environment,
            resolved_symbol_table_json=environment_details_data.get("resolvedSymbolTable", None),
        )

    @classmethod
    def validate_entity_data(cls, entity_data: dict[str, Any]) -> EnvironmentDetailsData:
        """
        Performs input validation on an entity response JSON object received from boto3's call to
        the BatchGetJobEntity AWS Deadline Cloud API.

        Parameters
        ----------
        entity_data : dict[str, Any]
            The environmentDetails entity data received from BatchGetJobEntity

        Returns
        -------
        deadline_worker_agent.api_models.EnvironmentDetailsData:
            A validated EnvironmentDetailsData instance

        Raises
        ------
        ValueError:
            Validation failure
        """

        validate_object(
            data=entity_data,
            fields=(
                Field(key="template", expected_type=dict, required=True),
                Field(key="environmentId", expected_type=str, required=True),
                Field(key="jobId", expected_type=str, required=True),
                Field(key="schemaVersion", expected_type=str, required=True),
                Field(key="resolvedSymbolTable", expected_type=str, required=False),
                Field(key="extensions", expected_type=list, required=False),
            ),
        )

        return cast(EnvironmentDetailsData, entity_data)
