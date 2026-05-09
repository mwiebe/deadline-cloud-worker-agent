# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

import os
import stat
import sys
import time
from logging import Logger
from pathlib import Path
from threading import Event, Thread
from typing import Optional

from openjd.sessions.v1 import PosixSessionUser

from ..aws_credentials.worker_boto3_session import WorkerBoto3Session
from ..config.config import Configuration
from ..log_messages import WorkerHostConfigurationLogEvent, WorkerHostConfigurationStatus

if sys.platform == "win32":
    from ..windows.win_admin_runner import _WindowsScriptRunner


class _HostConfigTimer:
    """Periodically logs elapsed and remaining time while the host configuration script runs.

    The host configuration timeout is enforced server-side — the service backend kills the worker
    when the timeout is reached. This timer provides client-side visibility into the countdown
    so operators can see progress in the logs before the worker is terminated.

    Logs every 30s normally, accelerating to every 10s when ≤60s remain.
    """

    _NORMAL_INTERVAL_S: int = 30
    _ACCELERATED_INTERVAL_S: int = 10
    _ACCELERATE_THRESHOLD_S: int = 60

    def __init__(
        self,
        *,
        timeout_seconds: int,
        logger: Logger,
        farm_id: str,
        fleet_id: str,
        worker_id: str,
    ) -> None:
        self._timeout_seconds = timeout_seconds
        self._logger = logger
        self._farm_id = farm_id
        self._fleet_id = fleet_id
        self._worker_id = worker_id
        self._stop_event = Event()
        self._thread: Optional[Thread] = None

    def start(self) -> None:
        self._thread = Thread(target=self._run, daemon=True, name="host-config-timer")
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=5)

    def _run(self) -> None:
        start_time = time.monotonic()

        while not self._stop_event.is_set():
            elapsed = time.monotonic() - start_time
            remaining = max(0, self._timeout_seconds - elapsed)

            interval = (
                self._ACCELERATED_INTERVAL_S
                if remaining <= self._ACCELERATE_THRESHOLD_S
                else self._NORMAL_INTERVAL_S
            )

            self._stop_event.wait(timeout=interval)
            if self._stop_event.is_set():
                break

            elapsed = time.monotonic() - start_time
            remaining = max(0, self._timeout_seconds - elapsed)

            self._logger.info(
                WorkerHostConfigurationLogEvent(
                    farm_id=self._farm_id,
                    fleet_id=self._fleet_id,
                    worker_id=self._worker_id,
                    message=(
                        f"Host Config Time — Elapsed: {int(elapsed)}s, Remaining: {int(remaining)}s"
                    ),
                    status=WorkerHostConfigurationStatus.RUNNING,
                )
            )

            if remaining <= 0:
                self._logger.warning(
                    WorkerHostConfigurationLogEvent(
                        farm_id=self._farm_id,
                        fleet_id=self._fleet_id,
                        worker_id=self._worker_id,
                        message=(
                            f"Host config timeout expired ({self._timeout_seconds}s). "
                            f"Worker may be terminated by the service."
                        ),
                        status=WorkerHostConfigurationStatus.FAILED,
                    )
                )
                break


class HostConfigurationScriptRunner:
    """Runs a host configuration script using an openjd Session."""

    def __init__(
        self,
        logger: Logger,
        configuration: Configuration,
        worker_id: str,
        session_directory: Path,
        worker_boto3_session: WorkerBoto3Session,
        host_configuration_script: str,
        host_configuration_timeout_seconds: int = 300,
        runas_user=PosixSessionUser(user="root") if sys.platform != "win32" else None,
    ) -> None:
        self._configuration = configuration
        self._worker_id = worker_id
        self._worker_boto3_session = worker_boto3_session
        self._host_configuration_script = host_configuration_script
        self._host_configuration_timeout_seconds = host_configuration_timeout_seconds
        self._log = logger
        self._session_directory = session_directory
        self._runas_user = runas_user
        self._windows_run_as_admin = True

    def _script_file_name(self) -> str:
        return "host_configuration.ps1" if sys.platform == "win32" else "host_configuration.sh"

    def _write_script_file(self) -> str:
        """Write the host configuration script to disk and return its path."""
        script_file_name = self._script_file_name()
        script_path = self._session_directory / script_file_name
        script_path.write_text(self._host_configuration_script)
        if sys.platform != "win32":
            script_path.chmod(script_path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        return str(script_path)

    def _host_configuration_env_vars(self) -> dict[str, str]:
        credentials = self._worker_boto3_session.get_credentials()
        return {
            "DEADLINE_FARM_ID": self._configuration.farm_id,
            "DEADLINE_FLEET_ID": self._configuration.fleet_id,
            "DEADLINE_WORKER_ID": self._worker_id,
            "HOST_CONFIG_TIMEOUT_SECONDS": str(self._host_configuration_timeout_seconds),
            "AWS_ACCESS_KEY_ID": credentials.access_key,
            "AWS_SECRET_ACCESS_KEY": credentials.secret_key,
            "AWS_SESSION_TOKEN": credentials.token,
        }

    def run(self) -> int:
        """Run the host configuration script. Returns exit code (0 = success)."""
        if self._host_configuration_script is None:
            self._log.info(
                WorkerHostConfigurationLogEvent(
                    farm_id=self._configuration.farm_id,
                    fleet_id=self._configuration.fleet_id,
                    worker_id=self._worker_id,
                    message="No host configuration script provided.",
                    status=WorkerHostConfigurationStatus.SKIPPED,
                )
            )
            return 0

        script_file_path = self._write_script_file()

        timer = _HostConfigTimer(
            timeout_seconds=self._host_configuration_timeout_seconds,
            logger=self._log,
            farm_id=self._configuration.farm_id,
            fleet_id=self._configuration.fleet_id,
            worker_id=self._worker_id,
        )
        timer.start()
        try:
            if sys.platform == "win32":
                return self._run_win32(script_file_path)
            return self._run_posix(script_file_path)
        finally:
            timer.stop()

    def _run_posix(self, script_file_path: str) -> int:
        """Run via Session.run_subprocess on POSIX."""
        from openjd._openjd_rs import Session, SessionState, ActionState

        session = Session(
            session_id=f"host-config-{self._worker_id}",
            job_parameter_values={},
            os_env_vars=self._host_configuration_env_vars(),
            session_root_directory=str(self._session_directory),
            retain_working_dir=True,
            user=PosixSessionUser(user=self._runas_user.user if self._runas_user else "root"),
        )

        try:
            session.run_subprocess(
                command=script_file_path,
                timeout=float(self._host_configuration_timeout_seconds),
            )

            # Poll for completion
            while session.state == SessionState.RUNNING:
                time.sleep(0.1)

            status = session.action_status
            if status and status.state == ActionState.SUCCESS and status.exit_code == 0:
                return 0
            return status.exit_code if status and status.exit_code is not None else -1
        finally:
            session.cleanup()

    def _run_win32(self, script_file_path: str) -> int:
        """Run via Windows admin runner."""
        if sys.platform == "win32":
            win32_runner = _WindowsScriptRunner(
                script_path=script_file_path,
                working_directory=self._session_directory,
                logger=self._log,
            )
            return win32_runner.run_powershell(self._host_configuration_env_vars())
        return -1
