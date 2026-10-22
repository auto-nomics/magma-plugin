# magma plugin

Migrated from the legacy `magma_annotate_container` wrapper in nodes-io.
One directory = one plugin family = one git-able unit.

## Layout

- `manifest.toml` — node kinds `magma_annotate`, `magma_gene_analysis`,
  `magma_gene_set`: ports, panels, image provenance
- `scripts/annotate.sh` — SNP-to-gene annotation, referenced relatively
  and inlined by the loader at startup
- `scripts/gene_analysis.sh` — summary-statistics gene-level analysis
  against the 1000G EUR reference panel
- `scripts/gene_set.sh` — competitive gene-set analysis on the
  `.genes.raw` output
- `Dockerfile` — image build definition (moved verbatim from
  `containers/magma/`; build + push still go through GHCR); all three
  kinds share the one official-binary image
- `test_magma_annotate.sh` — image + catalog-panel smoke test (moved from
  `containers/magma/`, `root=` repointed to this directory)
- `test_magma_gene_analysis.sh` — publishes the 1000G EUR reference
  panel and smoke-tests the gene-analysis command end to end
- `test_magma_gene_set.sh` — self-contained annotate → gene → GSA chain
  on a deterministic genome-wide SNP sample

## Provenance

- Image: `ghcr.io/auto-nomics/autonomics/magma@sha256:2ca854…` — the
  official MAGMA v1.10 static executable (`ctg.cncr.nl/software/magma`)
  copied onto `debian:bookworm-slim`; no license label is published
  upstream, so none is asserted here.
- Panel: `wjixiang/catalog-magma-gene-loc-ncbi37-3` (official NCBI37.3
  gene-location table) mounted at `/panels/gene_loc`.
- Panel: `wjixiang/catalog-magma-ref-g1000-eur` (official MAGMA v1.10
  1000 Genomes Phase 3 EUR LD reference: whole-genome PLINK bfile plus
  the `.synonyms` file MAGMA auto-detects for rsID remapping) mounted at
  `/panels/magma_ref`. The mixer signed-LD panel was considered and
  rejected: its BIM uses `chr:pos:allele` IDs that never align with
  rsID-based sumstats.

## Nodes

The three layers of the MAGMA pipeline, one kind each:

1. `magma_annotate` — assigns SNPs to genes, emits `.genes.annot`.
2. `magma_gene_analysis` — `magma --bfile <g1000_eur> --pval <sumstats>
   N=<n>|ncol=N --gene-annot <annot> --gene-model <model>`; emits the
   official `.genes.out` table plus the `.genes.raw` intermediate.
3. `magma_gene_set` — `magma --gene-results <raw> --set-annot <sets>`;
   emits the official competitive `.gsa.out` table.

Design notes verified against the v1.10 manual (deviations from the
original node-suite design doc):

- With p-value input the official default model is `snp-wise=mean`;
   `multi` is the aggregate of the snp-wise mean and top models — the
   principal-components regression (`linreg`) model needs raw genotype
   data, so there is no `n_pc` parameter to expose. `model` defaults to
   `multi` as the design doc planned, for its broader-architecture
   sensitivity.
- `max_perc`, `min_snps`, GSA permutations and a minimum-set-size filter
  have no v1.10 flags; none is emulated. GSA is analytical, and `NGENES`
  is reported per set for downstream filtering.
- GSA reads `.genes.raw`, not `.genes.out` — the gene-analysis node
  emits it as port 1 for exactly this hand-off.
- Gene IDs are NCBI37.3 Entrez numeric IDs throughout. Gene-set files
  pass through untouched: MAGMA discards GMT description columns itself,
  but symbol-named sets (plain MSigDB GMTs) never match — use the
  Entrez editions.

An earlier attempt to grow these nodes through the greenfield dev-plugin
lifecycle (`~/.autonomics/plugins/dev/magma`, kind `magma_gene`) is
policy-blocked ("panels are not allowed in the greenfield MVP") and took
a per-chromosome, custom-output-schema route; its empirically verified
flag spellings and the 8Gi multi-model OOM observation (memory here is
16Gi) informed this implementation.

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
