# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

from __future__ import annotations
from dataclasses import dataclass
from typing import Any, cast

from openjd.model._v1 import TemplateSpecificationVersion, UnsupportedSchema
from openjd._openjd_rs import decode_environment_template_dict, create_environment

from ...api_models import EnvironmentDetailsData
from .job_entity_type import JobEntityType
from .validation import Field, validate_object


@dataclass
class EnvironmentDetails:
    """Details required to activate and deactivate environments"""

    ENTITY_TYPE = JobEntityType.ENVIRONMENT_DETAILS.value

    environment: Any
    """The environment (Rust Environment object with unresolved format strings)"""

    @classmethod
    def from_boto(cls, environment_details_data: EnvironmentDetailsData) -> EnvironmentDetails:
        schema_version = TemplateSpecificationVersion(environment_details_data["schemaVersion"])

        if schema_version in (
            TemplateSpecificationVersion.JOBTEMPLATE_v2023_09,
            TemplateSpecificationVersion.ENVIRONMENT_v2023_09,
        ):
            env_template = decode_environment_template_dict(
                {
                    "specificationVersion": "environment-2023-09",
                    "environment": environment_details_data["template"],
                }
            )
            environment = create_environment(env_template)
        else:
            raise UnsupportedSchema(schema_version.value)

        return EnvironmentDetails(environment=environment)

    @classmethod
    def validate_entity_data(cls, entity_data: dict[str, Any]) -> EnvironmentDetailsData:
        validate_object(
            data=entity_data,
            fields=(
                Field(key="template", expected_type=dict, required=True),
                Field(key="environmentId", expected_type=str, required=True),
                Field(key="jobId", expected_type=str, required=True),
                Field(key="schemaVersion", expected_type=str, required=True),
            ),
        )
        return cast(EnvironmentDetailsData, entity_data)
