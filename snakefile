fastq_files, = glob_wildcards('data/02_seqdata/{filename}.fq.gz')
  
rule all:
  input: 
    expand("results/fastqc/{filename}_fastqc.zip", filename = fastq_files),
    "results/multiqc/multiqc.html"

rule fastqc:
  input: 
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
    "results/multiqc/multiqc.html"
  shell: 
    '''
    multiqc results/fastqc/ -n {output}
    '''
