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
#
# MAGMA v1.10 is single-threaded and has no thread flag, so batches>1 is
# the only way to use more than one core: the official --batch mode splits
# the genes across N processes, which the script launches concurrently and
# then merges with --merge. The manual caps batches at roughly 25-30
# (the limit comes from gene-gene correlation distances) unless
# --genes-only is used, which is not an option here because gene-set
# analysis needs those correlations. The cap is enforced by MAGMA itself
# (it silently reduces an over-large request); the node ceiling of 8 keeps
# N parallel reference loads inside the memory budget.
batches=${MAGMA_BATCHES:-1}
case "$batches" in
  '' | *[!0-9]*)
    echo "batches must be a positive integer (got '$batches')" >&2
    exit 1
    ;;
esac
[ "$batches" -ge 1 ] || {
  echo "batches must be at least 1 (got '$batches')" >&2
  exit 1
}

prefix="$AUTONOMICS_WORKDIR/magma_gene_analysis"

{
  echo "magma_gene_analysis: model=$model, $nnote"
  if [ "$batches" -gt 1 ]; then
    echo "batches=$batches (concurrent MAGMA --batch runs, merged afterwards)"
  fi
} > "$AUTONOMICS_OUTPUT2" 2>&1

if [ "$batches" -eq 1 ]; then
  magma \
    --bfile /panels/magma_ref/g1000_eur \
    --pval "$sumstats" "$nmode" \
    --gene-annot "$AUTONOMICS_INPUT1" \
    --gene-model "$model" \
    --out "$prefix" >> "$AUTONOMICS_OUTPUT2" 2>&1
else
  # Every batch MUST get the identical command and --out prefix: MAGMA keys
  # the per-batch files off that prefix (.batchP_N.genes.out) and --merge
  # refuses to run when any batch file is missing.
  pids=""
  b=1
  while [ "$b" -le "$batches" ]; do
    magma \
      --bfile /panels/magma_ref/g1000_eur \
      --pval "$sumstats" "$nmode" \
      --gene-annot "$AUTONOMICS_INPUT1" \
      --gene-model "$model" \
      --batch "$b" "$batches" \
      --out "$prefix" >> "$AUTONOMICS_OUTPUT2" 2>&1 &
    pids="$pids $b=$!"
    b=$((b + 1))
  done
  failed=""
  for entry in $pids; do
    wait "${entry#*=}" || failed="$failed ${entry%%=*}"
  done
  if [ -n "$failed" ]; then
    echo "batches=$batches: MAGMA batch run(s) failed for batch:$failed." >&2
    echo "  Two causes are common: a batch index beyond the v1.10 maximum of" >&2
    echo "  roughly 25-30 (MAGMA writes only a log for those), or too few genes" >&2
    echo "  to split across $batches batches. See the log for the MAGMA message." >&2
    exit 1
  fi
  # A batch that produced no .genes.out (MAGMA writes only a log when the
  # batch index exceeds the maximum it allows) would make --merge fail with
  # a confusing count mismatch; name the missing one here instead.
  b=1
  while [ "$b" -le "$batches" ]; do
    if [ ! -s "$prefix.batch${b}_${batches}.genes.out" ]; then
      echo "batches=$batches: batch $b produced no .genes.out. The v1.10 manual caps" >&2
      echo "batch mode at roughly 25-30 batches (gene-gene correlation distances);" >&2
      echo "reduce batches or check the log for that batch." >&2
      exit 1
    fi
    b=$((b + 1))
  done
  magma \
    --merge "$prefix" \
    --out "$prefix" >> "$AUTONOMICS_OUTPUT2" 2>&1
fi

# Move the official products onto the declared output ports explicitly
# rather than relying on the runner to collect the workdir prefix.
mv -f "$AUTONOMICS_WORKDIR/magma_gene_analysis.genes.out" "$AUTONOMICS_OUTPUT0"
mv -f "$AUTONOMICS_WORKDIR/magma_gene_analysis.genes.raw" "$AUTONOMICS_OUTPUT1"
test -s "$AUTONOMICS_OUTPUT0"
test -s "$AUTONOMICS_OUTPUT1"

# Underpowered-output detector for a GRCh37/GRCh38 mismatch: MAGMA
# annotates against the NCBI37.3 table using the coordinates baked into the
# annotation, so a mismatched build shows up as genes carrying only a
# handful of SNPs. A mean below 5 SNPs/gene over a multi-gene result is the
# empirical signature (dense CAD genes normally retain 50+). The .genes.out
# table is whitespace-separated, not tab-separated.
awk '
  NR == 1 || $1 ~ /^#/ { next }
  NF >= 5 {
    genes++
    if ($5 + 0 > 0) { covered++; snps += $5; if (covered == 1 || $5 + 0 < min) min = $5 + 0 }
    else bare++
  }
  END {
    if (genes < 100 || covered == 0) exit 0
    mean = snps / covered
    if (mean < 5 || bare > genes / 2) {
      printf "WARNING: only %.1f SNPs/gene on average over %d genes (%d with none, min %d).\n", mean, genes, bare, min > "/dev/stderr"
      printf "         If the SNP annotation was built from GRCh38 coordinates it\n" > "/dev/stderr"
      printf "         matches almost nothing against the NCBI37.3/GRCh37 gene model.\n" > "/dev/stderr"
    } else {
      printf "annotated %d genes, mean %.1f SNPs/gene (min %d)\n", genes, mean, min > "/dev/stderr"
    }
  }
' "$AUTONOMICS_OUTPUT0" >&2
