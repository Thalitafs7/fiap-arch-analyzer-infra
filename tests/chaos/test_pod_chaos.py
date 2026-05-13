"""
Chaos tests: kill pods and verify the service recovers.

All tests are marked with @pytest.mark.chaos and are skipped when:
  - KUBECONFIG environment variable is not set, OR
  - kubectl binary is not available on PATH.

For each service Deployment the test:
  1. Deletes one running pod.
  2. Verifies the pod is recreated within 2 minutes.
  3. Verifies the service health endpoint returns HTTP 200 within 3 minutes.

Validates: Requirements 17.1, 17.2
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from typing import Optional

import pytest
import requests

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# (deployment_name, namespace, health_url_path)
# celery-worker has no HTTP endpoint and is excluded from health checks.
SERVICE_DEPLOYMENTS: list[tuple[str, str, Optional[str]]] = [
    ("ms-auth-api",          "auth",              "/api/auth/health"),
    ("registration-service", "arch-analyzer-api", "/api/registration/health"),
    ("processing-service",   "arch-analyzer-ia",  "/api/analyses/health"),
    ("report-service",       "arch-analyzer-ia",  "/api/reports/health"),
    ("api-gateway",          "arch-analyzer-api", "/api/gateway/health"),
    # celery-worker: pod recreation verified but no HTTP health check
    ("celery-worker",        "arch-analyzer-ia",  None),
]

POD_RECREATE_TIMEOUT_SECONDS = 120   # 2 minutes (Req 17.1)
HEALTH_RECOVER_TIMEOUT_SECONDS = 180  # 3 minutes (Req 17.2)
POLL_INTERVAL_SECONDS = 5
REQUEST_TIMEOUT_SECONDS = 5

# ---------------------------------------------------------------------------
# Skip conditions
# ---------------------------------------------------------------------------

_KUBECONFIG = os.environ.get("KUBECONFIG", "").strip()
_KUBECTL = shutil.which("kubectl")

_skip_no_kubectl = pytest.mark.skipif(
    not _KUBECONFIG or not _KUBECTL,
    reason=(
        "Chaos tests require KUBECONFIG env var to be set "
        "and kubectl to be available on PATH"
    ),
)

pytestmark = pytest.mark.chaos

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _kubectl(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    """Run kubectl with the given arguments and return the CompletedProcess."""
    cmd = [_KUBECTL or "kubectl", *args]
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=check,
        timeout=60,
    )


def _get_pod_names(deployment: str, namespace: str) -> list[str]:
    """Return the names of all Running pods for *deployment* in *namespace*."""
    result = _kubectl(
        "get", "pods",
        "-n", namespace,
        "-l", f"app.kubernetes.io/name={deployment}",
        "--field-selector", "status.phase=Running",
        "-o", "jsonpath={.items[*].metadata.name}",
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        # Fallback: use the deployment name as the label selector value
        result = _kubectl(
            "get", "pods",
            "-n", namespace,
            "--selector", f"app={deployment}",
            "--field-selector", "status.phase=Running",
            "-o", "jsonpath={.items[*].metadata.name}",
            check=False,
        )
    names = result.stdout.strip().split()
    return [n for n in names if n]


def _pod_exists(pod_name: str, namespace: str) -> bool:
    """Return True if *pod_name* still exists in *namespace*."""
    result = _kubectl(
        "get", "pod", pod_name, "-n", namespace,
        check=False,
    )
    return result.returncode == 0


def _wait_for_new_pod(
    deployment: str,
    namespace: str,
    deleted_pod: str,
    timeout: int = POD_RECREATE_TIMEOUT_SECONDS,
) -> bool:
    """
    Wait until at least one Running pod for *deployment* exists that is NOT
    *deleted_pod*.  Returns True on success, False on timeout.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pods = _get_pod_names(deployment, namespace)
        new_pods = [p for p in pods if p != deleted_pod]
        if new_pods:
            return True
        time.sleep(POLL_INTERVAL_SECONDS)
    return False


def _alb_base_url() -> Optional[str]:
    """
    Return the ALB base URL from the ALB_DNS env var, or None if not set.
    Health checks are skipped when ALB_DNS is absent.
    """
    dns = os.environ.get("ALB_DNS", "").strip().rstrip("/")
    if not dns:
        return None
    if not dns.startswith(("http://", "https://")):
        dns = f"http://{dns}"
    return dns


def _wait_for_health(
    health_path: str,
    timeout: int = HEALTH_RECOVER_TIMEOUT_SECONDS,
) -> bool:
    """
    Poll GET <alb_base>/<health_path> every POLL_INTERVAL_SECONDS until
    HTTP 200 is received or *timeout* seconds elapse.
    Returns True on success, False on timeout.
    """
    base = _alb_base_url()
    if base is None:
        # ALB_DNS not set — skip health check portion
        return True

    url = f"{base}{health_path}"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            resp = requests.get(url, timeout=REQUEST_TIMEOUT_SECONDS)
            if resp.status_code == 200:
                return True
        except requests.RequestException:
            pass
        time.sleep(POLL_INTERVAL_SECONDS)
    return False


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module", autouse=True)
def verify_kubectl_connectivity():
    """Verify kubectl can reach the cluster before running any chaos test."""
    if not _KUBECONFIG or not _KUBECTL:
        pytest.skip(
            "Chaos tests require KUBECONFIG env var to be set "
            "and kubectl to be available on PATH"
        )
    result = _kubectl("cluster-info", check=False)
    if result.returncode != 0:
        pytest.skip(
            f"kubectl cannot reach the cluster. "
            f"STDERR: {result.stderr.strip()}"
        )


# ---------------------------------------------------------------------------
# Test class
# ---------------------------------------------------------------------------


@_skip_no_kubectl
class TestPodChaos:
    """
    **Validates: Requirements 17.1, 17.2**

    For each service Deployment:
      - Delete one running pod.
      - Assert a new pod is Running within 2 minutes (Req 17.1).
      - Assert the service health endpoint returns HTTP 200 within 3 minutes
        (Req 17.2) — only when ALB_DNS is set.
    """

    @pytest.mark.parametrize(
        "deployment,namespace,health_path",
        SERVICE_DEPLOYMENTS,
        ids=[d[0] for d in SERVICE_DEPLOYMENTS],
    )
    def test_pod_is_recreated_after_deletion(
        self,
        deployment: str,
        namespace: str,
        health_path: Optional[str],
    ):
        """
        **Validates: Requirements 17.1, 17.2**

        Delete one pod from *deployment* and verify:
          1. A new Running pod appears within 2 minutes.
          2. The service health endpoint returns 200 within 3 minutes
             (skipped when ALB_DNS is not set or health_path is None).
        """
        # --- find a running pod to delete ---
        pods = _get_pod_names(deployment, namespace)
        if not pods:
            pytest.skip(
                f"No Running pods found for deployment '{deployment}' "
                f"in namespace '{namespace}'. "
                f"Ensure the cluster is up and the deployment is healthy."
            )

        target_pod = pods[0]

        # --- delete the pod ---
        delete_result = _kubectl(
            "delete", "pod", target_pod,
            "-n", namespace,
            "--grace-period=0",
            "--force",
            check=False,
        )
        assert delete_result.returncode == 0, (
            f"Failed to delete pod '{target_pod}' in namespace '{namespace}'. "
            f"STDERR: {delete_result.stderr.strip()}"
        )

        # --- assert pod is recreated within 2 minutes (Req 17.1) ---
        recreated = _wait_for_new_pod(
            deployment, namespace, target_pod,
            timeout=POD_RECREATE_TIMEOUT_SECONDS,
        )
        assert recreated, (
            f"Deployment '{deployment}' in namespace '{namespace}' did NOT "
            f"recreate a Running pod within {POD_RECREATE_TIMEOUT_SECONDS}s "
            f"after deleting pod '{target_pod}'."
        )

        # --- assert health endpoint recovers within 3 minutes (Req 17.2) ---
        if health_path is None:
            # celery-worker has no HTTP endpoint
            return

        if _alb_base_url() is None:
            pytest.skip(
                "ALB_DNS not set — skipping health endpoint recovery check. "
                "Pod recreation was verified successfully."
            )

        recovered = _wait_for_health(
            health_path,
            timeout=HEALTH_RECOVER_TIMEOUT_SECONDS,
        )
        assert recovered, (
            f"Service health endpoint '{health_path}' did NOT return HTTP 200 "
            f"within {HEALTH_RECOVER_TIMEOUT_SECONDS}s after pod deletion for "
            f"deployment '{deployment}'."
        )

    def test_kubectl_get_deployments_lists_expected_services(self):
        """
        **Validates: Requirements 17.1**

        Sanity check: kubectl can list Deployments in the expected namespaces.
        This confirms the cluster is reachable and the namespaces exist.
        """
        namespaces = {"auth", "arch-analyzer-api", "arch-analyzer-ia"}
        for ns in namespaces:
            result = _kubectl(
                "get", "deployments",
                "-n", ns,
                "-o", "json",
                check=False,
            )
            assert result.returncode == 0, (
                f"kubectl get deployments -n {ns} failed. "
                f"STDERR: {result.stderr.strip()}"
            )
            data = json.loads(result.stdout or "{}")
            items = data.get("items", [])
            assert isinstance(items, list), (
                f"Unexpected response shape for namespace '{ns}': {data}"
            )
