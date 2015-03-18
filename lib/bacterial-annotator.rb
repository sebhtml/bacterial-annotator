# -*- coding: utf-8 -*-
# author:  	maxime déraspe
# email:	maxime@deraspe.net
# review:  	
# date:    	15-02-24
# version: 	0.0.1
# licence:  	

require 'bio'
require 'fileutils'

require 'bacterial-annotator/genbank-manip'
require 'bacterial-annotator/fasta-manip'
require 'bacterial-annotator/synteny-manip'
require 'bacterial-annotator/remote-ncbi'

class BacterialAnnotator

  # Initialize BacterialAnnotator
  def initialize fasta, refgenome, root, outdir, options

    @root = root
    @outdir = outdir
    @options = options
    if @options.has_key? :minlength
      @minlength = @options[:minlength].to_i
    else
      @minlength = 500
    end

    if File.exists? (@outdir)
      if ! options.has_key? :force
        abort "Output directory already exist ! Choose another one or use -f to overwrite"
      else
        puts "Overwriting output directory #{@outdir}"
        FileUtils.remove_dir(@outdir, force=true)
      end
    end

    Dir.mkdir(@outdir)
    @fasta = FastaManip.new(fasta)
    @refgenome = GenbankManip.new(refgenome, outdir)
    @prot_synteny = nil
    @annotation_stats = {by_contigs: {},
                         annotated_cds: 0,
                         total_cds: 0,
                         foreign_contigs: [],
                         synteny_contigs: [],
                         short_contigs: []}

    @contig_foreign_cds = {}
    @contig_annotations = {}

    puts "Successfully loaded #{@refgenome.gbk.definition} genomes"

  end

  # Prepare files for the annotation
  # Will run prodigal on the query and prepare reference genome files
  def prepare_files_for_annotation
    puts "\nRunning Prodigal on your genome.."
    @fasta.run_prodigal @root, @outdir
    @refgenome.write_cds_to_file @outdir
    puts "\nProdigal done."
  end

  # run_alignment of reference genome proteins and the query
  def run_annotation

    @prot_synteny = SyntenyManip.new(@fasta.prodigal_files[:proteins], @refgenome.cds_file)
    puts "\nRunning BLAT alignment.."
    @prot_synteny.run_blat @root, @outdir
    @prot_synteny.extract_hits

    @fasta.prodigal_files[:contigs].each_with_index do |contig, contig_index|

      # Skip short contigs
      if @fasta.prodigal_files[:contigs_length][contig_index] < @minlength
        @annotation_stats[:short_contigs] << contig
        next
      end

      contig_prots = @fasta.prodigal_files[:prot_ids_by_contig][contig]

      # contig_prot_annotations = @prot_synteny.get_annotation_for_contig contig_prots, @refgenome.coding_seq
      @contig_annotations[contig] = @prot_synteny.get_annotation_for_contig contig_prots, @refgenome.coding_seq

      remaining_cds = cumulate_annotation_stats_reference contig, @contig_annotations[contig]

      if ! remaining_cds.empty?
        @contig_foreign_cds[contig] = remaining_cds
      end

    end

    # dump foreign proteins to file
    foreign_cds_file = dump_cds

    # Finishing annotation for foreign proteins
    finish_annotation foreign_cds_file

    # Parse annotations to genbank files
    parsing_genbank_files

    puts "\nPrinting Statistics.."
    print_stats "#{@outdir}/Annotation-Stats.txt"

  end


  # Finishing the annotation of the remaining CDS
  def finish_annotation remaining_cds_file

    if @options.has_key? :external_db	# from an external DB
      


    elsif @options.has_key? :remote_db	# from a remote DB  

      remotedb = @options[:remote_db]
      valid = true
      begin
        puts "\nNCBI blast on #{remotedb} for foreign proteins"
        ncbiblast = RemoteNCBI.new(remotedb,
                                   remaining_cds_file,
                                   "#{remaining_cds_file}.ncbiblast.#{remotedb}.xml")
      rescue
        valid = false
      end

      # ncbi blast didn't worked out
      if !valid
        puts "Problem NCBI blast for foreign proteins"
      else
        ncbiblast.extract_blast_results
        ncbiblast.aln_hits.each do |k,v|
          contig_of_protein = k.split("_")[0..-2].join("_")
          # @contig_annotations[contig_of_protein][k][:product] = v[:hits][0][:product]
          @contig_annotations[contig_of_protein][k] = {product: v[:hits][0][:product],
                                                       gene: nil,
                                                       locustag: nil}
        end
      end

    end

  end


  # parse all genbank files
  def parsing_genbank_files

    @contig_annotations.each do |contig, contig_prot_annotations|
      puts "Parsing annotation for #{contig}.."
      gbk_path = @fasta.prodigal_files[:gbk_path]
      gbk_to_annotate = GenbankManip.new("#{gbk_path}/#{contig}.gbk", "#{gbk_path}")
      gbk_to_annotate.add_annotation contig_prot_annotations, gbk_path, 0
    end

  end


  # cumulate the stats for the synteny
  # return : unannotated cds array
  def cumulate_annotation_stats_reference contig, contig_prots_ann

    remaining_cds = []
    contig_prots = @fasta.prodigal_files[:prot_ids_by_contig][contig]

    @annotation_stats[:total_cds] += contig_prots.length if contig_prots
    contig_prots_ann.each do |k,v|
      if v != nil
        @annotation_stats[:annotated_cds] += 1
      else
        remaining_cds << k
      end
    end

    # Annotated Contigs
    if contig_prots_ann.keys.length < 1
      @annotation_stats[:foreign_contigs] << contig
    else
      @annotation_stats[:synteny_contigs] << contig
    end

    remaining_cds
  end


  # print statistics to file
  def print_stats file

    total_nb_contigs = @annotation_stats[:foreign_contigs].length +
                       @annotation_stats[:synteny_contigs].length +
                       @annotation_stats[:short_contigs].length
    p_contigs_annotated = @annotation_stats[:synteny_contigs].length.to_f/total_nb_contigs.to_f
    p_cds_annotated = @annotation_stats[:annotated_cds].to_f/@annotation_stats[:total_cds].to_f

    File.open(file, "w") do |fopen| 
      fopen.write("#Contigs annotation based on reference genomes\n")
      fopen.write("Short Contigs (< #{@minlength}) :\t" + @annotation_stats[:short_contigs].length.to_s + "\n")
      fopen.write("Foreign Contigs :\t\t" + @annotation_stats[:foreign_contigs].length.to_s + "\n")
      fopen.write("Annotated Contigs :\t\t" + @annotation_stats[:synteny_contigs].length.to_s + "\n")
      fopen.write("Total Contigs :\t\t\t" + total_nb_contigs.to_s + "\n") 
      fopen.write("% Contigs annotated :\t\t" + (p_contigs_annotated*100).to_s + "\n")
      fopen.write("\n")

      fopen.write("#CDS annotations based on reference genomes\n")
      fopen.write("Annotated CDS :\t\t\t" + @annotation_stats[:annotated_cds].to_s + "\n")
      fopen.write("Total CDS :\t\t\t" + @annotation_stats[:total_cds].to_s + "\n")
      fopen.write("% CDS annotated :\t\t" + (p_cds_annotated*100).to_s + "\n")
      fopen.write("\n")

    end

  end


  # dump cds to file for blast
  def dump_cds

    cds_outfile = File.open("#{@outdir}/Proteins-foreign.fa","w")
    foreign_cds = []
    @contig_foreign_cds.each_value do |v| 
      foreign_cds.push(*v)
    end
    inprot = false
    File.open(@fasta.prodigal_files[:proteins]) do |fprot|
      while l=fprot.gets
        if l[0] == ">"
          inprot = false
          prot_id = l.chomp.split(" ")[0].delete(">")
          if foreign_cds.include? prot_id
            inprot = true
            cds_outfile.write(l)
          end
        elsif inprot
          cds_outfile.write(l)
        end
      end
    end
    cds_outfile.close
    return "#{@outdir}/Proteins-foreign.fa"

  end

  private :dump_cds

end