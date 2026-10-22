set -eu

# Column-1 semantics differ by input: a PLINK .bim is accepted verbatim by
# the official reader (column 2 is the SNP ID), everything else is read as
# SNP CHR BP. Only the coordinate column is validated here.
snp_loc="$AUTONOMICS_INPUT0"

# Official flag is `--annotate window=N` in kilobases; `up,down` sets an
# asymmetric window (only meaningful strand-insensitive, which MAGMA
# applies via the ignore-strand modifier). 0 disables the window.
window=${MAGMA_ANNOT_WINDOW_KB:-10}
# Accept `N` (symmetric) or `up,down` (asymmetric, strand-insensitive).
# Split explicitly rather than with a case glob: `up,down` contains the
# comma that a glob would have to reject.
win_up=${window%%,*}
win_down=${window#*,}
[ "$win_down" = "$window" ] && win_down=$win_up
case "$win_up" in
  '' | *[!0-9]*)
    echo "window_kb must be N, up,down, or 0 (kilobases); got '$window'" >&2
    exit 1
    ;;
esac
case "$win_down" in
  '' | *[!0-9]*)
    echo "window_kb must be N, up,down, or 0 (kilobases); got '$window'" >&2
    exit 1
    ;;
esac
[ "$win_up" -le 1000 ] && [ "$win_down" -le 1000 ] || {
  echo "window_kb components must not exceed 1000 kilobases; got '$window'" >&2
  exit 1
}

MODS="window=$window"
if [ "${MAGMA_ANNOT_IGNORE_STRAND:-false}" = "true" ]; then
  MODS="$MODS ignore-strand"
fi
if [ "$window" = 0 ]; then
  MODS=""
fi

# Pre-flight the coordinate column. MAGMA reads SNP location files
# POSITIONALLY, so a standard GWAS/LDSC table (SNP A1 A2 FRQ BETA SE P ...)
# silently makes it parse the A1 allele as the chromosome code, and a
# GRCh38 build silently matches almost nothing. Both produce a near-empty
# annotation; catching them here keeps the failure explicit.
awk -v label="$(basename "$snp_loc")" '
  # A PLINK .bim is chr, snp, cm, bp, a1, a2: the coordinate is column 4.
  # Everything else is SNP CHR BP: the coordinate is column 3.
  BEGIN { col = (label ~ /\.bim$/) ? 4 : 3 }
  {
    n = NF
    if (col > n) { next }
    v = $col
    if (v == "" || v == "NA" || v == "NaN" || v == ".") { next }
    if (v !~ /^[0-9]+$/) {
      bad++
      if (bad <= 3) {
        printf "ERROR: %s column %d must be a GRCh37 base-pair position, found %s\n",
          label, col, v > "/dev/stderr"
      }
      next
    }
    ok++
    if (v > 308832240) { beyond++ }
  }
  END {
    if (ok == 0) {
      printf "ERROR: no parseable base-pair positions in %s column %d\n", label, col > "/dev/stderr"
      printf "       expected SNP CHR BP as the leading columns (or a PLINK .bim).\n" > "/dev/stderr"
      printf "       A GWAS/LDSC summary-statistics table puts A1/A2 in column 2\n" > "/dev/stderr"
      printf "       and MAGMA would parse that allele as the chromosome code.\n" > "/dev/stderr"
      exit 2
    }
    if (bad > 0 && bad >= ok) {
      printf "ERROR: %s: all %d parsed positions were non-integer — this looks like a\n", label, bad > "/dev/stderr"
      printf "       summary-statistics table. Derive SNP CHR BP by joining to the\n" > "/dev/stderr"
      printf "       reference .bim on rsID, then feed that three-column file here.\n" > "/dev/stderr"
      exit 2
    }
    if (bad > 0) {
      printf "WARNING: %s: %d of %d positions were not integers and were skipped\n", \
        label, bad, bad + ok > "/dev/stderr"
    }
    if (beyond > 0 && beyond * 2 >= ok) {
      printf "ERROR: %s: %d of %d positions exceed the GRCh37 chr1 length (308,832,240 bp).\n", \
        label, beyond, ok > "/dev/stderr"
      printf "       The annotation is NCBI37.3/GRCh37; GRCh38 coordinates match nothing.\n" > "/dev/stderr"
      printf "       Lift the coordinates (CrossMap/liftOver) before annotating.\n" > "/dev/stderr"
      exit 2
    }
  }
' "$snp_loc" >&2

prefix="$AUTONOMICS_WORKDIR/magma_annotate"

magma \
  --annotate $MODS \
  --snp-loc "$snp_loc" \
  --gene-loc /panels/gene_loc/NCBI37.3.gene.loc \
  --out "$prefix" \
  > "$AUTONOMICS_OUTPUT0" 2>&1

# Move the official products onto the declared output ports explicitly
# rather than relying on the runner to collect the workdir prefix.
mv -f "$prefix.genes.annot" "$AUTONOMICS_OUTPUT1"
test -s "$AUTONOMICS_OUTPUT1"