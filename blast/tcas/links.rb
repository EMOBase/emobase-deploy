require 'erb'
require 'json'

module SequenceServer
  module Links
    include ERB::Util
    alias encode url_encode

    def jbrowse2
      # Direct link to JBrowse 2 (bypassing the Astro wrapper)
      base_url = "https://ibeetle-base.uni-goettingen.de/ibb/jbrowse2/"
      
      # 1. Match the assembly name in your config.json
      assembly_name = "Tcas5.2"

      # 2. Clean the ID for JBrowse (e.g., CAXITT010000015.1)
      clean_id = id.gsub(/^.*\|(.*)\|.*$/, '\1')
      ref_name = encode(clean_id)

      # 3. Get coordinates and normalize (IMPORTANT FIX)
      coords = coordinates[1]
      start_pos, end_pos = coords.min, coords.max

      # Optional: detect strand
      strand = coords[0] <= coords[1] ? 1 : -1

      # Unique ID for this specific hit track
      track_id = "blast_hit_#{Time.now.to_i}"

      # 4. Define the temporary track (session track)
      session_track = {
        type: "FeatureTrack",
        trackId: track_id,
        name: "BLAST Hit: #{clean_id}",
        assemblyNames: [assembly_name],
        adapter: {
          type: "FromConfigAdapter",
          features: [{
            uniqueId: "hit_#{track_id}",
            refName: clean_id,
            start: start_pos - 1, # 0-based start (JBrowse requirement)
            end: end_pos,         # 1-based end
            strand: strand,
            type: "match"
          }]
        },
        displays: [
          {
            type: "LinearBasicDisplay",
            displayId: "#{track_id}-LinearBasicDisplay"
          }
        ]
      }

      # 5. Construct the Direct URL
      url =  "#{base_url}?config=config.json"
      url += "&loc=#{ref_name}:#{start_pos}..#{end_pos}"
      url += "&assembly=#{encode(assembly_name)}"
      url += "&tracks=tcas5_iBeetle.sorted.gff,tcas5_ncbi.sorted.gff,ib.sorted.gff,#{track_id}"
      url += "&tracklist=true"
      url += "&sessionTracks=#{encode([session_track].to_json)}"

      {
        order: 1,
        title: 'Genome Browser',
        url:   url,
        icon:  'fa-search-plus'
      }
    end
  end
end
