# Re-create jbrowse2 files
rm -rf /web/data/

# Prepare data
samtools faidx /data/genomic.fna
jbrowse sort-gff /data/genomic.gff | bgzip > /data/genomic.sorted.gff.gz
tabix /data/genomic.sorted.gff.gz

# Add tracks
jbrowse add-assembly /data/genomic.fna --load copy --out /web/data
jbrowse add-track /data/genomic.sorted.gff.gz --load copy --out /web/data
jbrowse text-index --out /web/data
