#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: test_magma_gene_set.sh

Self-contained GSA smoke test: samples SNPs from the 1000G EUR reference
BIM with deterministic p-values, runs the full in-container chain
(annotate -> gene analysis -> gene-set analysis), and checks the
competitive results. No catalog publish; the reference directory is
mounted directly.

Environment:
  MAGMA_IMAGE                OCI tag (default: localhost/atc/magma:1.10)
  MAGMA_SOURCE_ROOT          Official MAGMA deployment root
                             (default: /mnt/data/magma)
  BUILD_IMAGE=0              Skip podman build
EOF
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
image=${MAGMA_IMAGE:-localhost/atc/magma:1.10}
source_root=${MAGMA_SOURCE_ROOT:-/mnt/data/magma}
build_image=${BUILD_IMAGE:-1}
ref_dir=$source_root/resources/references/g1000_eur

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

need podman

[[ -f "$ref_dir/g1000_eur.bim" ]] || {
  echo "1000G EUR reference is missing: $ref_dir/g1000_eur.bim" >&2
  exit 1
}
[[ -f "$source_root/resources/genes/NCBI37.3.gene.loc" ]] || {
  echo "NCBI37.3 gene location table is missing" >&2
  exit 1
}

if [[ "$build_image" == 1 ]]; then
  podman build -f "$root/Dockerfile" \
    -t "$image" "$source_root"
fi
podman run --rm "$image" --version >/dev/null

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# Every 4000th of the 22.3M reference SNPs (~5.5k spread genome-wide) with
# a deterministic p-value cycle, so the gene analysis yields thousands of
# genes with varied Z-statistics for the competitive regression.
printf 'SNP\tP\n' > "$work/pval.tsv"
: > "$work/snp.loc"
awk -v OFS='\t' -v snp_loc="$work/snp.loc" '
  NR % 4000 == 1 {
    print $2, $1, $4 > snp_loc
    print $2, (n % 50 + 1) / 100
    n++
  }
' "$ref_dir/g1000_eur.bim" >> "$work/pval.tsv"
[[ -s "$work/snp.loc" ]] || {
  echo "SNP sampling produced an empty snp.loc" >&2
  exit 1
}

# Two 100-gene sets from the first 200 annotated genes (Entrez IDs).
run() {
  podman run --rm \
    -v "$ref_dir:/panels/magma_ref:ro" \
    -v "$source_root/resources/genes:/panels/gene_loc:ro" \
    -v "$work:/work" -w /work \
    "$image" "$@"
}

run --annotate \
  --snp-loc /work/snp.loc \
  --gene-loc /panels/gene_loc/NCBI37.3.gene.loc \
  --out /work/synth >/dev/null
[[ -s "$work/synth.genes.annot" ]] || {
  echo "synthetic annotation produced no .genes.annot" >&2
  exit 1
}

run --bfile /panels/magma_ref/g1000_eur \
  --pval /work/pval.tsv N=1000 \
  --gene-annot /work/synth.genes.annot \
  --gene-model snp-wise=mean \
  --out /work/synth_gene >/dev/null
awk 'NR > 1 { n++ } END { exit !(n >= 50) }' "$work/synth_gene.genes.out" || {
  echo "synthetic gene analysis produced fewer than 50 gene rows; log:" >&2
  cat "$work/synth_gene.log" >&2
  exit 1
}

awk 'BEGIN { OFS = "\t" }
  $1 !~ /^#/ { c++; if (c <= 100) a = a " " $1; else if (c <= 200) b = b " " $1 }
  END { print "SMOKE_SET_A" a; print "SMOKE_SET_B" b }
' "$work/synth.genes.annot" > "$work/sets.txt"

run --gene-results /work/synth_gene.genes.raw \
  --set-annot /work/sets.txt \
  --out /work/synth_gsa >/dev/null
grep -q '^SMOKE_SET_A' "$work/synth_gsa.gsa.out" || {
  echo "gsa.out is missing the SMOKE_SET_A result row; log:" >&2
  cat "$work/synth_gsa.log" >&2
  exit 1
}
grep -q '^SMOKE_SET_B' "$work/synth_gsa.gsa.out" || {
  echo "gsa.out is missing the SMOKE_SET_B result row" >&2
  exit 1
}
echo "genes analyzed: $(($(wc -l < "$work/synth_gene.genes.out") - 1))"
grep '^SMOKE_SET' "$work/synth_gsa.gsa.out"

# Batch regression: the node's batches>1 path (official --batch + --merge)
# must produce the same gene count as a single run, and its merged
# .genes.raw must remain consumable by --gene-results.
cp "$root/scripts/gene_analysis.sh" "$work/gene_analysis.sh"

node_gene_analysis() { # node_gene_analysis <batches>
  podman run --rm \
    -v "$ref_dir:/panels/magma_ref:ro" \
    -v "$work:/work" -w /work \
    --entrypoint sh "$image" -c '
      : > /work/ga.log; : > /work/ga.genes.out; : > /work/ga.genes.raw
      AUTONOMICS_INPUT0=/work/pval.tsv \
      AUTONOMICS_INPUT1=/work/synth.genes.annot \
      AUTONOMICS_WORKDIR=/work \
      AUTONOMICS_OUTPUT0=/work/ga.genes.out \
      AUTONOMICS_OUTPUT1=/work/ga.genes.raw \
      AUTONOMICS_OUTPUT2=/work/ga.log \
      MAGMA_GENE_MODEL=snp-wise=mean MAGMA_TOP_N= MAGMA_SAMPLE_SIZE=1000 \
      MAGMA_BATCHES="$1" sh /work/gene_analysis.sh
    ' _ "$1"
}

echo "checking batched gene analysis (batches=4)"
node_gene_analysis 4 || {
  echo "batched gene analysis failed; node log:" >&2
  cat "$work/ga.log" >&2
  exit 1
}
single_genes=$(($(wc -l < "$work/synth_gene.genes.out") - 1))
batch_genes=$(($(wc -l < "$work/ga.genes.out") - 1))
[ "$batch_genes" -eq "$single_genes" ] || {
  echo "batched run analysed $batch_genes genes, single run $single_genes" >&2
  exit 1
}
[ -s "$work/ga.genes.raw" ] || {
  echo "batched run produced no merged .genes.raw" >&2
  exit 1
}
echo "  batched genes match: $batch_genes"

run --gene-results /work/ga.genes.raw \
  --set-annot /work/sets.txt \
  --out /work/batched_gsa >/dev/null
grep -q '^SMOKE_SET_A' "$work/batched_gsa.gsa.out" || {
  echo "GSA on the merged .genes.raw produced no result row" >&2
  cat "$work/batched_gsa.log" >&2
  exit 1
}
echo "  merged .genes.raw feeds --gene-results"

echo "MAGMA gene set test completed successfully."
