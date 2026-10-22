set -eu

# Model whitelist: v0 params have no enum type, so the script rejects
# values the doc does not bless (lava analysis-param precedent). With
# --pval, "multi" is the official aggregate of the snp-wise mean and top
# models; the principal-components regression model needs raw genotype
# data and cannot run on summary statistics.
case "${MAGMA_GENE_MODEL}" in
  multi | snp-wise=mean | snp-wise=top) model="$MAGMA_GENE_MODEL" ;;
  *)
    echo "model must be one of multi, snp-wise=mean, snp-wise=top (got '$MAGMA_GENE_MODEL')" >&2
    exit 1
    ;;
esac

# Cross-field guard the v0 param DSL cannot express: top_n only decorates
# the top model, as snp-wise=top,K (K SNPs) per the v1.10 manual.
if [ -n "$MAGMA_TOP_N" ]; then
  case "$model" in
    snp-wise=top) model="snp-wise=top,$MAGMA_TOP_N" ;;
    *) echo "top_n requires model=snp-wise=top (got '$MAGMA_GENE_MODEL')" >&2; exit 1 ;;
  esac
fi

sumstats="$AUTONOMICS_INPUT0"

# Single optional gzip input: decompressed into the private workspace so
# the official reader sees a plain SNP/P table (ldsc munge precedent).
case "$sumstats" in
  *.gz)
    # The runner stages scripts under .autonomics/ but do not lean on
    # that; make sure the staging subdir exists before writing into it.
    mkdir -p "$AUTONOMICS_WORKDIR/.autonomics"
    sumstats="$AUTONOMICS_WORKDIR/.autonomics/input-0.tsv"
    gzip -dc -- "$AUTONOMICS_INPUT0" > "$sumstats"
    ;;
esac

# Sample size: MAGMA requires N=<n> or ncol=<name> on --pval. A per-SNP N
# column in the sumstats wins; the fixed sample_size param is the fallback
# for N-less sumstats. Header fields may be tab- or space-separated.
n_count=$(head -n 1 "$sumstats" | tr ' \t' '\n\n' | grep -cx N || true)
if [ "$n_count" -ge 1 ]; then
  nmode="ncol=N"
  nnote="per-SNP N column detected, using ncol=N (sample_size param ignored)"
elif [ -n "$MAGMA_SAMPLE_SIZE" ]; then
  nmode="N=$MAGMA_SAMPLE_SIZE"
  nnote="no N column, using fixed sample size N=$MAGMA_SAMPLE_SIZE"
else
  echo "sumstats has no N column and sample_size is unset: provide one of the two" >&2
  exit 1
fi

# The official MAGMA-distributed 1000G EUR reference (with its .synonyms
# file auto-detected next to the bfile prefix for rsID remapping) is a
# family panel; this node is its only reader.
{
  echo "magma_gene_analysis: model=$model, $nnote"
  magma \
    --bfile /panels/magma_ref/g1000_eur \
    --pval "$sumstats" "$nmode" \
    --gene-annot "$AUTONOMICS_INPUT1" \
    --gene-model "$model" \
    --out "$AUTONOMICS_WORKDIR/magma_gene_analysis"
} > "$AUTONOMICS_OUTPUT2" 2>&1

test -s "$AUTONOMICS_OUTPUT0"
test -s "$AUTONOMICS_OUTPUT1"
