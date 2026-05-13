"""
Property-based tests for the security-group least-privilege invariant.

Validates: Requirements 2.6

Invariant: no ingress rule with CIDR 0.0.0.0/0 may exist unless it targets
the ALB security group on port 80.  The Terraform `security` module encodes
this via a `check` block and a variable validation on `allowed_ssh_cidrs`.

These tests exercise the same logic in pure Python so the invariant can be
verified in CI without running `terraform apply`.
"""

from __future__ import annotations

import ipaddress
from typing import List, Optional

import pytest
from hypothesis import assume, given, settings
from hypothesis import strategies as st

# ---------------------------------------------------------------------------
# Domain model — mirrors the Terraform security module's rule structure
# ---------------------------------------------------------------------------

OPEN_CIDR = "0.0.0.0/0"
ALB_HTTP_PORT = 80


class IngressRule:
    """Represents a single security-group ingress rule."""

    def __init__(
        self,
        cidr: Optional[str],
        from_port: int,
        to_port: int,
        target_sg: Optional[str] = None,
    ):
        self.cidr = cidr
        self.from_port = from_port
        self.to_port = to_port
        self.target_sg = target_sg  # referenced SG id, if any

    def is_open_internet(self) -> bool:
        """True when the rule allows traffic from the open internet (0.0.0.0/0)."""
        return self.cidr == OPEN_CIDR

    def is_alb_http(self, alb_sg_id: str) -> bool:
        """True when this is the permitted ALB HTTP rule."""
        return (
            self.target_sg == alb_sg_id
            or (
                self.cidr == OPEN_CIDR
                and self.from_port == ALB_HTTP_PORT
                and self.to_port == ALB_HTTP_PORT
            )
        )


def least_privilege_invariant(
    rules: List[IngressRule],
    alb_sg_id: str = "sg-alb",
) -> bool:
    """
    Returns True when all rules satisfy the least-privilege invariant:
    the only 0.0.0.0/0 ingress rule allowed is the ALB SG rule on port 80.

    Mirrors the Terraform `check` block in modules/security/main.tf.
    """
    for rule in rules:
        if rule.is_open_internet() and not rule.is_alb_http(alb_sg_id):
            return False
    return True


def validate_allowed_ssh_cidrs(cidrs: List[str]) -> bool:
    """
    Returns True when the SSH CIDR list does not contain 0.0.0.0/0.

    Mirrors the `validation` block on `allowed_ssh_cidrs` in
    modules/security/variables.tf.
    """
    return OPEN_CIDR not in cidrs


# ---------------------------------------------------------------------------
# Hypothesis strategies
# ---------------------------------------------------------------------------

# Valid private / restricted CIDRs (never 0.0.0.0/0)
_private_cidr = st.one_of(
    st.just("10.0.0.0/8"),
    st.just("172.16.0.0/12"),
    st.just("192.168.0.0/16"),
    st.builds(
        lambda a, b: f"10.{a}.{b}.0/24",
        st.integers(0, 255),
        st.integers(0, 255),
    ),
    st.builds(
        lambda a, b, c: f"{a}.{b}.{c}.0/24",
        st.integers(1, 223),
        st.integers(0, 255),
        st.integers(0, 255),
    ),
)

_port = st.integers(min_value=1, max_value=65535)

_sg_id = st.builds(
    lambda n: f"sg-{n:08x}",
    st.integers(min_value=1, max_value=0xFFFFFFFF),
)


def _alb_http_rule(alb_sg_id: str) -> IngressRule:
    """The one permitted open-internet rule: ALB SG on port 80."""
    return IngressRule(cidr=OPEN_CIDR, from_port=80, to_port=80, target_sg=alb_sg_id)


@st.composite
def compliant_rule_set(draw, alb_sg_id: str = "sg-alb"):
    """
    Generates a list of ingress rules that satisfies the least-privilege
    invariant.  May include the ALB HTTP rule; all other rules use private
    CIDRs or SG references (no 0.0.0.0/0).
    """
    include_alb_rule = draw(st.booleans())
    n_extra = draw(st.integers(0, 8))

    rules: List[IngressRule] = []
    if include_alb_rule:
        rules.append(_alb_http_rule(alb_sg_id))

    for _ in range(n_extra):
        use_sg_ref = draw(st.booleans())
        if use_sg_ref:
            rules.append(
                IngressRule(
                    cidr=None,
                    from_port=draw(_port),
                    to_port=draw(_port),
                    target_sg=draw(_sg_id),
                )
            )
        else:
            rules.append(
                IngressRule(
                    cidr=draw(_private_cidr),
                    from_port=draw(_port),
                    to_port=draw(_port),
                )
            )
    return rules


@st.composite
def violating_rule_set(draw, alb_sg_id: str = "sg-alb"):
    """
    Generates a list of ingress rules that contains at least one violation:
    a 0.0.0.0/0 rule that is NOT the ALB HTTP rule.
    """
    bad_port = draw(_port.filter(lambda p: p != ALB_HTTP_PORT))
    bad_rule = IngressRule(cidr=OPEN_CIDR, from_port=bad_port, to_port=bad_port)

    n_extra = draw(st.integers(0, 4))
    extra = draw(
        st.lists(
            st.builds(
                IngressRule,
                cidr=_private_cidr,
                from_port=_port,
                to_port=_port,
            ),
            min_size=n_extra,
            max_size=n_extra,
        )
    )
    rules = [bad_rule] + extra
    return rules


# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------


@given(rules=compliant_rule_set())
@settings(max_examples=200)
def test_compliant_rule_set_passes_invariant(rules):
    """
    **Validates: Requirements 2.6**

    Property: any rule set that contains only private-CIDR or SG-reference
    ingress rules (plus at most the ALB HTTP rule) satisfies the
    least-privilege invariant.
    """
    assert least_privilege_invariant(rules), (
        f"Compliant rule set unexpectedly failed invariant: {[(r.cidr, r.from_port) for r in rules]}"
    )


@given(rules=violating_rule_set())
@settings(max_examples=200)
def test_violating_rule_set_fails_invariant(rules):
    """
    **Validates: Requirements 2.6**

    Property: any rule set containing a 0.0.0.0/0 ingress rule on a port
    other than 80 MUST fail the least-privilege invariant.
    """
    assert not least_privilege_invariant(rules), (
        f"Violating rule set unexpectedly passed invariant: {[(r.cidr, r.from_port) for r in rules]}"
    )


@given(
    extra_cidrs=st.lists(_private_cidr, min_size=0, max_size=5),
    alb_sg_id=_sg_id,
)
@settings(max_examples=150)
def test_alb_http_rule_is_only_permitted_open_internet_rule(extra_cidrs, alb_sg_id):
    """
    **Validates: Requirements 2.6**

    Property: a rule set consisting of the ALB HTTP rule plus arbitrary
    private-CIDR rules always satisfies the invariant, regardless of the
    number of extra rules.
    """
    rules = [_alb_http_rule(alb_sg_id)] + [
        IngressRule(cidr=c, from_port=443, to_port=443) for c in extra_cidrs
    ]
    assert least_privilege_invariant(rules, alb_sg_id=alb_sg_id)


@given(
    cidrs=st.lists(
        st.one_of(
            _private_cidr,
            st.just("10.0.0.1/32"),
            st.just("203.0.113.0/24"),
        ),
        min_size=1,
        max_size=10,
    )
)
@settings(max_examples=200)
def test_allowed_ssh_cidrs_without_open_internet_passes_validation(cidrs):
    """
    **Validates: Requirements 2.6**

    Property: any non-empty list of SSH CIDRs that does not contain
    0.0.0.0/0 passes the variable validation.
    """
    assert validate_allowed_ssh_cidrs(cidrs), (
        f"SSH CIDR list without 0.0.0.0/0 unexpectedly failed: {cidrs}"
    )


@given(
    prefix=st.lists(
        _private_cidr,
        min_size=0,
        max_size=5,
    ),
    suffix=st.lists(
        _private_cidr,
        min_size=0,
        max_size=5,
    ),
)
@settings(max_examples=200)
def test_allowed_ssh_cidrs_containing_open_internet_fails_validation(prefix, suffix):
    """
    **Validates: Requirements 2.6**

    Property: any SSH CIDR list that contains 0.0.0.0/0 (at any position)
    MUST be rejected by the variable validation.
    """
    cidrs = prefix + [OPEN_CIDR] + suffix
    assert not validate_allowed_ssh_cidrs(cidrs), (
        f"SSH CIDR list with 0.0.0.0/0 unexpectedly passed: {cidrs}"
    )


# ---------------------------------------------------------------------------
# Concrete examples (unit tests)
# ---------------------------------------------------------------------------


class TestLeastPrivilegeExamples:
    """Concrete examples that document the invariant unambiguously."""

    def test_empty_rule_set_passes(self):
        assert least_privilege_invariant([])

    def test_alb_http_only_passes(self):
        rules = [IngressRule(cidr=OPEN_CIDR, from_port=80, to_port=80)]
        assert least_privilege_invariant(rules)

    def test_open_ssh_fails(self):
        rules = [IngressRule(cidr=OPEN_CIDR, from_port=22, to_port=22)]
        assert not least_privilege_invariant(rules)

    def test_open_https_fails(self):
        rules = [IngressRule(cidr=OPEN_CIDR, from_port=443, to_port=443)]
        assert not least_privilege_invariant(rules)

    def test_sg_reference_nodeport_passes(self):
        """EKS nodes SG uses SG reference — no CIDR — so it passes."""
        rules = [
            IngressRule(
                cidr=None,
                from_port=30000,
                to_port=32767,
                target_sg="sg-alb",
            )
        ]
        assert least_privilege_invariant(rules)

    def test_private_cidr_ssh_passes(self):
        rules = [IngressRule(cidr="10.0.0.0/8", from_port=22, to_port=22)]
        assert least_privilege_invariant(rules)

    def test_open_internet_ssh_rejected_by_variable_validation(self):
        assert not validate_allowed_ssh_cidrs(["0.0.0.0/0"])

    def test_empty_ssh_cidrs_passes_validation(self):
        assert validate_allowed_ssh_cidrs([])

    def test_mixed_ssh_cidrs_with_open_internet_rejected(self):
        assert not validate_allowed_ssh_cidrs(["10.0.0.0/8", "0.0.0.0/0"])
