set -eu

# Competitive gene-set analysis on the .genes.raw output of
# magma_gene_analysis. correct=all is the official default and adjusts
# for gene size/SNP count, within-gene LD density, minor-allele count and
# sample size; "none" turns every correction off. v0 params have no enum
# type, so the script rejects anything else (lava analysis-param
# precedent).
ARGS=""
if [ -n "$MAGMA_GENE_SET_CORRECT" ]; then
  case "$MAGMA_GENE_SET_CORRECT" in
    all | none) ARGS="--model correct=$MAGMA_GENE_SET_CORRECT" ;;
    *)
      echo "correct must be all or none (got '$MAGMA_GENE_SET_CORRECT')" >&2
      exit 1
      ;;
  esac
fi

# Gene-set files pass through untouched: MAGMA discards unmatched values,
# so a GMT's description column is dropped by the official reader itself.
# ARGS is whitelist-controlled, never user text (ldsc munge precedent).
#
# A symbol-keyed set file matches no NCBI37.3 Entrez gene. Field 1 of each
# row is the set NAME, so gene IDs start at field 2. Judge the MAJORITY of
# sampled gene fields, not a single one: a GMT description column or an
# occasional numeric-looking symbol makes a per-field probe unreliable.
counts=$(awk '
  NF >= 2 {
    for (i = 2; i <= NF; i++) {
      if ($i == "") continue
      seen++
      if ($i ~ /^[0-9]+$/) num++
      else { sym++; if (!first) first = $i }
      if (seen >= 200) { done = 1; exit }
    }
  }
  END { printf "%d %d %s\n", num + 0, sym + 0, first }' "$AUTONOMICS_INPUT1")
set -- $counts
if [ "${2:-0}" -gt "${1:-0}" ]; then
  echo "gene sets must use NCBI37.3 Entrez numeric gene IDs, but most sampled IDs" >&2
  echo "are not numeric (e.g. '$3')." >&2
  echo "Symbol-keyed MSigDB GMTs never match — use the Entrez (Entrez_Gene) editions." >&2
  exit 1
fi

magma \
  --gene-results "$AUTONOMICS_INPUT0" \
  --set-annot "$AUTONOMICS_INPUT1" \
  $ARGS \
  --out "$AUTONOMICS_WORKDIR/magma_gene_set" \
  > "$AUTONOMICS_OUTPUT1" 2>&1

# Move the official product onto the declared output port explicitly rather
# than relying on the runner to collect the workdir prefix.
mv -f "$AUTONOMICS_WORKDIR/magma_gene_set.gsa.out" "$AUTONOMICS_OUTPUT0"
test -s "$AUTONOMICS_OUTPUT0"

# Silent all-zero results are the other GSA failure mode (a .genes.raw from
# a mismatched build, or sets that simply do not overlap).
if awk 'NR > 1 && $0 !~ /^#/ { if ($3 == 0) zero++; total++ }
       END { exit !(total > 0 && zero == total) }' "$AUTONOMICS_OUTPUT0"; then
  echo "WARNING: every gene set matched zero genes — check that the gene sets" >&2
  echo "         share the annotation's gene identifiers (Entrez numeric IDs)." >&2
fi
