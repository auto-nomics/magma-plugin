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
magma \
  --gene-results "$AUTONOMICS_INPUT0" \
  --set-annot "$AUTONOMICS_INPUT1" \
  $ARGS \
  --out "$AUTONOMICS_WORKDIR/magma_gene_set" \
  > "$AUTONOMICS_OUTPUT1" 2>&1

test -s "$AUTONOMICS_OUTPUT0"
