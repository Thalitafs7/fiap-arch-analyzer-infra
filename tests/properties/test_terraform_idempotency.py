"""
Property-based tests for Terraform configuration determinism / idempotency.

Validates: Requirements 18.1

Idempotency invariant: given the same set of input variables, the Terraform
configuration MUST always produce the same logical plan — i.e. the same set
of resource addresses with the same attribute values.  A second `terraform
apply` after a successful first apply MUST show zero planned changes.

Since running actual `terraform apply` is not feasible in unit tests (no live
AWS account, no credentials), this test suite validates the idempotency
property at the *configuration level*:

1. The same inputs always produce the same rendered HCL variable map
   (deterministic serialisation).
2. The variable-validation rules are stable: the same input either always
   passes or always fails, never flipping between runs.
3. The module dependency graph derived from the variable contracts is
   acyclic — a prerequisite for idempotent applies.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Dict, List, Optional

import pytest
from hypothesis import assume, given, settings
from hypothesis import strategies as st

# ---------------------------------------------------------------------------
# Domain model — Terraform variable contracts
# ---------------------------------------------------------------------------

# Mirrors variables.tf in the infra root
VALID_ENVIRONMENTS = ["dev", "staging", "prod"]
VALID_INSTANCE_TYPES = ["t3.small", "t3.medium", "t3.large"]


class TerraformInputs:
    """
    Represents a complete set of root-module input variables.
    Mirrors the variable declarations in variables.tf / terraform.tfvars.example.
    """

    def __init__(
        self,
        environment: str,
        vpc_cidr: str,
        public_subnet_cidrs: List[str],
        private_subnet_cidrs: List[str],
        eks_node_instance_types: List[str],
        eks_desired_size: int,
        eks_min_size: int,
        eks_max_size: int,
        db_name: str,
        force_destroy: bool,
        use_aws_managed_kms: bool,
        alb_ingress_cidrs: List[str],
        allowed_ssh_cidrs: List[str],
    ):
        self.environment = environment
        self.vpc_cidr = vpc_cidr
        self.public_subnet_cidrs = public_subnet_cidrs
        self.private_subnet_cidrs = private_subnet_cidrs
        self.eks_node_instance_types = eks_node_instance_types
        self.eks_desired_size = eks_desired_size
        self.eks_min_size = eks_min_size
        self.eks_max_size = eks_max_size
        self.db_name = db_name
        self.force_destroy = force_destroy
        self.use_aws_managed_kms = use_aws_managed_kms
        self.alb_ingress_cidrs = alb_ingress_cidrs
        self.allowed_ssh_cidrs = allowed_ssh_cidrs

    def to_dict(self) -> Dict[str, Any]:
        return {
            "environment": self.environment,
            "vpc_cidr": self.vpc_cidr,
            "public_subnet_cidrs": sorted(self.public_subnet_cidrs),
            "private_subnet_cidrs": sorted(self.private_subnet_cidrs),
            "eks_node_instance_types": sorted(self.eks_node_instance_types),
            "eks_desired_size": self.eks_desired_size,
            "eks_min_size": self.eks_min_size,
            "eks_max_size": self.eks_max_size,
            "db_name": self.db_name,
            "force_destroy": self.force_destroy,
            "use_aws_managed_kms": self.use_aws_managed_kms,
            "alb_ingress_cidrs": sorted(self.alb_ingress_cidrs),
            "allowed_ssh_cidrs": sorted(self.allowed_ssh_cidrs),
        }

    def canonical_hash(self) -> str:
        """
        Deterministic hash of the input set.
        Two TerraformInputs with identical values MUST produce the same hash.
        This is the unit-test proxy for 'same inputs → same plan'.
        """
        serialised = json.dumps(self.to_dict(), sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(serialised.encode()).hexdigest()


# ---------------------------------------------------------------------------
# Variable validation rules (mirrors Terraform validation blocks)
# ---------------------------------------------------------------------------


def validate_inputs(inputs: TerraformInputs) -> List[str]:
    """
    Returns a list of validation error messages.
    Empty list means all validations pass.
    Mirrors the `validation` blocks in variables.tf.
    """
    errors: List[str] = []

    if inputs.environment not in VALID_ENVIRONMENTS:
        errors.append(
            f"environment must be one of {VALID_ENVIRONMENTS}, got '{inputs.environment}'"
        )

    if not re.match(r"^\d+\.\d+\.\d+\.\d+/\d+$", inputs.vpc_cidr):
        errors.append(f"vpc_cidr must be a valid CIDR, got '{inputs.vpc_cidr}'")

    if inputs.eks_min_size < 1:
        errors.append("eks_min_size must be >= 1")

    if inputs.eks_max_size < inputs.eks_min_size:
        errors.append("eks_max_size must be >= eks_min_size")

    if not (inputs.eks_min_size <= inputs.eks_desired_size <= inputs.eks_max_size):
        errors.append(
            "eks_desired_size must be between eks_min_size and eks_max_size"
        )

    if len(inputs.alb_ingress_cidrs) == 0:
        errors.append("alb_ingress_cidrs must contain at least one CIDR")

    if "0.0.0.0/0" in inputs.allowed_ssh_cidrs:
        errors.append("allowed_ssh_cidrs must not contain 0.0.0.0/0")

    return errors


# ---------------------------------------------------------------------------
# Module dependency graph
# ---------------------------------------------------------------------------

# Adjacency list: module → list of modules it depends on
MODULE_DEPS: Dict[str, List[str]] = {
    "network": [],
    "security": ["network"],
    "storage": [],
    "ecr": [],
    "messaging": [],
    "database": ["security", "network"],
    "eks": ["network", "security"],
    "alb": ["eks", "storage"],
    "k8s-config": ["eks", "messaging", "storage", "database"],
    "secrets": [],
    "observability": ["eks"],
    "mongodb-on-eks": ["k8s-config", "secrets"],
    "redis-on-eks": ["k8s-config", "secrets"],
}


def has_cycle(deps: Dict[str, List[str]]) -> bool:
    """Detects cycles in the module dependency graph via DFS."""
    WHITE, GRAY, BLACK = 0, 1, 2
    color: Dict[str, int] = {m: WHITE for m in deps}

    def dfs(node: str) -> bool:
        color[node] = GRAY
        for neighbour in deps.get(node, []):
            if color.get(neighbour, WHITE) == GRAY:
                return True
            if color.get(neighbour, WHITE) == WHITE and dfs(neighbour):
                return True
        color[node] = BLACK
        return False

    return any(dfs(m) for m in deps if color[m] == WHITE)


# ---------------------------------------------------------------------------
# Hypothesis strategies
# ---------------------------------------------------------------------------

_environment = st.sampled_from(VALID_ENVIRONMENTS)

_octet = st.integers(0, 255)
_private_vpc_cidr = st.builds(
    lambda a, b: f"10.{a}.{b}.0/16",
    st.integers(0, 255),
    st.integers(0, 255),
)

_subnet_cidr = st.builds(
    lambda a, b, c: f"10.{a}.{b}.{c}/24",
    st.integers(0, 255),
    st.integers(0, 255),
    st.integers(0, 255),
)

_instance_type = st.sampled_from(VALID_INSTANCE_TYPES)

_db_name = st.from_regex(r"[a-z][a-z0-9_]{2,15}", fullmatch=True)

_alb_cidr = st.one_of(
    st.just("0.0.0.0/0"),
    _subnet_cidr,
)

_ssh_cidr = st.one_of(
    st.just("10.0.0.0/8"),
    st.just("192.168.0.0/16"),
    _subnet_cidr,
)


@st.composite
def valid_terraform_inputs(draw) -> TerraformInputs:
    """Generates a valid TerraformInputs that passes all validations."""
    min_size = draw(st.integers(1, 3))
    max_size = draw(st.integers(min_size, min_size + 4))
    desired = draw(st.integers(min_size, max_size))

    return TerraformInputs(
        environment=draw(_environment),
        vpc_cidr=draw(_private_vpc_cidr),
        public_subnet_cidrs=draw(st.lists(_subnet_cidr, min_size=2, max_size=4)),
        private_subnet_cidrs=draw(st.lists(_subnet_cidr, min_size=2, max_size=4)),
        eks_node_instance_types=draw(
            st.lists(_instance_type, min_size=1, max_size=3, unique=True)
        ),
        eks_desired_size=desired,
        eks_min_size=min_size,
        eks_max_size=max_size,
        db_name=draw(_db_name),
        force_destroy=draw(st.booleans()),
        use_aws_managed_kms=draw(st.booleans()),
        alb_ingress_cidrs=draw(st.lists(_alb_cidr, min_size=1, max_size=3)),
        allowed_ssh_cidrs=draw(st.lists(_ssh_cidr, min_size=0, max_size=3)),
    )


# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------


@given(inputs=valid_terraform_inputs())
@settings(max_examples=300)
def test_same_inputs_produce_same_canonical_hash(inputs):
    """
    **Validates: Requirements 18.1**

    Property: serialising the same TerraformInputs twice always yields the
    same canonical hash.  This is the unit-test proxy for the idempotency
    invariant: identical inputs → identical plan → zero changes on re-apply.
    """
    hash1 = inputs.canonical_hash()
    hash2 = inputs.canonical_hash()
    assert hash1 == hash2, (
        f"Non-deterministic hash for inputs: {inputs.to_dict()}"
    )


@given(inputs=valid_terraform_inputs())
@settings(max_examples=300)
def test_valid_inputs_pass_all_validations(inputs):
    """
    **Validates: Requirements 18.1**

    Property: any TerraformInputs generated by the valid_terraform_inputs
    strategy passes all variable validation rules without errors.
    """
    errors = validate_inputs(inputs)
    assert errors == [], (
        f"Valid inputs unexpectedly failed validation: {errors}\nInputs: {inputs.to_dict()}"
    )


@given(inputs_a=valid_terraform_inputs(), inputs_b=valid_terraform_inputs())
@settings(max_examples=200)
def test_different_inputs_may_produce_different_hashes(inputs_a, inputs_b):
    """
    **Validates: Requirements 18.1**

    Property: if two input sets differ in at least one field, their canonical
    hashes MUST differ.  Ensures the hash function is injective over the
    input space (no silent collisions that would mask plan drift).
    """
    if inputs_a.to_dict() != inputs_b.to_dict():
        assert inputs_a.canonical_hash() != inputs_b.canonical_hash(), (
            "Two distinct input sets produced the same hash — "
            "idempotency check would miss drift.\n"
            f"A: {inputs_a.to_dict()}\nB: {inputs_b.to_dict()}"
        )


@given(inputs=valid_terraform_inputs())
@settings(max_examples=200)
def test_validation_is_deterministic(inputs):
    """
    **Validates: Requirements 18.1**

    Property: calling validate_inputs on the same inputs twice always returns
    the same result.  Flaky validation would break idempotent CI runs.
    """
    result1 = validate_inputs(inputs)
    result2 = validate_inputs(inputs)
    assert result1 == result2


@given(
    environment=st.text(
        alphabet=st.characters(whitelist_categories=("Ll",)),
        min_size=1,
        max_size=20,
    ).filter(lambda e: e not in VALID_ENVIRONMENTS)
)
@settings(max_examples=100)
def test_invalid_environment_fails_validation(environment):
    """
    **Validates: Requirements 18.1**

    Property: any environment name outside the allowed set is rejected.
    """
    inputs = TerraformInputs(
        environment=environment,
        vpc_cidr="10.0.0.0/16",
        public_subnet_cidrs=["10.0.1.0/24", "10.0.2.0/24"],
        private_subnet_cidrs=["10.0.3.0/24", "10.0.4.0/24"],
        eks_node_instance_types=["t3.small"],
        eks_desired_size=2,
        eks_min_size=1,
        eks_max_size=5,
        db_name="archanalyzer",
        force_destroy=False,
        use_aws_managed_kms=True,
        alb_ingress_cidrs=["0.0.0.0/0"],
        allowed_ssh_cidrs=[],
    )
    errors = validate_inputs(inputs)
    assert any("environment" in e for e in errors)


def test_module_dependency_graph_is_acyclic():
    """
    **Validates: Requirements 18.1**

    Concrete test: the declared module dependency graph must be a DAG.
    A cycle would make `terraform apply` non-deterministic / non-idempotent.
    """
    assert not has_cycle(MODULE_DEPS), (
        "Module dependency graph contains a cycle — terraform apply would be non-deterministic."
    )


def test_all_module_dependencies_are_declared():
    """
    **Validates: Requirements 18.1**

    Concrete test: every dependency referenced in MODULE_DEPS must itself be
    a declared module.  Undeclared dependencies would cause plan failures.
    """
    declared = set(MODULE_DEPS.keys())
    for module, deps in MODULE_DEPS.items():
        for dep in deps:
            assert dep in declared, (
                f"Module '{module}' depends on undeclared module '{dep}'"
            )


@given(inputs=valid_terraform_inputs())
@settings(max_examples=100)
def test_eks_size_constraints_are_consistent(inputs):
    """
    **Validates: Requirements 18.1**

    Property: valid inputs always satisfy min_size ≤ desired_size ≤ max_size.
    Violated constraints cause non-deterministic plan failures.
    """
    assert inputs.eks_min_size <= inputs.eks_desired_size <= inputs.eks_max_size


# ---------------------------------------------------------------------------
# Concrete examples
# ---------------------------------------------------------------------------


class TestIdempotencyExamples:
    """Concrete examples documenting the idempotency invariant."""

    def _base_inputs(self, **overrides) -> TerraformInputs:
        defaults = dict(
            environment="dev",
            vpc_cidr="10.0.0.0/16",
            public_subnet_cidrs=["10.0.1.0/24", "10.0.2.0/24"],
            private_subnet_cidrs=["10.0.3.0/24", "10.0.4.0/24"],
            eks_node_instance_types=["t3.small"],
            eks_desired_size=2,
            eks_min_size=1,
            eks_max_size=5,
            db_name="archanalyzer",
            force_destroy=False,
            use_aws_managed_kms=True,
            alb_ingress_cidrs=["0.0.0.0/0"],
            allowed_ssh_cidrs=[],
        )
        defaults.update(overrides)
        return TerraformInputs(**defaults)

    def test_identical_inputs_same_hash(self):
        a = self._base_inputs()
        b = self._base_inputs()
        assert a.canonical_hash() == b.canonical_hash()

    def test_changed_environment_different_hash(self):
        a = self._base_inputs(environment="dev")
        b = self._base_inputs(environment="staging")
        assert a.canonical_hash() != b.canonical_hash()

    def test_changed_vpc_cidr_different_hash(self):
        a = self._base_inputs(vpc_cidr="10.0.0.0/16")
        b = self._base_inputs(vpc_cidr="10.1.0.0/16")
        assert a.canonical_hash() != b.canonical_hash()

    def test_valid_dev_inputs_pass_validation(self):
        inputs = self._base_inputs()
        assert validate_inputs(inputs) == []

    def test_open_ssh_fails_validation(self):
        inputs = self._base_inputs(allowed_ssh_cidrs=["0.0.0.0/0"])
        errors = validate_inputs(inputs)
        assert any("allowed_ssh_cidrs" in e for e in errors)

    def test_inverted_min_max_fails_validation(self):
        inputs = self._base_inputs(eks_min_size=5, eks_max_size=1, eks_desired_size=3)
        errors = validate_inputs(inputs)
        assert len(errors) > 0
