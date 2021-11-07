// time nextflow -log index_with_annotations.log run main.nf --reads Data/Reads/
// nextflow run main.nf --reads ../Data/Reads --genome ../Data/Genome/Homo_sapiens.GRCh38.dna.primary_assembly.fa

/*
    Nexflow pipeline to perform a full RNA-seq analysis (differential expression)
    from a series of SRA accession numbers and a reference genome.

    All parameters are defined in the `params` scope
    within the "nextflow.config" configuration file.
    However the default values can be overriden by 
    specifing them as command line arguments.

    Usage:
    -----
    * Launch the pipeline using the default params
        $ nextflow run main.nf

    * Override params.ids (SRA accession numbers)
        TODO



    ######################################################################
                    WORKFLOW DIAGRAM
    ######################################################################

    ---------------     --------------------
    | SRA entries |     | Reference genome |
    ---------------     --------------------
        ||                     ||
        ||                     ||
        ||              ------------------
        ||              | Index building |
        ||              ------------------
        \\                     ||
         \\                    ||
          \\           ------------------------
           \\==========| Mapping RNA-seq data |
                       | to reference genome  |
                       ------------------------
                               ||
                               ||
                        -------------------------------
                        | Building a count matrix     |
                        | (for genes accross samples) |
                        -------------------------------
                               ||
                               ||
                        -----------------------
                        |Perform differential |
                        |expression analysis  |
                        -----------------------
                               ||
                               ||
                        -----------------
                        | Build reports |
                        -----------------

    ######################################################################
*/

// nextflow run main.nf --reads ../Data/Reads --genome ../Data/Genome/GRCh38.primary_assembly.genome.fa
nextflow.enable.dsl=2

// I called it DIFF RNA for Differential RNA analysis
log.info """\
D I F F R N A - N F  v0.1.0 
===========================
genome       : $params.genome_url
annotations  : $params.annotation_url
reads        : $params.ids
readlength-1 : $params.sjdbOverhang
"""


process Fasterq {
    /*
    Use ncbi sra-tools' fasterq-dump to rapdily retrieve
    and extract fastq files from SRA-accession-numbers.

    arguments:
    ---------
        ids: a SRA accession number (a channel containing many of them)

    output:
    ------
        A chanel of tuples, containing the id (SRA accession)
        and the path to the fastq files (id, [id_1.fastq, id_2.fastq])

    For further information refer too fasterq-dump's documentation:
    https://github.com/ncbi/sra-tools/wiki/HowTo:-fasterq-dump
    */

    tag "Importation of ${ids}"

    input:
        val ids

    output:
        tuple val("${ids}"), path("*_{1,2}.fastq")

    script:
    """
    fasterq-dump ${ids}
    """
}

process Genome {
    /*
    Use `wget` to retrieve a genome, then expand it using `gunzip`.

    arguments:
    ---------
        url: url pointing to the desired reference genome

    output:
    ------
        A path (glob), of all the uncompressed parts of the genome.
    */
    tag "Retreiving genome: ${genome_url}, annotation: ${annotation_url}"

    input:
        tuple val(genome_url), val(annotation_url)

    output:
        tuple path("*.f*a"), path("*.gtf")
        // DISCUSSION :
        // gunzip expands the patterns `*.fna.gz` and `*fa.gz`
        // shouldn't this wildcard be the same ?

    script:
    """
    #!/usr/bin/env bash
    wget ${genome_url}
    [[ ${genome_url} == *.gz ]] && gunzip *.gz || echo "File already unzip."
    wget ${annotation_url}
    [[ ${annotation_url} == *.gz ]] && gunzip *.gz || echo "File already unzip."
    """
}

process Index {
    /*
	Create an index for the desired reference genome.

    arguments:
    ---------
        genome_file: a path, pointing to the genomeFastaFiles

    output:
    ------
        path: A directory containing the genome index generated by STAR

    params:
    ------
        params.index_cpus: an integer, specifying the number of threads to be used
                           whilst creating the index.

    */

    tag "Creation of the index"

    input:
        tuple path(genome_path), path(annotation_path)

    output:
        path "GenomeDir"
    
    script:
    """
    STAR --runThreadN ${params.index_cpus}\
         --runMode genomeGenerate\
         --genomeFastaFiles ${genome_path}\
         --sjdbGTFfile ${annotation_path}\
         --sjdbOverhang ${params.sjdbOverhang}
    """
}

// process Mapping {
    /*
    STAR for short-read whole-transcriptome sequencing data.
    */
    // TODO : write the process specification.
// }

workflow {

    // SEE EXPLANATION OF THE NEW PROGRAM STRUCTURE AFTER THE WORKFLOW

    // Retrieve RNA-seq data (fastq files / SRA accession numbers)
    ids = Channel.fromList(params.ids)
    fasterq_files = (
        params.reads == null ?
        Fasterq(ids) :
        Channel.fromFilePairs("${params.reads}/SRR*_{1,2}.fastq*", checkIfExists:true)
    )
    //fasterq_files.view()

    // Retrieve genome and annotations
    //url_tuple = new Tuple(params.genome_url, Channel.value(params.annotation_url))
    url_tuple = new Tuple(params.genome_url, params.annotation_url)
    genome_tuple = (
        params.genome == null ?
        Genome(url_tuple) :
        new Tuple(
            Channel.fromPath("${params.genome}/*.f*a", checkIfExists:true)
            Channel.fromPath("${params.genome}/*.gtf", checkIfExists:true)
        )
    )
    //genome_file.view()

    // Create genome index
    path_index = (
        params.index == null ?
        Index(genome_tuple) :
        Channel.fromPath("${params.index}", checkIfExists:true)
    )
    path_index.view()

}


// MANUAL TESTING COMMANDS HISTORY :

// docker pull combinelab/salmon
// wget ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_29/gencode.v29.transcripts.fa.gz
// wget ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_29/GRCh38.primary_assembly.genome.fa.gz
// cat gencode.v29.transcripts.fa.gz GRCh38.primary_assembly.genome.fa.gz > gentrome.fa.gz
// salmon index -t gentrome.fa.gz --decoys GRCh38.primary_assembly.genome.fa.gz -p 12 -i salmon_index --gencode

// gunzip *.f*a.gz
// salmon index -t gencode.v29.transcripts.fa.gz -i index --gencode

// STAR --runThreadN 6 --runMode genomeGenerate –genomeDir Index --genomeFastaFiles Genome/GRCh38.primary_assembly.genome.fa