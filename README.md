# magma plugin

Migrated from the legacy `magma_annotate_container` wrapper in nodes-io.
One directory = one plugin family = one git-able unit.

## Layout

- `manifest.toml` — node kind `magma_annotate`: ports, panel, image
  provenance
- `scripts/annotate.sh` — the execution script, referenced relatively and
  inlined by the loader at startup
- `Dockerfile` — image build definition (moved verbatim from
  `containers/magma/`; build + push still go through GHCR)
- `test_magma_annotate.sh` — image + catalog-panel smoke test (moved from
  `containers/magma/`, `root=` repointed to this directory)

## Provenance

- Image: `ghcr.io/auto-nomics/autonomics/magma@sha256:2ca854…` — the
  official MAGMA v1.10 static executable (`ctg.cncr.nl/software/magma`)
  copied onto `debian:bookworm-slim`; no license label is published
  upstream, so none is asserted here.
- Panel: `wjixiang/catalog-magma-gene-loc-ncbi37-3` (official NCBI37.3
  gene-location table) mounted at `/panels/gene_loc`.

## Migration parity

The golden test (`container-plugin/tests/magma_migration.rs`) compares the
compiled `ContainerCommandSpec` against the legacy Rust wrapper's output:
image, panel bundle, outputs, resources, timeout are equal. The legacy
script was fully static — no optional flags, no gzip input handling — so
the plugin script is byte-identical to it (unlike the ldsc scripts, which
moved optional flags into env-driven `if` stanzas).

Two deliberate deltas:

- The kind drops the `_container` suffix (`magma_annotate_container` →
  `magma_annotate`), and `artifact_prefix` follows the kind
  (`/artifacts/magma_annotate`, was `/artifacts/magma_annotate_container`).
  This is also the DSL-derived default when `artifact_prefix` is omitted.
- The legacy spec exposed `artifact_prefix`/`timeout_secs` as per-instance
  overridable fields with defaults; the plugin DSL bakes them as fixed
  node-level manifest values (their validation rules — absolute path,
  non-zero timeout — are enforced at manifest load). The node therefore
  accepts only the empty spec `{}`.
