#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: test_magma_gene_analysis.sh

Builds the official MAGMA image, publishes the 1000G EUR LD-reference
catalog package, and smoke-tests magma_gene_analysis end to end.

Environment:
  VFS_CONFIG                 Catalog VFS config (default: ~/.autonomics/vfs.toml)
  MAGMA_IMAGE                OCI tag (default: localhost/atc/magma:1.10)
  MAGMA_SOURCE_ROOT          Official MAGMA deployment root
                             (default: /mnt/data/magma)
  AUTONOMICS_MAGMA_IT_PVAL   Smoke p-value file, SNP and P columns
                             (default: $MAGMA_SOURCE_ROOT/data/smoke_test.pval)
  AUTONOMICS_MAGMA_IT_ANNOT  Smoke .genes.annot
                             (default: $MAGMA_SOURCE_ROOT/results/smoke_test.annotation.genes.annot)
  BUILD_IMAGE=0              Skip podman build
  PUBLISH_PANEL=0            Skip package build/publish
EOF
}

# Plugin directory: the Dockerfile lives next to this script.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config=${VFS_CONFIG:-"$HOME/.autonomics/vfs.toml"}
image=${MAGMA_IMAGE:-localhost/atc/magma:1.10}
source_root=${MAGMA_SOURCE_ROOT:-/mnt/data/magma}
pval=${AUTONOMICS_MAGMA_IT_PVAL:-$source_root/data/smoke_test.pval}
annot=${AUTONOMICS_MAGMA_IT_ANNOT:-$source_root/results/smoke_test.annotation.genes.annot}
build_image=${BUILD_IMAGE:-1}
publish_panel=${PUBLISH_PANEL:-1}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need cargo
need podman

[[ -f "$config" ]] || {
  echo "VFS config does not exist: $config" >&2
  exit 1
}
[[ -f "$pval" ]] || {
  echo "MAGMA p-value input does not exist: $pval" >&2
  exit 1
}
[[ -f "$annot" ]] || {
  echo "MAGMA .genes.annot input does not exist: $annot" >&2
  exit 1
}

export AUTONOMICS_PANEL_CACHE_ROOT=${AUTONOMICS_PANEL_CACHE_ROOT:-$HOME/.autonomics/panels}
export AUTONOMICS_TEST_VFS_CONFIG=$config

catalog() {
  cargo run -q -p data-catalog --bin autonomics-catalog -- "$@"
}

if [[ "$publish_panel" == 1 ]]; then
  work=$(mktemp -d)
  cleanup_paths=("$work")
  cleanup() {
    if [[ ${#cleanup_paths[@]} -gt 0 ]]; then
      rm -rf "${cleanup_paths[@]}"
    fi
  }
  trap cleanup EXIT
  # Whole-genome bfile plus the .synonyms file MAGMA auto-detects next
  # to the prefix; the legacy DAG bundle.json and precomputed annotations
  # stay out of the catalog package.
  mkdir -p "$work/g1000-eur"
  for ext in bed bim fam synonyms; do
    cp "$source_root/resources/references/g1000_eur/g1000_eur.$ext" "$work/g1000-eur/"
  done

  catalog build "$work/g1000-eur" "$work/package" \
    --repo wjixiang/catalog-magma-ref-g1000-eur --version v1 --kind magma_ld_ref \
    --metadata population=EUR --metadata genome_build=GRCh37 \
    --metadata reference=1000G_Phase3 \
    --metadata description="Official MAGMA v1.10 1000 Genomes Phase 3 EUR LD reference (whole-genome PLINK bfile with .synonyms)"
  catalog validate "$work/package"
  catalog publish "$work/package" --config "$config"
  catalog install wjixiang/catalog-magma-ref-g1000-eur
else
  cleanup_paths=()
  cleanup() {
    if [[ ${#cleanup_paths[@]} -gt 0 ]]; then
      rm -rf "${cleanup_paths[@]}"
    fi
  }
  trap cleanup EXIT
fi

# Presence check against the local panel cache — what the loader mounts
# from. (The remote search subcommand trips over an unrelated malformed
# package index in the current catalog generation.)
current=$(catalog list --cache "$AUTONOMICS_PANEL_CACHE_ROOT")
grep -q '"repo": "wjixiang/catalog-magma-ref-g1000-eur"' <<<"$current" || {
  echo "local panel cache is missing wjixiang/catalog-magma-ref-g1000-eur (publish it with PUBLISH_PANEL=1)" >&2
  exit 1
}

if [[ "$build_image" == 1 ]]; then
  podman build -f "$root/Dockerfile" \
    -t "$image" "$source_root"
fi
podman run --rm "$image" --version >/dev/null

# End-to-end smoke: the historical annotate smoke inputs against the EUR
# reference, exactly the command scripts/gene_analysis.sh renders (here
# with the fixed-N fallback because the smoke pval file has no N column).
work=$(mktemp -d)
cleanup_paths+=("$work")
cp "$pval" "$work/smoke.pval"
cp "$annot" "$work/smoke.genes.annot"

podman run --rm \
  -v "$source_root/resources/references/g1000_eur:/panels/magma_ref:ro" \
  -v "$work:/work" -w /work \
  "$image" \
  --bfile /panels/magma_ref/g1000_eur \
  --pval /work/smoke.pval N=503 \
  --gene-annot /work/smoke.genes.annot \
  --gene-model snp-wise=mean \
  --out /work/smoke_gene

[[ -s "$work/smoke_gene.genes.out" ]] || {
  echo "smoke gene analysis produced no .genes.out; log:" >&2
  cat "$work/smoke_gene.log" >&2
  exit 1
}
[[ -s "$work/smoke_gene.genes.raw" ]] || {
  echo "smoke gene analysis produced no .genes.raw (required by magma_gene_set)" >&2
  exit 1
}
awk 'NR > 1 { n++ } END { exit !(n >= 1) }' "$work/smoke_gene.genes.out" || {
  echo "smoke gene analysis produced no result rows" >&2
  exit 1
}
head -n 3 "$work/smoke_gene.genes.out"

echo "MAGMA gene analysis test completed successfully."
