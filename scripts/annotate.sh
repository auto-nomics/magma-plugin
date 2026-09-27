set -eu
magma \
  --annotate \
  --snp-loc "$AUTONOMICS_INPUT0" \
  --gene-loc /panels/gene_loc/NCBI37.3.gene.loc \
  --out "$AUTONOMICS_WORKDIR/magma_annotate" \
  > "$AUTONOMICS_OUTPUT0" 2>&1
