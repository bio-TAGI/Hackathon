/* nextflow run main.nf --reads ../Data/Reads --genome ../Data/Genome --index ../Data/Index --mapping ../Data/Mapping \
--index_cpus 7 \
--mapping_cpus 7 \
--mapping_memory '12GB'
*/

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

nextflow.enable.dsl=2

log.info """\
D I F F R N A - N F  v0.1.0 
===========================
genome_url       :  $params.genome_url
annotations_url  :  $params.annotation_url
SRA ids          :  $params.ids
readlength-1     :  $params.sjdbOverhang
reads_dir        :  $params.reads
genome_dir       :  $params.genome
index_dir        :  $params.index
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

    tag "Downloading ${ids}..."

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
    tag "Retrieving genome: ${genome_url}, annotation: ${annotation_url}"

    input:
        val genome_url
        val annotation_url

    output:
        path "*.f*a"
        path "*.gtf"
        // DISCUSSION :
        // gunzip expands the patterns `*.fna.gz` and `*fa.gz`
        // shouldn't this wildcard be the same ?

    script:
    """
    #!/usr/bin/env bash
    echo "Downloading genome..."
    wget ${genome_url}
    [[ ${genome_url} == *.gz ]] && gunzip *.gz || echo "File already unzip."
    echo "Downloading annotations..."
    wget ${annotation_url}
    [[ ${annotation_url} == *.gz ]] && gunzip *.gz || echo "File already unzip."
    """
}

process Index {
    /*
	Create an index for the desired reference genome.

    arguments:
    ---------
        genome_path: a path, pointing to the genome fasta file
        annotation_path: a path, pointing to the annotation gtf file

    output:
    ------
        path: a directory containing the genome index generated by STAR

    params:
    ------
        params.index_cpus: an integer, specifying the number of threads to be used
                           whilst creating the index.
    */

    cpus params.index_cpus
    tag "Creation of the index"

    input:
        path genome_path
        path annotation_path

    output:
        path "GenomeDir"
    
    script:
    """
    #!/usr/bin/env bash
    STAR --runThreadN ${task.cpus} \
         --runMode genomeGenerate \
         --genomeFastaFiles ${genome_path} \
         --sjdbGTFfile ${annotation_path} \
         --sjdbOverhang ${params.sjdbOverhang}
    """

}

process Mapping {
    /*
	Create the mapping for the RNA-seq data.

    arguments:
    ---------
        fastq_files: a list of paired paths, each pointing to paired-end fastq files
        index_path: a directory containing the genome index

    output:
    ------
        path: a path to BAM file generated by STAR

    params:
    ------
        params.mapping_memory: an integer, specifying the number of RAM memory to allocate
                           whilst creating the BAM files. 
        params.mapping_cpus: an integer, specifying the number of threads to be used
                           whilst creating the BAM files.
    */

    memory params.mapping_memory
    cpus params.mapping_cpus
    tag "Mapping ${fastq_files[0]} to reference genome index"

    input:
        each fastq_files
        path index_path

    output:
        path "${fastq_files[0]}.bam"
    
    script:
    """
    #!/usr/bin/env bash
    echo "Mapping computation for ${fastq_files[0]}..."
    STAR  --runThreadN ${task.cpus} \
    	  --outFilterMultimapNmax 10 \
    	  --genomeDir ${index_path} \
    	  --readFilesIn ${fastq_files[1][0]} ${fastq_files[1][1]} \
    	  --outSAMtype BAM SortedByCoordinate
    mv Aligned.sortedByCoord.out.bam ${fastq_files[0]}.bam
    echo "Done for ${fastq_files[0]}"
    """
}

process Counting {
    /*
	Create the counting matrix for the RNA-seq data.

    arguments:
    ---------
        annotation_path: a path, pointing to the annotation gtf file
        bam_files: a list of paths, each pointing to a BAM file

    output:
    ------
        path: a path to counting file generated by featureCounts (subread)

    params:
    ------
        params.counting_cpus: an integer, specifying the number of threads to be used
                           whilst creating the counting file.
    */


    cpus params.counting_cpus
    tag "Counting the number of reads per gene"

    input:
    path annotation_path
    path bam_files

    output:
    path "counts.txt"

    script:
    """
    #!/usr/bin/env bash
    featureCounts -p -T ${params.counting_cpus} -t gene -g gene_id -s 0 -a ${annotation_path} -o counts.txt ${bam_files}
    """

}

process DESeq {

    input:
    path DESeq_path
    path counting_path
    path metadata_path

    output:
    path "Figures"

    script:
    """
    mkdir Figures
    Rscript --vanilla ${DESeq_path} "${counting_path}" "${metadata_path}"
    """

}

workflow RNASeq_quant {

    emit:
    counting_path

    main:
    // Download RNA-seq data (fastq files / SRA accession numbers)
    ids = Channel.fromList(params.ids)
    fastq_files = (
        params.reads == null ?
        Fasterq(ids) :
        Channel.fromFilePairs("${params.reads}/SRR*_{1,2}.fastq*", checkIfExists:true)
    )

    // Download genome and annotations
    if (params.genome == null) {
    	Genome(params.genome_url, params.annotation_url)
        path_genome = Genome.out[0]
        path_annotation = Genome.out[1]
    } else {
    	Channel
            .fromPath("${params.genome}/*.fa", checkIfExists: true)
            .set{ path_genome }
    	Channel
            .fromPath("${params.genome}/*.gtf", checkIfExists: true)
            .set{ path_annotation }
    }

    // Create genome index
    path_index = (
        params.index == null ?
        Index(path_genome, path_annotation) :
        Channel.fromPath("${params.index}", checkIfExists:true)
    )

    // Create Bam files
    mapping_path = (
        params.mapping == null ?
        Mapping(fastq_files, path_index) :
        Channel.fromPath("${params.mapping}/*.bam", checkIfExists:true)
    )

    // Create counting matrix
    mapping_path.toSortedList().view()
//    mapping_path.toList().view()
//    sub = { it.substring(5, 19) }

// println list.collect({sub})
    counting_path = Counting(path_annotation,mapping_path.toSortedList())

}

workflow RNASeq_analysis {

    take:
    counting_path

    emit:
    figures_path

    main:
    // Peform RNASeq analysis
    deseq_path = Channel.fromPath("templates/differential_analysis.R")
    metadata_path = (
        params.metadata == null ?
        Channel.fromPath("SraRunTable.txt") :
        Channel.fromPath(params.metadata)
    )
    figures_path = DESeq(deseq_path, counting_path, metadata_path)

}


workflow {
    
    counting_path = (
        params.counting == null ?
        RNASeq_quant() :
        Channel.fromPath("${params.counting}", checkIfExists:true)
    )
    
    // figure_path = RNASeq_analysis(counting_path)
    // figure_path.view()

}

// nextflow run main.nf --counting ../Data/Counts/counts.txt
