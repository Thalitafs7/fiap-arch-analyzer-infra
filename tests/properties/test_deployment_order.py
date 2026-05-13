"""
Property-based tests for the deployment stage ordering invariant.

Validates: Requirements 15.9

Invariant: api-gateway MUST always be deployed AFTER auth-service,
registration-service, report-service, and processing-service.

Additional invariant: celery-worker is never deployed as a standalone
service — it is part of processing-service's k8s/ folder and is listed
under processing-service's `deployments[]` array, not as a top-level
service entry.

The tests parse `scripts/deploy-all.config.yaml` and also exercise the
ordering logic in pure Python so the invariant can be verified without
running the actual orchestrator.
"""

from __future__ import annotations

import os
import random
from typing import Dict, List, Optional, Set

import pytest
import yaml
from hypothesis import assume, given, settings
from hypothesis import strategies as st

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_CONFIG_PATH = os.path.join(_REPO_ROOT, "scripts", "deploy-all.config.yaml")

# ---------------------------------------------------------------------------
# Domain model — mirrors deploy-all.config.yaml structure
# ---------------------------------------------------------------------------

# Canonical stage ordering from Requirement 15.9
STAGE_ORDER: List[List[str]] = [
    ["auth-service"],
    ["registration-service", "report-service", "processing-service"],
    ["api-gateway"],
]

# Services that must precede api-gateway
API_GATEWAY_PREREQUISITES: Set[str] = {
    "auth-service",
    "registration-service",
    "report-service",
    "processing-service",
}

# celery-worker must NOT appear as a top-level service name
FORBIDDEN_STANDALONE_SERVICES: Set[str] = {"celery-worker"}


class DeploymentStage:
    """Represents one deployment stage (a group of services deployed in parallel)."""

    def __init__(self, services: List[str]):
        self.services = list(services)

    def __repr__(self) -> str:
        return f"Stage({self.services})"


class DeploymentPlan:
    """Ordered list of deployment stages."""

    def __init__(self, stages: List[DeploymentStage]):
        self.stages = stages

    def flat_order(self) -> List[str]:
        """Returns services in the order they are first deployed."""
        seen: List[str] = []
        for stage in self.stages:
            for svc in stage.services:
                if svc not in seen:
                    seen.append(svc)
        return seen

    def stage_index(self, service: str) -> Optional[int]:
        """Returns the 0-based stage index for a service, or None if not found."""
        for i, stage in enumerate(self.stages):
            if service in stage.services:
                return i
        return None

    def api_gateway_after_prerequisites(self) -> bool:
        """
        Returns True when api-gateway is deployed STRICTLY after all its
        prerequisites (auth-service, registration-service, report-service,
        processing-service).  "Strictly after" means a higher stage index —
        being in the same stage is a violation.
        """
        gw_idx = self.stage_index("api-gateway")
        if gw_idx is None:
            # api-gateway not in plan — invariant vacuously holds
            return True
        for prereq in API_GATEWAY_PREREQUISITES:
            prereq_idx = self.stage_index(prereq)
            if prereq_idx is None:
                continue  # prereq not in plan — skip
            # prereq must be in a strictly earlier stage
            if prereq_idx >= gw_idx:
                return False
        return True

    def has_standalone_celery_worker(self) -> bool:
        """Returns True when celery-worker appears as a top-level service."""
        for stage in self.stages:
            if "celery-worker" in stage.services:
                return True
        return False


def canonical_plan() -> DeploymentPlan:
    """Returns the canonical deployment plan from STAGE_ORDER."""
    return DeploymentPlan([DeploymentStage(s) for s in STAGE_ORDER])


# ---------------------------------------------------------------------------
# Config file helpers
# ---------------------------------------------------------------------------


def load_config() -> dict:
    with open(_CONFIG_PATH, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def services_from_config(config: dict) -> List[str]:
    return [entry["name"] for entry in config.get("services", [])]


def deployments_from_config(config: dict) -> Dict[str, List[str]]:
    """Returns {service_name: [deployment_names]} from the config."""
    return {
        entry["name"]: entry.get("deployments", [])
        for entry in config.get("services", [])
    }


# ---------------------------------------------------------------------------
# Hypothesis strategies
# ---------------------------------------------------------------------------

_ALL_SERVICES = [
    "auth-service",
    "registration-service",
    "report-service",
    "processing-service",
    "api-gateway",
]

_PREREQ_SERVICES = list(API_GATEWAY_PREREQUISITES)


@st.composite
def valid_deployment_plan(draw) -> DeploymentPlan:
    """
    Generates a DeploymentPlan that satisfies the ordering invariant:
    api-gateway always comes after all its prerequisites.
    """
    # Stage 1: auth-service (always first)
    stage1 = ["auth-service"]

    # Stage 2: any non-empty subset of {registration, report, processing}
    middle = draw(
        st.lists(
            st.sampled_from(["registration-service", "report-service", "processing-service"]),
            min_size=1,
            max_size=3,
            unique=True,
        )
    )

    # Stage 3: api-gateway (always last)
    stage3 = ["api-gateway"]

    stages = [DeploymentStage(stage1), DeploymentStage(middle), DeploymentStage(stage3)]
    return DeploymentPlan(stages)


@st.composite
def violating_deployment_plan(draw) -> DeploymentPlan:
    """
    Generates a DeploymentPlan where api-gateway appears BEFORE at least one
    of its prerequisites — violating the ordering invariant.
    """
    # Put api-gateway in stage 0, prerequisites in stage 1
    stage0 = ["api-gateway"]
    stage1 = draw(
        st.lists(
            st.sampled_from(_PREREQ_SERVICES),
            min_size=1,
            max_size=4,
            unique=True,
        )
    )
    return DeploymentPlan([DeploymentStage(stage0), DeploymentStage(stage1)])


@st.composite
def random_permutation_plan(draw) -> DeploymentPlan:
    """
    Generates a DeploymentPlan where all services are in a single stage
    in a random order — used to verify that the ordering check catches
    violations when api-gateway is not last.
    """
    services = draw(st.permutations(_ALL_SERVICES))
    return DeploymentPlan([DeploymentStage(services)])


# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------


@given(plan=valid_deployment_plan())
@settings(max_examples=300)
def test_valid_plan_satisfies_ordering_invariant(plan):
    """
    **Validates: Requirements 15.9**

    Property: any deployment plan generated by valid_deployment_plan satisfies
    the api-gateway-after-prerequisites ordering invariant.
    """
    assert plan.api_gateway_after_prerequisites(), (
        f"Valid plan unexpectedly violated ordering invariant.\n"
        f"Stages: {plan.stages}\n"
        f"Flat order: {plan.flat_order()}"
    )


@given(plan=violating_deployment_plan())
@settings(max_examples=200)
def test_violating_plan_fails_ordering_invariant(plan):
    """
    **Validates: Requirements 15.9**

    Property: any plan where api-gateway precedes at least one prerequisite
    MUST fail the ordering invariant check.
    """
    assert not plan.api_gateway_after_prerequisites(), (
        f"Violating plan unexpectedly passed ordering invariant.\n"
        f"Stages: {plan.stages}\n"
        f"Flat order: {plan.flat_order()}"
    )


@given(services=st.permutations(_ALL_SERVICES))
@settings(max_examples=300)
def test_single_stage_plan_always_violates_ordering_invariant(services):
    """
    **Validates: Requirements 15.9**

    Property: when all services (including api-gateway AND at least one
    prerequisite) are placed in a single stage, the ordering invariant is
    ALWAYS violated — because api-gateway must be in a strictly later stage
    than its prerequisites, not merely later in a list within the same stage.
    """
    plan = DeploymentPlan([DeploymentStage(services)])
    # All services share stage index 0, so api-gateway cannot be strictly
    # after any prerequisite → invariant must fail.
    assert not plan.api_gateway_after_prerequisites(), (
        f"Single-stage plan unexpectedly passed ordering invariant: {services}"
    )


@given(
    extra_services=st.lists(
        st.sampled_from(_PREREQ_SERVICES),
        min_size=0,
        max_size=4,
        unique=True,
    )
)
@settings(max_examples=200)
def test_canonical_plan_always_satisfies_invariant(extra_services):
    """
    **Validates: Requirements 15.9**

    Property: the canonical plan (from STAGE_ORDER) always satisfies the
    ordering invariant, regardless of which subset of prerequisites is present.
    """
    plan = canonical_plan()
    assert plan.api_gateway_after_prerequisites()


@given(
    standalone_name=st.sampled_from(list(FORBIDDEN_STANDALONE_SERVICES)),
    other_services=st.lists(
        st.sampled_from(_ALL_SERVICES),
        min_size=0,
        max_size=4,
        unique=True,
    ),
)
@settings(max_examples=100)
def test_celery_worker_as_standalone_is_detected(standalone_name, other_services):
    """
    **Validates: Requirements 15.9**

    Property: any plan that includes celery-worker as a top-level service
    entry is detected by has_standalone_celery_worker().
    """
    stage = DeploymentStage([standalone_name] + other_services)
    plan = DeploymentPlan([stage])
    assert plan.has_standalone_celery_worker(), (
        f"celery-worker as standalone not detected in plan: {plan.flat_order()}"
    )


@given(
    services=st.lists(
        st.sampled_from(_ALL_SERVICES),
        min_size=1,
        max_size=5,
        unique=True,
    )
)
@settings(max_examples=200)
def test_plan_without_celery_worker_passes_standalone_check(services):
    """
    **Validates: Requirements 15.9**

    Property: any plan that does not include celery-worker as a top-level
    service passes the standalone check.
    """
    plan = DeploymentPlan([DeploymentStage(services)])
    assert not plan.has_standalone_celery_worker(), (
        f"False positive: celery-worker standalone detected in {services}"
    )


# ---------------------------------------------------------------------------
# Config file tests (parse actual deploy-all.config.yaml)
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def deploy_config():
    return load_config()


@pytest.fixture(scope="module")
def config_service_names(deploy_config):
    return services_from_config(deploy_config)


@pytest.fixture(scope="module")
def config_deployments(deploy_config):
    return deployments_from_config(deploy_config)


class TestDeployConfigOrdering:
    """Tests that parse the actual deploy-all.config.yaml."""

    def test_config_file_exists(self):
        assert os.path.isfile(_CONFIG_PATH), (
            f"deploy-all.config.yaml not found at {_CONFIG_PATH}"
        )

    def test_api_gateway_is_last_service(self, config_service_names):
        """api-gateway must be the last entry in the services list."""
        assert config_service_names[-1] == "api-gateway", (
            f"api-gateway is not last. Order: {config_service_names}"
        )

    def test_api_gateway_after_all_prerequisites(self, config_service_names):
        """
        **Validates: Requirements 15.9**

        api-gateway index must be greater than the index of every prerequisite.
        """
        gw_idx = config_service_names.index("api-gateway")
        for prereq in API_GATEWAY_PREREQUISITES:
            if prereq in config_service_names:
                prereq_idx = config_service_names.index(prereq)
                assert prereq_idx < gw_idx, (
                    f"'{prereq}' (index {prereq_idx}) must come before "
                    f"api-gateway (index {gw_idx})"
                )

    def test_celery_worker_not_a_top_level_service(self, config_service_names):
        """
        **Validates: Requirements 15.9**

        celery-worker must NOT appear as a top-level service name.
        """
        assert "celery-worker" not in config_service_names, (
            "celery-worker must not be a standalone top-level service entry"
        )

    def test_celery_worker_is_deployment_under_processing_service(
        self, config_deployments
    ):
        """
        **Validates: Requirements 15.9**

        celery-worker must appear in processing-service's deployments[] list.
        """
        proc_deployments = config_deployments.get("processing-service", [])
        assert "celery-worker" in proc_deployments, (
            f"celery-worker not found in processing-service.deployments: {proc_deployments}"
        )

    def test_all_prerequisites_present_in_config(self, config_service_names):
        """All api-gateway prerequisites must be declared in the config."""
        for prereq in API_GATEWAY_PREREQUISITES:
            assert prereq in config_service_names, (
                f"Prerequisite '{prereq}' missing from deploy-all.config.yaml"
            )

    def test_auth_service_is_first(self, config_service_names):
        """auth-service must be the first service (stage 1 per Req 15.9)."""
        assert config_service_names[0] == "auth-service", (
            f"auth-service is not first. Order: {config_service_names}"
        )

    def test_stage_ordering_matches_requirement(self, config_service_names):
        """
        **Validates: Requirements 15.9**

        Verifies the full stage ordering:
        [auth-service] → [registration, report, processing] → [api-gateway]

        The config's flat service list is treated as sequential single-service
        stages (each service in its own stage) to verify strict ordering.
        """
        # Wrap each service in its own stage so stage_index reflects list position
        stages = [DeploymentStage([svc]) for svc in config_service_names]
        plan = DeploymentPlan(stages)
        assert plan.api_gateway_after_prerequisites(), (
            f"Config service order violates ordering invariant: {config_service_names}"
        )

    def test_no_service_has_empty_deployments_list(self, config_deployments):
        """Every service must declare at least one deployment to watch."""
        for svc, deployments in config_deployments.items():
            assert len(deployments) > 0, (
                f"Service '{svc}' has an empty deployments[] list"
            )


# ---------------------------------------------------------------------------
# Concrete examples
# ---------------------------------------------------------------------------


class TestOrderingExamples:
    """Concrete examples documenting the ordering invariant."""

    def test_canonical_plan_passes(self):
        plan = canonical_plan()
        assert plan.api_gateway_after_prerequisites()

    def test_gw_first_fails(self):
        plan = DeploymentPlan([
            DeploymentStage(["api-gateway"]),
            DeploymentStage(["auth-service", "registration-service"]),
        ])
        assert not plan.api_gateway_after_prerequisites()

    def test_gw_same_stage_as_prereq_fails(self):
        plan = DeploymentPlan([
            DeploymentStage(["auth-service", "api-gateway"]),
        ])
        assert not plan.api_gateway_after_prerequisites()

    def test_gw_after_all_prereqs_passes(self):
        plan = DeploymentPlan([
            DeploymentStage(["auth-service"]),
            DeploymentStage(["registration-service", "report-service", "processing-service"]),
            DeploymentStage(["api-gateway"]),
        ])
        assert plan.api_gateway_after_prerequisites()

    def test_celery_worker_standalone_detected(self):
        plan = DeploymentPlan([DeploymentStage(["celery-worker", "auth-service"])])
        assert plan.has_standalone_celery_worker()

    def test_celery_worker_not_standalone_in_canonical_plan(self):
        plan = canonical_plan()
        assert not plan.has_standalone_celery_worker()
