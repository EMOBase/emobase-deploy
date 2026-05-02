#!/bin/sh

gunzip -c /data/from_ncbi/GCF_000002335.3_Tcas5.2_genomic.fna.gz \
	| makeblastdb -in - -dbtype nucl -title "T.cas genome (OGS3)" -parse_seqids -out "/db/Tcas-OGS3-genome"

cat /data/provided_by_Lizzy/Tcas5.2_GenBank.corrected_v5.renamed.aa \
	| makeblastdb -in - -dbtype prot -title "T.cas proteins (OGS3)" -parse_seqids -out "/db/Tcas-OGS3-prot"

makeblastdb -in /data/provided_by_Lizzy/Tcas5.2_GenBank.corrected_v5.renamed.mrna -dbtype nucl -title "T.cas mRNA (OGS3)" -parse_seqids -out "/db/Tcas-OGS3-mRNA"
