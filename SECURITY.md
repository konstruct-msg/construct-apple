# Security Policy

Konstruct is a privacy-first, end-to-end-encrypted messenger. We take security and
cryptography issues seriously and welcome good-faith research.

> **Project maturity.** Konstruct is pre-1.0 and under active development (currently in
> TestFlight). The cryptographic core has **not yet undergone an external audit**. Treat the
> protocol and implementation as evolving. We are actively seeking review — see *Cryptography*
> below.

---

## Reporting a vulnerability

**Please do not open public issues, pull requests, or social-media posts for security
vulnerabilities.** Use private coordinated disclosure.

Report via **GitHub Private Vulnerability Reporting** ("Report a vulnerability") on the repo
closest to the issue:

| Area | Repository | Report here |
|------|-----------|-------------|
| Cryptographic core (X3DH, Double Ratchet, PQXDH, hybrid signatures, key management) | `konstruct-msg/construct-core` | `…/security/advisories/new` |
| Obfuscation / anti-censorship transport (VEIL) | `konstruct-msg/construct-veil` | `…/security/advisories/new` |
| iOS / macOS client | `naminohi/construct-ios` | `…/security/advisories/new` |

If you are unsure which repo applies — especially for anything touching the cryptographic
protocol — default to **`construct-core`**. Cross-cutting protocol issues are best filed there.

We do not currently operate a `security@` email address; GitHub's private advisory channel is the
authoritative intake. If you cannot use it, open a *minimal, non-sensitive* public issue asking us
to open a private advisory thread with you — **without** disclosing details.

### What to include
- A clear description of the issue and its security impact.
- Affected component / repo / version or commit.
- Reproduction steps or a proof-of-concept (a failing test, script, or trace is ideal).
- Your assessment of severity and any suggested remediation.
- Whether you intend to publish, and on what timeline.

PoC against your **own** accounts/keys/devices only. Do not test against other users.

---

## Scope

**In scope** (highest interest first):
- Breaks in the **end-to-end encryption** guarantee: message confidentiality/integrity,
  authentication, forward secrecy, post-compromise security.
- Flaws in **key exchange / ratchet / session** logic (X3DH, Double Ratchet, PQXDH, session
  healing, multi-device linking).
- **Post-quantum** primitives and the **hybrid signature** construction (downgrade, mismatched
  associated data, signature stripping).
- **Sealed-sender / metadata** leaks (who-talks-to-whom beyond the documented threat model).
- **VEIL** transport: distinguishers, ticket/capability forgery or replay, downgrade.
- Authentication / account-takeover, token handling, local secret storage (Keychain).
- Memory-safety or panics reachable from attacker-controlled input in the Rust cores.

**Out of scope** (unless chained into a concrete user-impacting exploit):
- Reports from automated scanners with no demonstrated impact.
- Missing security headers / best-practice nits on marketing sites.
- Self-inflicted issues requiring a jailbroken/rooted device or a malicious local app with
  elevated privileges.
- Social engineering of users or staff; physical attacks.
- Denial of service via volumetric flooding.
- Known limitations already documented in the threat model.

---

## Coordinated disclosure & timelines

We follow coordinated vulnerability disclosure. Targets (not guarantees — we are a small team):

| Stage | Target |
|-------|--------|
| Acknowledge receipt | within **72 hours** |
| Initial assessment / triage | within **7 days** |
| Fix or mitigation for high/critical | target **90 days** |

We will keep you updated, agree a disclosure date with you, and credit you (see below) unless you
prefer to remain anonymous. If an issue is being actively exploited, we may ship and disclose
faster. Please give us a reasonable window before public disclosure.

---

## Safe harbor

We consider security research conducted in good faith under this policy to be **authorized**. For
such research we will not pursue or support legal action, provided you:
- only interact with accounts, keys, and devices you own or are explicitly authorized to use;
- do not access, modify, or exfiltrate other users' data;
- avoid privacy violations, service degradation, and data destruction;
- give us a reasonable time to remediate before any public disclosure.

If in doubt about whether an action is authorized, ask first via a private advisory.

---

## Cryptography

For context, the primitives a reviewer would be looking at (see the protocol spec and `security/`
docs for detail):

- **Identity & signatures:** Ed25519, with a **hybrid** post-quantum signature
  (Ed25519 + **ML-DSA-65**) for downgrade-resistant authentication.
- **Key agreement:** X3DH, extended to **PQXDH** with **ML-KEM-768** for post-quantum
  confidentiality.
- **Messaging:** Double Ratchet (forward secrecy + post-compromise security), with session
  healing and multi-device support.
- **Metadata:** sealed-sender / stealth addressing to reduce who-talks-to-whom exposure.
- **Transport obfuscation (VEIL):** pluggable transports (obfs4 / WebTunnel / veil-front) with
  backend-signed, per-user capabilities for censorship circumvention.

The cryptographic core is implemented in Rust (`construct-core`) and exposed to clients via FFI;
the anti-censorship layer is `construct-veil`. **We are actively seeking protocol and code review**
(academic, NGO-funded, or commercial) and welcome both formal analysis and implementation audits.

---

## Recognition

With your consent, we credit reporters of valid issues in release notes and a future
`SECURITY-HALL-OF-FAME` once we have our first acknowledged report. We do not currently run a paid
bug-bounty program.
