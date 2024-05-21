#!/bin/sh
DISPLAY_NAME="$*"

makeblastdb -in /data/genomic.fna -dbtype nucl -title "${DISPLAY_NAME} Genome" -parse_seqids -out "/db/genome"
makeblastdb -in /data/protein.faa -dbtype prot -title "${DISPLAY_NAME} Proteins" -parse_seqids -out "/db/protein"
makeblastdb -in /data/rna.fna -dbtype nucl -title "${DISPLAY_NAME} RNAs" -parse_seqids -out "/db/rna"
