# Re-create jbrowse2 files
cp /work/config.json /web/config.json
jbrowse text-index --force --out /web/ --tracks=tcas5_iBeetle.sorted.gff,tcas5_ncbi.sorted.gff,ib.sorted.gff,OGS2.sorted.gff,au4.liftover.sorted.gff
