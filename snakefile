#### Global setup ####

fastq_files, = glob_wildcards('data/02_seqdata/{filename}.fq.gz')
TISSUE_TYPES = ("placenta_maternal", "lung_maternal", "liver_maternal", "liver_fetal", "placenta_fetal")
MODELS = ("placentas", "fetal_liver", "maternal_liver", "maternal_lung")

MIN_COUNTS = 10
ALPHA = 0.05
MIN_LOGFC = 0.5

import re

rule all:
  input: 
    multiqc_report = "reports/multiqc/multiqc.html",
    tpm_results = "results/tpm_summary/tpm_tibble.rds",
    limma_results =  "results/limma_compile_results/limma_results_no_maternal_contrasts.csv",
    go_results = expand(
          "results/gost_enrichment_format/enrichment_{models}_{up_or_down}_long.csv",
          models = MODELS, 
          up_or_down = ("upregulated", "downregulated")
    ),
    fold_change_matrices = "results/heatmap_fold_change_format/response_matrix_list.rds",
    receptor_ligand_map =  "results/match_orthologs/human_mouse_ligands_receptors.txt",
    upsetr_plots = expand(
          "results/upsetr/{tissue}.pdf",
          tissue = MODELS
    ),
    pathview_graphs = expand(
          "results/pathview_{data}",
          data = ("rnaseq") # "phospho/sites"
    ),
    lien_comparisons = expand(
      "results/inflammation_comparison/{tissue}_{value}_plot.pdf",
      tissue = ("placenta", "lung"),
      value = ("baseline", "response")
    ),
    phospho_results = expand(
      "results/phospho_limma/{tissue}/significant_results.csv",
      tissue = ("liver", "placenta")
    )

#### Quality controls ####

rule md5:
  input:
    "data/02_seqdata/MD5.txt",
    "data/02_seqdata/MD5-1.txt"
  log:
    "results/md5/md5_checks.txt"
  output:
    touch("results/md5_checks_completed.done")
  threads: 20
  shell:
    '''
    cat {input} | awk '{{print $1 " data/02_seqdata/" $2}}' | parallel --jobs {threads} --pipe -N1 md5sum -c >> {log}
    '''

rule fastqc:
  input: 
    "results/md5/md5_checks.txt",
    "data/02_seqdata/{fastq_file}.fq.gz"
  output:
    zip="results/fastqc/{fastq_file}_fastqc.zip"
  log:
    "logs/fastqc/{fastq_file}_fastqc.log"
  threads: 
    1
  shell:
    '''
    nice --adjustment=+30 fastqc {input} -o=results/fastqc/ 2> {log}
    '''
    
rule multiqc:
  input: 
    expand("results/fastqc/{filename}_fastqc.zip", filename = fastq_files)
  output: 
    "reports/multiqc/multiqc.html"
  shell: 
    '''
    multiqc results/fastqc/ -n {output}
    '''

rule trim_reads:
  input:
    multiqc = "results/multiqc/multiqc.html",
    fastq = "data/02_seqdata/{fastq_file}.fq.gz"
  output: 
    "results/trim_reads/{fastq_file}.fq"
  threads: 1
  shell:
    '''
    seqtk trimfq -b 11 {input.fastq} > {output}
    '''
#### Salmon quantification ####

# Download mouse reference transcriptome from Gencode v23
rule download_mouse:
  output:
    transcriptome = 'data/Mouse/gencode.vM23.transcripts.fa.gz',
    genome = 'data/Mouse/GRCm38.primary_assembly.genome.fa.gz'
  log:
    "logs/download_mouse.txt"
  shell:
    '''
    curl -o {output.transcriptome} ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_M23/gencode.vM23.transcripts.fa.gz 2> {log}
    curl -o {output.genome} ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_M23/GRCm38.primary_assembly.genome.fa.gz 2>> {log}
    '''

# Index mouse genome for salmon quantification
rule salmon_index:
  input:
    transcriptome = 'data/Mouse/gencode.vM23.transcripts.fa.gz',
    genome = 'data/Mouse/GRCm38.primary_assembly.genome.fa.gz'
  output:
      decoys = temp("results/salmon/mouse_transcriptome_index/decoys.txt"),
      gentrome = temp("results/salmon/mouse_transcriptome_index/gentrome.fa"),
      index = directory("results/salmon/mouse_transcriptome_index/ref_idexing"),
  threads: 30
  params:
      kmer = 31
  shell:
      '''
      # Crate decoy file
      echo "Creating Decoy File"
      grep "^>" <(zcat {input.genome}) | cut -d " " -f 1 > {output.decoys} &&
      sed -i -e 's/>//g' {output.decoys} &&
      # Concatenate genome and transcriptome
      echo "Concatenating genome and transcriptome"
      zcat {input.transcriptome} {input.genome} > {output.gentrome} &&
      # Create index
      echo "Creating index"
      salmon index \
                -t {output.gentrome} \
                -i {output.index} \
                -d {output.decoys} \
                -p {threads} \
                -k {params.kmer} \
                --gencode
      '''

# Quantify read counts via Samon
rule salmon_quant:
  input:
    index = "results/salmon/mouse_transcriptome_index/ref_idexing",
    reads_1 = "results/trim_reads/{sample_id}_1.fq",
    reads_2 = "results/trim_reads/{sample_id}_2.fq"
  output:
    outdir = directory("results/salmon/salmon_quant/{sample_id}")
  params:
    libtype = "ISR",
    numBootstraps = 10,
    minScoreFraction = 0.8,
  threads: 10
  shell:
    '''
    ionice -c2 -n7 \
    salmon quant \
            -i {input.index} \
            -l {params.libtype} \
            -1 {input.reads_1} \
            -2 {input.reads_2} \
            -o {output.outdir} \
            --validateMappings \
            --minScoreFraction {params.minScoreFraction} \
            --numBootstraps {params.numBootstraps}\
            --gcBias \
            --seqBias \
            --writeUnmappedNames \
            --threads {threads} \
    '''
    
#### Metadata annotation ####

# Import sample metadata
rule metadata_import:
  input:
  output:
    rdata = "results/metadata/sample_metadata.Rdata",
    csv = "results/metadata/sample_metadata.csv"
  script:
    "scripts/metadata.R"

# Merge read counts and metadata via tximeta
rule tximeta:
  input:
    salmon_dirs = expand("results/salmon/salmon_quant/{sample_id}", sample_id = list(set([re.sub('_[1-2]$', '', string) for string in fastq_files]))),
    metadata = "results/metadata/sample_metadata.Rdata"
  output:
    expression_results = "results/tximeta/expression_results.Rdata",
    variance_stabilized_counts = "results/tximeta/variance_stabilized_counts.csv"
  script:
    "scripts/tximeta.R"

# Download gene symbols and description
rule download_gene_data:
  input:
    "results/tximeta/variance_stabilized_counts.csv"
  output:
    "results/download_gene_data/gene_names.Rdata"
  script:
    "scripts/download_gene_data.R"

# Save TPM summary tibble
rule tpm_summary:
  input:
    mgi_symbols = "results/download_gene_data/gene_names.Rdata",
    expression_results = "results/tximeta/expression_results.Rdata"
  output:
    tpm_results = "results/tpm_summary/tpm_tibble.rds"
  script:
    "scripts/TPM_summary.R"

#### Linear models for DE ####

# Fit linear models for the 2 placentas
# NOTE
# 3 way interaction: the residual response of maternal placenta. 
# Positive for exposed maternal placentas, negative for maternal controls
# Negative for exposed foetal placenta, positive for foetal controls
# High values mean greater response in maternal than in fetal placenta and vice versa

rule limma_placentas:
  input:
    expression_results = "results/tximeta/expression_results.Rdata",
    gene_data = "results/download_gene_data/gene_names.Rdata"
  output:
    factor_design_matrix = "results/limma_placentas/factor_design_matrix.csv",
    count_distribution_plot = "results/limma_placentas/count_distribution.pdf",
    linear_models = "results/limma_placentas/fitted_model.Rdata",
    fdr_plot = "results/limma_placentas/fdr_plot.pdf",
    q_values_plot = "results/limma_placentas/q_value_distribution.pdf",
    q_values_plot_zoomed = "results/limma_placentas/q_value_distribution_zoomed.pdf",
    volcano_plots = "results/limma_placentas/volcano_plots.png",
    summary_csv = "results/limma_placentas/fold_change_summary.csv",
    summary_rds = "results/limma_placentas/fold_change_summary.rds"
  params:
    min_counts = MIN_COUNTS,
    fold_change_threshold = MIN_LOGFC,
    alpha = ALPHA
  script:
    "scripts/limma_placentas.R"

# Fit linear models for all non-placenta tissues
rule limma_non_placentas:
  input:
    expression_results = "results/tximeta/expression_results.Rdata",
    gene_data = "results/download_gene_data/gene_names.Rdata"
  output:
    factor_design_matrix = "results/limma_{tissue}/factor_design_matrix.csv",
    count_distribution_plot = "results/limma_{tissue}/count_distribution.pdf",
    linear_models = "results/limma_{tissue}/fitted_model.Rdata",
    fdr_plot = "results/limma_{tissue}/fdr_plot.pdf",
    q_values_plot = "results/limma_{tissue}/q_value_distribution.pdf",
    q_values_plot_zoomed = "results/limma_{tissue}/q_value_distribution_zoomed.pdf",
    volcano_plots = "results/limma_{tissue}/volcano_plots.png",
    summary_csv = "results/limma_{tissue}/fold_change_summary.csv",
    summary_rds = "results/limma_{tissue}/fold_change_summary.rds"
  params:
    min_counts = MIN_COUNTS,
    fold_change_threshold = MIN_LOGFC,
    alpha = ALPHA,
    tissue = "{tissue}"
  wildcard_constraints:
    tissue = ".*_.*"
  script:
    "scripts/limma_non_placentas.R"

# Merge all limma summaries in a single table
rule limma_compile_results:
  input:
    limma_results = expand(
      "results/limma_{models}/fold_change_summary.rds",
      models = MODELS
    )
  output:
    maternal = "results/limma_compile_results/limma_results_maternal_contrasts.csv",
    summary =  "results/limma_compile_results/limma_results_no_maternal_contrasts.csv"
  params:
    models = MODELS
  script:
    "scripts/limma_compile_results.R"

# Create upset plots of differentially expressed genes from linear model results
rule upset:
  input:
    "results/limma_{tissue}/fold_change_summary.rds"
  output:
    "results/upsetr/{tissue}.pdf"
  params:
    ALPHA = ALPHA,
    MIN_LOGFC = MIN_LOGFC
  script:
    "scripts/upsetr.R"
    
# Create variance stabilized counts for exploratory plotting
rule vsd:
  input:
    expression_results = 'results/tximeta/expression_results.Rdata'
  output:
    variance_stabilized_counts = 'results/tximeta/vsd.Rdata'
  params:
    min_counts = MIN_COUNTS
  script:
    'scripts/vsd.R'

#### Enrichment analyses and fold summary ####

# Perform enrichment across all ranked sets of genes
rule enrichment_run:
  input:
    limma_results = "results/limma_compile_results/limma_results_no_maternal_contrasts.csv"
  output:
    raw_results =  "results/gost_enrichment_run/go_{model}_{up_or_down}.rds"
  params: 
    model = "{model}",
    up_or_down = "{up_or_down}"
  script:
    "scripts/gost_enrichment_run.R"

# Format enrichment result to human readable tidy table
rule enrichment_format:
  input: "results/gost_enrichment_run/go_{model}_{up_or_down}.rds"
  output: 
    go_long_format = "results/gost_enrichment_format/enrichment_{model}_{up_or_down}_long.csv",
    go_wide_format = "results/gost_enrichment_format/enrichment_{model}_{up_or_down}_wide.csv"
  script: 
    "scripts/gost_enrichment_format.R"

# Format log fold change data for heatmaps
rule heatmap_fold_change_format:
  input:
    fold_change_summaries = expand(
      "results/limma_{tissue}/fold_change_summary.rds", 
      tissue = ("maternal_lung", "maternal_liver", "placentas", "fetal_liver")
      )
  output:
    matrix_list = "results/heatmap_fold_change_format/response_matrix_list.rds",
    lps_response = "results/heatmap_fold_change_format/lps_response_summary.csv",
    maternal_lps_response = "results/heatmap_fold_change_format/maternal_lps_response_summary.csv"
  script:
    "scripts/heatmap_fold_change_format.R"

# Import phospho proteomic data
rule phospho_import:
  input:
    results = "data/proteomics/20210202_second_run/Analysed_data_TMM_EdgeR_4_experiments__Jan_2021.xlsx"
  output:
    genewise_results = 'results/phospho_import/genewise_results.rds',
    genewise_fdr_plot = 'results/phospho_import/genewise_fdr_plot.pdf',
    sitewise_results = 'results/phospho_import/sitewise_results.rds'
  script:
    "scripts/phospho_import.R"

# Perform classic limma/voom analysis on phospho data
rule phospho_limma:
  input: 
    data = 'data/proteomics/20210202_second_run/MaxQuant_table_all4exp_Jan_2021.xlsx'
  output:
    significant_results = "results/phospho_limma/{tissue}/significant_results.csv",
    significant_genes = "results/phospho_limma/{tissue}/significant_genes.csv",
    linear_model = "results/phospho_limma/{tissue}/linear_model.rds"
  params:
    output_path = 'results/phospho_limma/{tissue}',
    tissue = "{tissue}"
  script:
    'scripts/phospho_limma.R'
    
# Create pathview graphs from rnaseq and phospho proteomic data    
rule pathview_rnaseq:
  input:
    rna = "results/limma_compile_results/limma_results_no_maternal_contrasts.csv",
  params:
    tissues = ("placentas", "fetal_liver"),
    pathways = (
      "mmu04064", "mmu04668", "mmu04020", "mmu04110", "mmu04210",
      "mmu00190", "mmu04150", "mmu04010", "mmu04620", "mmu04062",
      # "mmu03410", "mmu03420", "mmu03430", "mmu03450", # DNA repair
      "mmu04060", "mmu04657", "mmu04810", "mmu04670",
      "mmu04370", "mmu04012", "mmu04350", # angoigenesis
      "mmu04068", "mmu04115", # oxidative stress
      "mmu04530", # tight junctions/claudins
      "mmu04514",
      "mmu04658", "mmu04151", "mmu04630", "mmu04659", "mmu04660" # IL4
      )
  output:
    rna = directory("results/pathview_rnaseq")
  resources: 
    pathview = 1
  script:
    "scripts/pathview_rnaseq.R"

rule pathview_phospho:
  input:
    phospho_genes = "results/phospho_import/genewise_results.rds",
    phospho_sites = "results/phospho_import/sitewise_results.rds"
  params:
    tissues = ("placentas", "fetal_liver"),
    pathways = (
      "mmu04064", "mmu04668", "mmu04020", "mmu04110", "mmu04210",
      "mmu00190", "mmu04150", "mmu04010", "mmu04620", "mmu04062",
      # "mmu03410", "mmu03420", "mmu03430", "mmu03450", # DNA repair
      "mmu04060", "mmu04657", "mmu04810", "mmu04670",
      "mmu04370", "mmu04012", "mmu04350", # angoigenesis
      "mmu04068", "mmu04115", # oxidative stress
      "mmu04530", # tight junctions/claudins
      "mmu04514",
      "mmu04658", "mmu04151", "mmu04630", "mmu04659", "mmu04660" # IL4
      )
  output:
    phospho_genes = directory("results/pathview_phospho/genes"),
    phospho_sites = directory("results/pathview_phospho/sites")
  resources: 
    pathview = 1
  script:
    "scripts/pathview_phospho.R"
 
#### Receptor-ligand analyses ####

# List all genes involved in each protein complex for receptor/ligand pairs
rule untangle_pairs:
  input:
    "data/cellphone_db/protein_curated.csv",  
    "data/cellphone_db/complex_curated.csv", 
    "data/cellphone_db/interaction_curated.csv",
    "data/cellphone_db/gene_input.csv"
  output:
    "results/untangle_pairs/human_secreted_to_receptor.txt"
  shell:
    "scripts/untangle_pairs.pl {input} {output}"

# Create lookup table for human to mouse genes via bioMart
rule ortholog_conversion:
  input: 
    "results/untangle_pairs/human_secreted_to_receptor.txt"
  output:
    "results/ortholog_conversion/human_mouse_orthologs.txt"
  script:
    "scripts/ortholog_conversion.R"
  
# Remove multi-hit and no-hit human to mouse orthologs
rule match_orthologs:
  input:
    "results/ortholog_conversion/human_mouse_orthologs.txt",
    "results/untangle_pairs/human_secreted_to_receptor.txt"
  output:
    "results/match_orthologs/human_mouse_ligands_receptors.txt"
  shell:
    "scripts/match_orthologs.pl {input} {output}"

#### Compare with direct placenta inflammation study ####
## From     
## Lien YC, Zhang Z, Barila G, Green-Brown A et al. 
## Intrauterine Inflammation Alters the Transcriptome and Metabolome in Placenta. 
## Front Physiol 2020;11:592689. PMID: 33250783
## https://doi.org/10.3389/fphys.2020.592689
#########################################################

rule download_inflammation_study:
  output: 
    data = "data/direct_inflammation/GSE151728_count_gene.txt.gz",
    metadata = "data/direct_inflammation/GSE151728_family.soft.gz"
  shell:
    '''
    curl -o {output.data} ftp://ftp.ncbi.nlm.nih.gov/geo/series/GSE151nnn/GSE151728/suppl/GSE151728_count_gene.txt.gz 
    curl -o {output.metadata} ftp://ftp.ncbi.nlm.nih.gov/geo/series/GSE151nnn/GSE151728/soft/GSE151728_family.soft.gz
    '''
## Perform Limma analysis on Lien 2020 data

rule process_lien_results:
  input:
    "data/direct_inflammation/GSE151728_count_gene.txt.gz"
  output:
    hclust = "results/process_lien_results/pre_filtering_hclust.pdf",
    voom = "results/process_lien_results/voom_post_filtering.pdf",
    rds_results = "results/process_lien_results/fold_change_summary.rds",
    volcano_plot = "results/process_lien_results/volcano_plot.pdf",
    MA_plot = "results/process_lien_results/MA_plot.pdf"
  params:
    min_counts = MIN_COUNTS
  script:
    "scripts/process_lien_results.R"

# Plot comparisons between Lien and our results

rule inflammation_comparison:
  input:
    de_inflammation_results = "results/process_lien_results/fold_change_summary.rds",
    de_transfer_results = "results/limma_compile_results/limma_results_no_maternal_contrasts.csv"
  output:
    filtered_shared_genes_list = "results/inflammation_comparison/filtered_shared_genes_list.rds",
    placenta_baseline_plot = "results/inflammation_comparison/placenta_baseline_plot.pdf",
    placenta_response_plot = "results/inflammation_comparison/placenta_response_plot.pdf",
    lung_baseline_plot = "results/inflammation_comparison/lung_baseline_plot.pdf",
    lung_response_plot = "results/inflammation_comparison/lung_response_plot.pdf"
  params:
    q_value_threshold = 0.05,
    log_fc_threshold = 0.25
  script:
    "scripts/inflammation_comparison.R"

