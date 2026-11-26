# Nscale notes for this fork

This directory holds documentation that is specific to the Nscale fork of
`tacplus-ng/event-driven-servers`. Everything else under `doc/` is upstream
documentation and is generated from the manuals; do not edit it here.

The repository is public. Keep host names, addresses, account names and
anything from the deployment inventory out of these files.

## Contents

| File | What it is |
|------|------------|
| [performance.md](performance.md) | Investigation and plan for the memory exhaustion tracked in NETDEV-2 |

## Architecture decision records

Put each ADR in `adr/NNNN-short-title.md`, numbered in order, with these
sections: Status, Context, Decision, Consequences. An ADR records one decision.
Supersede an old ADR with a new one instead of rewriting it.

The plan in [performance.md](performance.md) lists the decisions that need an
ADR.
