# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, cast

from openjd.model import TemplateSpecificationVersion, UnsupportedSchema
from openjd._openjd_rs import deserialize_step

from ...api_models import StepDetailsData
from .job_entity_type import JobEntityType
from .validation import Field, validate_object


@dataclass
class StepDetails:
    """Details required to perform work for a step"""

    ENTITY_TYPE = JobEntityType.STEP_DETAILS.value

    step_template: Any
    """The deserialized Step object."""

    step_id: str

    dependencies: list[str] = field(default_factory=list)

    @property
    def script(self):
        """The step's script."""
        return self.step_template.script

    @classmethod
    def from_boto(cls, step_details_data: StepDetailsData) -> StepDetails:
        schema_version = TemplateSpecificationVersion(step_details_data["schemaVersion"])

        if schema_version == TemplateSpecificationVersion.JOBTEMPLATE_v2023_09:
            details_data = step_details_data["template"]
            if "name" not in details_data:
                details_data = {"name": "Placeholder", "script": details_data}
            step = deserialize_step(details_data)
        else:
            raise UnsupportedSchema(schema_version.value)

        return StepDetails(
            step_template=step,
            step_id=step_details_data["stepId"],
            dependencies=step_details_data.get("dependencies", []),
        )

    @classmethod
    def validate_entity_data(cls, entity_data: dict[str, Any]) -> StepDetailsData:
        if not isinstance(entity_data, dict):
            raise ValueError(f"Expected a JSON object but got {type(entity_data)}")
        validate_object(
            data=entity_data,
            fields=(
                Field(key="jobId", expected_type=str, required=True),
                Field(key="schemaVersion", expected_type=str, required=True),
                Field(key="template", expected_type=dict, required=True),
                Field(key="stepId", expected_type=str, required=True),
                Field(key="dependencies", expected_type=list, required=False),
            ),
        )
        if dependencies := entity_data.get("dependencies"):
            for dependency in dependencies:
                if not isinstance(dependency, str):
                    raise ValueError(
                        f"Expected dependencies to be strings but got {type(dependency)}"
                    )
        return cast(StepDetailsData, entity_data)
