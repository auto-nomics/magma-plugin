#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: test_magma_annotate.sh

Builds the official MAGMA image, validates the gene-location catalog package,
and smoke-tests the image.

Environment:
  VFS_CONFIG                 Catalog VFS config (default: ~/.autonomics/vfs.toml)
  MAGMA_IMAGE                OCI tag (default: localhost/atc/magma:1.10)
  MAGMA_SOURCE_ROOT          Official MAGMA deployment root
                             (default: /mnt/data/magma)
  AUTONOMICS_MAGMA_IT_SNP_LOC
                             Three-column SNP location smoke input
  BUILD_IMAGE=0              Skip podman build
  PUBLISH_PANEL=0            Skip package build/publish
EOF
}

# Plugin directory: the Dockerfile lives next to this script (moved from
# containers/magma/ during the plugin migration).
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config=${VFS_CONFIG:-"$HOME/.autonomics/vfs.toml"}
image=${MAGMA_IMAGE:-localhost/atc/magma:1.10}
source_root=${MAGMA_SOURCE_ROOT:-/mnt/data/magma}
snp_loc=${AUTONOMICS_MAGMA_IT_SNP_LOC:-$source_root/results/smoke_test.annotation.snp.loc}
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
[[ -x "$source_root/bin/magma" ]] || {
  echo "official MAGMA static binary is missing: $source_root/bin/magma" >&2
  exit 1
}
[[ -f "$snp_loc" ]] || {
  echo "MAGMA SNP-location input does not exist: $snp_loc" >&2
  exit 1
}

export AUTONOMICS_PANEL_CACHE_ROOT=${AUTONOMICS_PANEL_CACHE_ROOT:-$HOME/.autonomics/panels}
export AUTONOMICS_TEST_VFS_CONFIG=$config
export AUTONOMICS_MAGMA_IT_SNP_LOC=$snp_loc

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
  mkdir -p "$work/gene-location"
  cp "$source_root/resources/genes/NCBI37.3.gene.loc" "$work/gene-location/"

  catalog build "$work/gene-location" "$work/package" \
    --repo wjixiang/catalog-magma-gene-loc-ncbi37-3 --version v1 --kind magma_gene_loc \
    --metadata population=multi --metadata genome_build=GRCh37 \
    --metadata release=NCBI37.3 \
    --metadata description="Official MAGMA NCBI37.3 gene location table"
  catalog validate "$work/package"
  catalog publish "$work/package" --config "$config"
  catalog install wjixiang/catalog-magma-gene-loc-ncbi37-3
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
grep -q '"repo": "wjixiang/catalog-magma-gene-loc-ncbi37-3"' <<<"$current" || {
  echo "local panel cache is missing wjixiang/catalog-magma-gene-loc-ncbi37-3 (publish it with PUBLISH_PANEL=1)" >&2
  exit 1
}

if [[ "$build_image" == 1 ]]; then
  podman build -f "$root/Dockerfile" \
    -t "$image" "$source_root"
fi
podman run --rm "$image" --version >/dev/null

# Input-guard regressions: the pre-flight checks in scripts/annotate.sh must
# reject a summary-statistics table (A1 allele parsed as chromosome) and a
# GRCh38 coordinate file, both of which otherwise yield a near-empty
# annotation. Run inside the image so MAGMA is on PATH.
work=$(mktemp -d)
cleanup_paths+=("$work")

printf 'SNP\tA1\tA2\tFRQ\tBETA\tSE\tP\nrs140739101\tT\tG\t0.5\t0.1\t0.05\t0.5\nrs548369610\tA\tC\t0.4\t0.1\t0.05\t0.4\n' \
  > "$work/sumstats_like.tsv"
awk -v OFS='\t' 'NR <= 2000 && NR > 1 { print $2, $1, $4 + 287100000 }' \
  "$source_root/resources/references/g1000_eur/g1000_eur.bim" > "$work/grch38.loc"

# The gene-location panel is mounted read-only exactly as the node does in
# production; the script is copied in rather than baked into the image.
annotate() {
  podman run --rm \
    -v "$source_root/resources/genes:/panels/gene_loc:ro" \
    -v "$work:/w" -w /w \
    --entrypoint sh "$image" -c '
      cp /w/annotate.sh /tmp/annotate.sh
      : > /w/out.log; : > /w/out.annot
      AUTONOMICS_INPUT0="$1" AUTONOMICS_WORKDIR=/w \
      AUTONOMICS_OUTPUT0=/w/out.log AUTONOMICS_OUTPUT1=/w/out.annot \
      MAGMA_ANNOT_WINDOW_KB="${2:-10}" MAGMA_ANNOT_IGNORE_STRAND=false \
      sh /tmp/annotate.sh
    ' _ "$1" "${2:-10}"
}

cp "$root/scripts/annotate.sh" "$work/annotate.sh"

expect_rejected() {
  local label=$1 input=$2
  if annotate "$input" >/dev/null 2>&1; then
    echo "annotate guard regression: $label was accepted but must be rejected" >&2
    exit 1
  fi
  echo "  rejected as expected: $label"
}

# The gene panel is mounted read-only, matching production; no catalog
# install is needed for these guard checks.
echo "checking annotate input guards"
expect_rejected "GWAS/LDSC summary-statistics table" /w/sumstats_like.tsv
expect_rejected "GRCh38 coordinates" /w/grch38.loc

# Happy path: the historical smoke SNP-location input must still annotate,
# and window_kb must visibly widen the gene region (5kb widens it).
cp "$snp_loc" "$work/snp.loc"
: > "$work/out.log"; : > "$work/out.annot"
podman run --rm \
  -v "$source_root/resources/genes:/panels/gene_loc:ro" \
  -v "$work:/w" -w /w \
  --entrypoint sh "$image" -c '
    cp /w/annotate.sh /tmp/annotate.sh
    AUTONOMICS_INPUT0=/w/snp.loc AUTONOMICS_WORKDIR=/w \
    AUTONOMICS_OUTPUT0=/w/out.log AUTONOMICS_OUTPUT1=/w/out.annot \
    MAGMA_ANNOT_WINDOW_KB=5 MAGMA_ANNOT_IGNORE_STRAND=false \
    sh /tmp/annotate.sh
    test -s /w/out.annot
  '
grep -qv '^#' "$work/out.annot" || {
  echo "valid GRCh37 SNP-location input produced an empty annotation" >&2
  exit 1
}

echo "MAGMA official annotation test completed successfully."
