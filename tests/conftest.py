"""
Shared pytest fixtures and configuration for the infra test suite.
"""
import os
import pytest


def pytest_configure(config):
    """Register custom marks so pytest does not emit PytestUnknownMarkWarning."""
    config.addinivalue_line(
        "markers",
        "e2e: end-to-end tests that require ALB_DNS to be set and a live cluster",
    )
    config.addinivalue_line(
        "markers",
        "chaos: chaos tests that require KUBECONFIG and kubectl to be available",
    )


@pytest.fixture(scope="session")
def infra_root():
    """Absolute path to the infra repo root."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture(scope="session")
def scripts_dir(infra_root):
    """Absolute path to the scripts directory."""
    return os.path.join(infra_root, "scripts")


@pytest.fixture(scope="session")
def modules_dir(infra_root):
    """Absolute path to the modules directory."""
    return os.path.join(infra_root, "modules")
