"""
Smoke tests for the deploy-all orchestrator and its configuration.

Validates: Requirements 15.1, 15.2

Tests:
  - deploy-all.ps1 can be invoked with --dry-run and exits 0
  - deploy-all.config.yaml is valid YAML and contains all required fields
  - All repo_path values declared in the config exist on disk
  - All k8s directories declared in the config exist on disk
  - validate.ps1 exists and is executable (non-zero size)
"""

from __future__ import annotations

import os
import platform
import shutil
import stat
import subprocess
import sys

import pytest
import yaml

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
_SCRIPTS_DIR = os.path.join(_REPO_ROOT, "scripts")
_CONFIG_PATH = os.path.join(_SCRIPTS_DIR, "deploy-all.config.yaml")
_DEPLOY_ALL_PS1 = os.path.join(_SCRIPTS_DIR, "deploy-all.ps1")
_VALIDATE_PS1 = os.path.join(_SCRIPTS_DIR, "validate.ps1")
_VALIDATE_SH = os.path.join(_SCRIPTS_DIR, "validate.sh")

# Required top-level fields per service entry (Req 15.1)
REQUIRED_SERVICE_FIELDS = {
    "name",
    "repo_path",
    "dockerfile",
    "build_context",
    "ecr_key",
    "namespace",
    "container_port",
    "ingress_path",
    "health_path",
    "deployments",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_config() -> dict:
    """Load and return the parsed deploy-all.config.yaml."""
    with open(_CONFIG_PATH, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def _resolve_repo_path(repo_path: str) -> str:
    """Resolve a (possibly relative) repo_path to an absolute path."""
    if os.path.isabs(repo_path):
        return repo_path
    # repo_path values like ../fiap-arch-analyzer-auth-service are relative
    # to the infra repo root (parent of scripts/).
    return os.path.normpath(os.path.join(_REPO_ROOT, repo_path))


def _pwsh_executable() -> str | None:
    """Return the path to pwsh (PowerShell 7+) or None if not found."""
    return shutil.which("pwsh") or shutil.which("pwsh.exe")


# ---------------------------------------------------------------------------
# Fixture: parsed config
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def deploy_config() -> dict:
    """Parsed deploy-all.config.yaml."""
    return _load_config()


@pytest.fixture(scope="module")
def services(deploy_config) -> list:
    """List of service entries from the config."""
    return deploy_config.get("services", [])


# ---------------------------------------------------------------------------
# 1. deploy-all.ps1 --dry-run exits 0
# ---------------------------------------------------------------------------


class TestDeployAllDryRun:
    """
    **Validates: Requirements 15.1, 15.2**

    Invoke deploy-all.ps1 with -DryRun so it validates paths and prints
    commands without touching AWS or Kubernetes.  The script must exit 0.
    """

    def test_deploy_all_ps1_exists(self):
        """deploy-all.ps1 must exist in the scripts directory."""
        assert os.path.isfile(_DEPLOY_ALL_PS1), (
            f"deploy-all.ps1 not found at {_DEPLOY_ALL_PS1}"
        )

    @pytest.mark.skipif(
        _pwsh_executable() is None,
        reason="pwsh (PowerShell 7+) not available on this system",
    )
    def test_deploy_all_dry_run_exits_zero(self):
        """
        **Validates: Requirements 15.1, 15.2**

        Running deploy-all.ps1 -DryRun must exit 0.
        In dry-run mode the script loads the config, validates paths, and
        prints commands without executing them.
        """
        pwsh = _pwsh_executable()
        result = subprocess.run(
            [
                pwsh,
                "-NonInteractive",
                "-NoProfile",
                "-File",
                _DEPLOY_ALL_PS1,
                "-DryRun",
                "-ConfigPath",
                _CONFIG_PATH,
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert result.returncode == 0, (
            f"deploy-all.ps1 -DryRun exited {result.returncode}.\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )


# ---------------------------------------------------------------------------
# 2. Config file is valid YAML with all required fields
# ---------------------------------------------------------------------------


class TestConfigFileStructure:
    """
    **Validates: Requirements 15.1**

    The config file must be valid YAML and every service entry must carry
    all required fields.
    """

    def test_config_file_exists(self):
        assert os.path.isfile(_CONFIG_PATH), (
            f"deploy-all.config.yaml not found at {_CONFIG_PATH}"
        )

    def test_config_is_valid_yaml(self):
        """File must parse without errors."""
        config = _load_config()
        assert config is not None, "YAML parsed to None"

    def test_config_has_services_key(self, deploy_config):
        assert "services" in deploy_config, (
            "deploy-all.config.yaml missing top-level 'services' key"
        )

    def test_services_is_non_empty_list(self, services):
        assert isinstance(services, list) and len(services) > 0, (
            "'services' must be a non-empty list"
        )

    @pytest.mark.parametrize(
        "field",
        sorted(REQUIRED_SERVICE_FIELDS),
    )
    def test_all_services_have_required_field(self, services, field):
        """
        **Validates: Requirements 15.1**

        Every service entry must carry the required field.
        """
        for svc in services:
            assert field in svc, (
                f"Service '{svc.get('name', '<unknown>')}' is missing required field '{field}'"
            )

    def test_deployments_field_is_non_empty_list(self, services):
        """Every service must declare at least one deployment name."""
        for svc in services:
            deployments = svc.get("deployments", [])
            assert isinstance(deployments, list) and len(deployments) > 0, (
                f"Service '{svc.get('name')}' has an empty or missing 'deployments' list"
            )

    def test_k8s_dir_defaults_to_k8s_when_absent(self, services):
        """k8s_dir is optional; when absent the orchestrator defaults to 'k8s'."""
        for svc in services:
            k8s_dir = svc.get("k8s_dir", "k8s")
            assert isinstance(k8s_dir, str) and len(k8s_dir) > 0, (
                f"Service '{svc.get('name')}' has an invalid k8s_dir value: {k8s_dir!r}"
            )

    def test_container_port_is_positive_integer(self, services):
        for svc in services:
            port = svc.get("container_port")
            assert isinstance(port, int) and port > 0, (
                f"Service '{svc.get('name')}' has invalid container_port: {port!r}"
            )

    def test_ingress_path_starts_with_slash(self, services):
        for svc in services:
            path = svc.get("ingress_path", "")
            assert path.startswith("/"), (
                f"Service '{svc.get('name')}' ingress_path must start with '/': {path!r}"
            )

    def test_health_path_starts_with_slash(self, services):
        for svc in services:
            path = svc.get("health_path", "")
            assert path.startswith("/"), (
                f"Service '{svc.get('name')}' health_path must start with '/': {path!r}"
            )


# ---------------------------------------------------------------------------
# 3. All repo_path values exist on disk
# ---------------------------------------------------------------------------


class TestRepoPaths:
    """
    **Validates: Requirements 15.2**

    Every repo_path declared in the config must resolve to an existing
    directory on disk.  The orchestrator fails fast when any path is missing.
    """

    def test_all_repo_paths_exist(self, services):
        """
        **Validates: Requirements 15.2**

        Each service's repo_path must resolve to an existing directory.
        """
        missing = []
        for svc in services:
            repo_abs = _resolve_repo_path(svc["repo_path"])
            if not os.path.isdir(repo_abs):
                missing.append(
                    f"  service='{svc['name']}' repo_path='{svc['repo_path']}' "
                    f"resolved='{repo_abs}'"
                )
        assert not missing, (
            "The following repo_path directories are missing:\n" + "\n".join(missing)
        )

    def test_repo_paths_are_not_empty_strings(self, services):
        for svc in services:
            assert svc.get("repo_path", "").strip(), (
                f"Service '{svc.get('name')}' has an empty repo_path"
            )


# ---------------------------------------------------------------------------
# 4. All k8s directories exist on disk
# ---------------------------------------------------------------------------


class TestK8sDirs:
    """
    **Validates: Requirements 15.2**

    Every <repo_path>/<k8s_dir> declared in the config must exist on disk.
    """

    def test_all_k8s_dirs_exist(self, services):
        """
        **Validates: Requirements 15.2**

        Each service's k8s directory must exist inside its repo.
        """
        missing = []
        for svc in services:
            repo_abs = _resolve_repo_path(svc["repo_path"])
            k8s_dir = svc.get("k8s_dir", "k8s")
            k8s_abs = os.path.join(repo_abs, k8s_dir)
            if not os.path.isdir(k8s_abs):
                missing.append(
                    f"  service='{svc['name']}' k8s_dir='{k8s_dir}' "
                    f"resolved='{k8s_abs}'"
                )
        assert not missing, (
            "The following k8s directories are missing:\n" + "\n".join(missing)
        )

    def test_k8s_dirs_contain_at_least_one_yaml(self, services):
        """Each k8s directory must contain at least one YAML manifest."""
        empty_dirs = []
        for svc in services:
            repo_abs = _resolve_repo_path(svc["repo_path"])
            k8s_dir = svc.get("k8s_dir", "k8s")
            k8s_abs = os.path.join(repo_abs, k8s_dir)
            if not os.path.isdir(k8s_abs):
                continue  # already caught by test_all_k8s_dirs_exist
            yaml_files = [
                f for f in os.listdir(k8s_abs)
                if f.endswith(".yaml") or f.endswith(".yml")
            ]
            if not yaml_files:
                empty_dirs.append(
                    f"  service='{svc['name']}' k8s_dir='{k8s_abs}'"
                )
        assert not empty_dirs, (
            "The following k8s directories contain no YAML manifests:\n"
            + "\n".join(empty_dirs)
        )


# ---------------------------------------------------------------------------
# 5. validate script exists and is executable
# ---------------------------------------------------------------------------


class TestValidateScript:
    """
    **Validates: Requirements 15.1, 15.2**

    The validate script must exist and be non-empty (executable).
    On POSIX systems the executable bit is also checked.
    """

    def test_validate_ps1_exists(self):
        """validate.ps1 must exist in the scripts directory."""
        assert os.path.isfile(_VALIDATE_PS1), (
            f"validate.ps1 not found at {_VALIDATE_PS1}"
        )

    def test_validate_ps1_is_non_empty(self):
        """validate.ps1 must have non-zero size."""
        size = os.path.getsize(_VALIDATE_PS1)
        assert size > 0, f"validate.ps1 is empty (0 bytes) at {_VALIDATE_PS1}"

    def test_validate_sh_exists(self):
        """validate.sh must exist in the scripts directory."""
        assert os.path.isfile(_VALIDATE_SH), (
            f"validate.sh not found at {_VALIDATE_SH}"
        )

    def test_validate_sh_is_non_empty(self):
        """validate.sh must have non-zero size."""
        size = os.path.getsize(_VALIDATE_SH)
        assert size > 0, f"validate.sh is empty (0 bytes) at {_VALIDATE_SH}"

    @pytest.mark.skipif(
        platform.system() == "Windows",
        reason="Executable bit check is POSIX-only",
    )
    def test_validate_sh_is_executable(self):
        """On POSIX, validate.sh must have the executable bit set."""
        file_stat = os.stat(_VALIDATE_SH)
        is_exec = bool(file_stat.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
        assert is_exec, (
            f"validate.sh is not executable at {_VALIDATE_SH}. "
            f"Run: chmod +x {_VALIDATE_SH}"
        )

    def test_deploy_all_sh_exists(self):
        """deploy-all.sh must also exist alongside deploy-all.ps1."""
        deploy_sh = os.path.join(_SCRIPTS_DIR, "deploy-all.sh")
        assert os.path.isfile(deploy_sh), (
            f"deploy-all.sh not found at {deploy_sh}"
        )
