#!/usr/bin/env python3

import os
import re
import sys
import math
import tempfile
import itertools
import pandas as pd
from snake_setup import set_config, load_samples, get_grouping, load_regions, get_allele_groupings, load_coords

BASE = workflow.basedir

# Define path to conda environment specifications
ENVS = f'{BASE}/workflow/envs'
# Defne path to custom scripts directory
SCRIPTS = f'{BASE}/workflow/scripts'

if not config:
    configfile: f'{BASE}/config/config.yaml'

# Defaults configuration file - use empty string to represent no default value.
default_config = {
    'workdir':           workflow.basedir,
    'tmpdir':            tempfile.gettempdir(),
    'threads':           workflow.cores,
    'data':              ''          ,
    'phased_vcf':        None        ,
    'genome':            ''          ,
    'bigWig':            {}          ,
    'bed':               {}          ,
    'regions':           ''          ,
    'cutadapt':
        {'forwardAdapter': 'AGATCGGAAGAGCACACGTCTGAACTCCAGTCA',
         'reverseAdapter': 'AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT',
         'overlap':         3                                 ,
         'errorRate':       0.1                               ,
         'minimumLength':   0                                 ,
         'qualityCutoff':  '0,0'                              ,
         'GCcontent':       50                                ,},
    'restrictionSeqs':      ''      ,
    'HiCParams':
        {'minDistance':          300  ,
         'maxLibraryInsertSize': 1000 ,
         'removeSelfLigation':   True ,
         'keepSelfCircles':      False,
         'skipDuplicationCheck': False,
         'nofill':               False,},
    'HiCcompare':
        {'fdr' :         0.05         ,
         'logFC' :       1            ,
         'multi' :       False        ,},
    'compareMatrices':
        {'vMin' :        -2.5         ,
         'vMax' :        2.5          ,
         'size':         1            ,},
    'gatk':
        {'true_snp1' :   None         ,
         'true_snp2' :   None         ,
         'nontrue_snp' : None         ,
         'known' :       None         ,
         'true_indel' :  None         ,
         'known' :       None         ,
         'all_known':    None         ,},
    'binsize':           [5000, 10000],
    'plot_coordinates':  None,
    'fastq_screen':      None,
    'phase':             True,
    'createValidBam':    False,
    'colourmap':         'Purples',
    'multiQCconfig':     None,
    'groupJobs':         False,
}

config = set_config(config, default_config)

workdir: config['workdir']
THREADS = config['threads']
READS = ['R1', 'R2']
BINS = config['binsize']
BASE_BIN = BINS[0]

# Read path to samples in pandas
samples = load_samples(config['data'])

# Extract groups and replicates.
ORIGINAL_SAMPLES, ORIGINAL_GROUPS, CELL_TYPES = get_grouping(samples)

REGIONS = load_regions(config['regions'])

if config['phased_vcf']:
    GROUPS, SAMPLES = get_allele_groupings(ORIGINAL_SAMPLES)
    ALLELE_SPECIFIC = True
else:
    SAMPLES = ORIGINAL_SAMPLES
    GROUPS = ORIGINAL_GROUPS
    ALLELE_SPECIFIC = False

if config['phase'] and not ALLELE_SPECIFIC:
    if config['gatk']['all_known']:
        PHASE_MODE = 'GATK'
    else:
        PHASE_MODE = 'BCFTOOLS'
    phase = [expand('phasedVCFs/{cell_type}-phased.vcf',
        cell_type=list(CELL_TYPES))]
else:
    phase = []
    PHASE_MODE = None

wildcard_constraints:
    cell_type = rf'{"|".join(CELL_TYPES)}',
    pre_group = rf'{"|".join(ORIGINAL_GROUPS)}',
    pre_sample = rf'{"|".join(ORIGINAL_SAMPLES)}',
    region = rf'{"|".join(REGIONS.index)}',
    allele = r'[12]',
    rep = r'\d+',
    read = r'R[12]',
    bin = r'\d+',
    mode = r'SNP|INDEL',
    set = r'logFC|sig|fdr',
    compare = r'HiCcompare|multiHiCcompare',
    group = rf'{"|".join(GROUPS)}',
    group1 = rf'{"|".join(GROUPS)}',
    group2 = rf'{"|".join(GROUPS)}',
    sample = rf'{"|".join(SAMPLES)}',
    all = rf'{"|".join(SAMPLES + list(GROUPS))}'

# Generate list of group comparisons - this avoids self comparison
COMPARES = [f'{i[0]}-vs-{i[1]}' for i in itertools.combinations(list(GROUPS), 2)]

# Generate dictionary of plot coordinates, may be multple per region
COORDS = load_coords([config['plot_coordinates'], config['regions']])

preQC_mode = ['qc/multiqc', 'qc/filterQC/ditag_length.png',
              'qc/fastqc/.tmp.aggregateFastqc',
              'qc/samtools/.tmp.aggregateSamtoolsQC']
HiC_mode = [expand('qc/hicrep/.tmp.{region}-{bin}-hicrep',
                region=REGIONS.index, bin=BINS),
            'qc/hicup/.tmp.aggregatehicupTruncate',
            expand('plots/{region}/{bin}/.tmp.aggregateProcessHiC',
                region=REGIONS.index, bin=BINS)]

# Create a per-sample BAM, for each sample, of only valid HiC reads
if config['createValidBam']:
    validBAM = [expand('dat/mapped/{sample}-validHiC.bam', sample=SAMPLES)]
else:
    validBAM = []

rule all:
    input:
        preQC_mode,
        HiC_mode,
        phase,
        validBAM

if ALLELE_SPECIFIC:
    rule maskPhased:
        input:
            genome = lambda wc: config['genome'][wc.cell_type],
            vcf = lambda wc: config['phased_vcf'][wc.cell_type]
        output:
            'dat/genome/masked/{cell_type}.fa'
        group:
            'prepareGenome'
        log:
            'logs/maskPhased/{cell_type}.log'
        conda:
            f'{ENVS}/bedtools.yaml'
        shell:
            'bedtools maskfasta -fullHeader '
            '-fi <(zcat -f {input.genome}) '
            '-bed {input.vcf} -fo {output} 2> {log}'


rule vcf2SNPsplit:
    input:
        lambda wc: config['phased_vcf'][wc.cell_type]
    output:
        'snpsplit/{cell_type}-snpsplit.txt'
    log:
        'logs/vcf2SNPsplit/{cell_type}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/reformatSNPsplit.py {input} > {output} 2> {log}'


rule bgzipGenome:
    input:
        lambda wc: config['genome'][wc.cell_type]
    output:
        'dat/genome/{cell_type}.fa.gz'
    group:
        'prepareGenome'
    log:
        'logs/bgzipGenome/{cell_type}.log'
    conda:
        f'{ENVS}/tabix.yaml'
    shell:
        '(zcat -f {input} | bgzip > {output}) 2> {log}'


rule indexGenome:
    input:
        rules.bgzipGenome.output
    output:
        f'{rules.bgzipGenome.output}.fai'
    group:
        'prepareGenome'
    log:
        'logs/indexGenome/{cell_type}-indexGenome.log'
    conda:
        f'{ENVS}/samtools.yaml'
    shell:
        'samtools faidx {input} &> {log}'


rule getChromSizes:
    input:
        rules.indexGenome.output
    output:
        'dat/genome/chrom_sizes/{cell_type}.chrom.sizes'
    group:
        'prepareGenome'
    log:
        'logs/getChromSizes/{cell_type}.log'
    shell:
        'cut -f 1,2 {input} > {output} 2> {log}'


def bowtie2BuildInput(wildcards):
    if ALLELE_SPECIFIC:
        return rules.maskPhased.output
    else:
        return rules.bgzipGenome.output


rule bowtie2Build:
    input:
        bowtie2BuildInput
    output:
        expand('dat/genome/index/{{cell_type}}.{n}.bt2',
               n=['1', '2', '3', '4', 'rev.1', 'rev.2'])
    params:
        basename = lambda wc: f'dat/genome/index/{wc.cell_type}'
    group:
        'prepareGenome'
    log:
        'logs/bowtie2Build/{cell_type}.log'
    conda:
        f'{ENVS}/bowtie2.yaml'
    threads:
        THREADS
    shell:
        'bowtie2-build --threads {threads} {input} {params.basename} &> {log}'


rule fastQC:
    input:
        lambda wc: samples.xs(wc.single, level=3)['path']
    output:
        html = 'qc/fastqc/{single}.raw_fastqc.html',
        zip = 'qc/fastqc/unmod/{single}.raw.fastqc.zip'
    group:
        'fastqc'
    log:
        'logs/fastqc/{single}.log'
    wrapper:
        '0.49.0/bio/fastqc'


rule reformatFastQC:
    input:
        'qc/fastqc/unmod/{single}.raw.fastqc.zip'
    output:
        'qc/fastqc/{single}.raw_fastqc.zip'
    group:
        'fastqc'
    log:
        'logs/reformatFastQC/{single}.raw.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/modifyFastQC.py {input} {output} '
        '{wildcards.single} &> {log}'


rule fastQCTrimmed:
    input:
        'dat/fastq/trimmed/{single}.trim.fastq.gz'
    output:
        html = 'qc/fastqc/{single}.trim_fastqc.html',
        zip = 'qc/fastqc/{single}.trim_fastqc.zip'
    group:
        'fastqc'
    log:
        'logs/fastqc_trimmed/{single}.log'
    wrapper:
        '0.49.0/bio/fastqc'


rule aggregateFastqc:
    input:
        expand('qc/fastqc/{sample}-{read}.{type}_fastqc.zip',
            sample=ORIGINAL_SAMPLES, read=READS, type=['trim', 'raw'])
    output:
        touch(temp('qc/fastqc/.tmp.aggregateFastqc'))
    group:
        'fastqc' if config['groupJobs'] else 'aggregateTarget'


if config['fastq_screen'] is not None:

    rule fastQScreen:
        input:
            'dat/fastq/trimmed/{single}.trim.fastq.gz'
        output:
            txt = 'qc/fastq_screen/{single}.fastq_screen.txt',
            png = 'qc/fastq_screen/{single}.fastq_screen.png'
        params:
            fastq_screen_config = config['fastq_screen'],
            subset = 100000,
            aligner = 'bowtie2'
        log:
            'logs/fastq_screen/{single}.log'
        threads:
            THREADS
        wrapper:
            "0.60.0/bio/fastq_screen"


rule cutadapt:
    input:
        lambda wc: samples.xs(wc.pre_sample, level=2)['path']
    output:
        trimmed = ['dat/fastq/trimmed/{pre_sample}-R1.trim.fastq.gz',
                   'dat/fastq/trimmed/{pre_sample}-R2.trim.fastq.gz'],
        qc = 'qc/cutadapt/unmod/{pre_sample}.cutadapt.txt'
    group:
        'cutadapt'
    params:
        forwardAdapter = config['cutadapt']['forwardAdapter'],
        reverseAdapter = config['cutadapt']['reverseAdapter'],
        overlap = config['cutadapt']['overlap'],
        errorRate = config['cutadapt']['errorRate'],
        minimumLength = config['cutadapt']['minimumLength'],
        qualityCutoff = config['cutadapt']['qualityCutoff'],
        GCcontent = config['cutadapt']['GCcontent']
    log:
        'logs/cutadapt/{pre_sample}.log'
    conda:
        f'{ENVS}/cutadapt.yaml'
    threads:
        THREADS
    shell:
        'cutadapt -a {params.forwardAdapter} -A {params.reverseAdapter} '
        '--overlap {params.overlap} --error-rate {params.errorRate} '
        '--minimum-length {params.minimumLength} '
        '--quality-cutoff {params.qualityCutoff} '
        '--gc-content {params.GCcontent} --cores {threads} '
        '-o {output.trimmed[0]} -p {output.trimmed[1]} {input} '
        '> {output.qc} 2> {log}'


rule reformatCutadapt:
    input:
        rules.cutadapt.output.qc
    output:
        'qc/cutadapt/{pre_sample}.cutadapt.txt'
    group:
        'cutadapt'
    log:
        'logs/reformatCutadapt/{pre_sample}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/modifyCutadapt.py {wildcards.pre_sample} {input} '
        '> {output} 2> {log}'


rule hicupTruncate:
    input:
        rules.cutadapt.output.trimmed
    output:
        truncated = ['dat/fastq/truncated/{pre_sample}-R1.trunc.fastq.gz',
                     'dat/fastq/truncated/{pre_sample}-R2.trunc.fastq.gz'],
        summary = 'qc/hicup/{pre_sample}-truncate-summary.txt'
    params:
        re1 = list(config['restrictionSeqs'].values())[0],
        fill = '--nofill' if config['HiCParams']['nofill'] else ''
    group:
        'hicupTruncate'
    threads:
        2 if THREADS > 2 else THREADS
    log:
        'logs/hicupTruncate/{pre_sample}.log'
    conda:
        f'{ENVS}/hicup.yaml'
    shell:
        '{SCRIPTS}/hicup/hicupTruncate.py {params.fill} '
        '--output {output.truncated} '
        '--summary {output.summary} '
        '--re1 {params.re1} '
        '--threads {threads} {input} &> {log}'


rule aggregatehicupTruncate:
    input:
        expand('qc/hicup/{sample}-truncate-summary.txt',
            sample=ORIGINAL_SAMPLES)
    output:
        touch(temp('qc/hicup/.tmp.aggregatehicupTruncate'))
    group:
        'hicupTruncate' if config['groupJobs'] else 'aggregateTarget'


def bowtie2Index(wildcards):
    """ Retrieve bowtie2 index associated with sample. """

    for cell_type, samples in CELL_TYPES.items():
        if wildcards.pre_sample in samples:
            type = cell_type

    return expand('dat/genome/index/{cell_type}.{n}.bt2',
        cell_type=type, n=['1', '2', '3', '4', 'rev.1', 'rev.2'])


def bowtie2Basename(wildcards):
    """ Retrieve bowtie2 index basename associated with sample. """

    for cell_type, samples in CELL_TYPES.items():
        if wildcards.pre_sample in samples:
            type = cell_type

    return expand('dat/genome/index/{cell_type}', cell_type=type)


def getCellType(wc):
    """ Retrieve cell type associated with sample. """

    for cellType, samples in CELL_TYPES.items():
        if wc.pre_sample in samples:
            return cellType


rule bowtie2:
    input:
        fastq = 'dat/fastq/truncated/{pre_sample}-{read}.trunc.fastq.gz',
        bt2_index = bowtie2Index
    output:
        sam = pipe('mapped/{pre_sample}-{read}.sam'),
        qc = 'qc/bowtie2/{pre_sample}-{read}.bowtie2.txt'
    params:
        index = bowtie2Basename,
        cellType = getCellType
    group:
        'bowtie2'
    log:
        'logs/bowtie2/{pre_sample}-{read}.log'
    conda:
        f'{ENVS}/bowtie2.yaml'
    threads:
        THREADS - 1 if THREADS > 1 else 1
    shell:
        'bowtie2 -x {params.index} -U {input.fastq} '
        '--reorder --rg-id {params.cellType} --threads {threads} '
        '--very-fast > {output.sam} 2> {log} && cp {log} {output.qc}'


rule addReadFlag:
    input:
        rules.bowtie2.output.sam
    output:
        'mapped/{pre_sample}-{read}-addFlag.sam'
    params:
        flag = lambda wc: '0x41' if wc.read == 'R1' else '0x81'
    group:
        'bowtie2'
    log:
        'logs/addReadFlag/{pre_sample}-{read}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    shell:
        '{SCRIPTS}/addReadFlag.awk -v flag={params.flag} {input} '
        '> {output} 2> {log}'


rule mergeBam:
    input:
        'mapped/{pre_sample}-R1-addFlag.sam',
        'mapped/{pre_sample}-R2-addFlag.sam'
    output:
        pipe('mapped/{pre_sample}-merged.bam')
    group:
        'prepareBAM'
    log:
        'logs/collateBam/{pre_sample}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    shell:
        'samtools merge -nu {output} {input} &> {log}'

# Input to SNPsplit
rule fixmateBam:
    input:
        rules.mergeBam.output
    output:
        'dat/mapped/{pre_sample}.fixed.bam'
    group:
        'prepareBAM'
    log:
        'logs/fixmateBam/{pre_sample}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    threads:
        THREADS - 1 if THREADS > 1 else 1
    shell:
        'samtools fixmate -@ {threads} -mp {input} {output} 2> {log}'


def SNPsplit_input(wildcards):
    """ Retrieve cell type associated with sample. """

    for cell_type, samples in CELL_TYPES.items():
        if wildcards.pre_sample in samples:
            type = cell_type

    return f'snpsplit/{type}-snpsplit.txt'


rule SNPsplit:
    input:
        bam = rules.fixmateBam.output,
        snps = SNPsplit_input
    output:
        expand('snpsplit/{{pre_sample}}.pair.{ext}',
            ext = ['G1_G1.bam', 'G1_G2.bam', 'G1_UA.bam', 'G2_G2.bam',
                   'G2_UA.bam', 'SNPsplit_report.txt', 'SNPsplit_sort.txt',
                   'UA_UA.bam', 'allele_flagged.bam'])
    params:
        outdir = 'snpsplit/'
    group:
        'SNPsplit'
    log:
        'logs/SNPsplit/SNPsplit-{pre_sample}.log'
    conda:
        f'{ENVS}/snpsplit.yaml'
    shell:
        'SNPsplit {input.bam} --snp_file {input.snps} '
        '--hic --output_dir {params.outdir} &> {log}'


rule mergeSNPsplit:
    input:
        'snpsplit/{pre_group}-{rep}.dedup.G{allele}_G{allele}.bam',
        'snpsplit/{pre_group}-{rep}.dedup.G{allele}_UA.bam'
    output:
        'snpsplit/merged/{pre_group}_a{allele}-{rep}.pair.bam'
    group:
        'SNPsplit'
    log:
        'logs/mergeSNPsplit/{pre_group}_a{allele}-{rep}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    shell:
        'samtools merge -n {output} {input} &> {log}'


def splitInput(wc):
    if ALLELE_SPECIFIC:
        return 'snpsplit/merged/{sample}.pair.bam'
    else:
        return 'dat/mapped/{sample}.fixed.bam'


rule splitPairedReads:
    input:
        splitInput
    output:
        'dat/mapped/split/{sample}-{read}.bam'
    params:
        flag = lambda wc: '0x40' if wc.read == 'R1' else '0x80'
    group:
        'prepareBAM'
    log:
        'logs/splitPairedReads/{sample}-{read}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    threads:
        THREADS
    shell:
        'samtools view -@ {threads} -f {params.flag} -b {input} '
        '> {output} 2> {log}'


rule findRestSites:
    input:
        rules.bgzipGenome.output
    output:
        'dat/genome/{cell_type}-{re}-restSites.bed'
    params:
        reSeq = lambda wc: config['restrictionSeqs'][wc.re].replace('^', '')
    group:
        'prepareBAM'
    log:
        'logs/findRestSites/{cell_type}-{re}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicFindRestSite --fasta {input} --searchPattern {params.reSeq} '
        '--outFile {output} &> {log}'


def getRestSites(wildcards):
    """ Retrieve restSite files associated with sample. """

    for cell_type, samples in CELL_TYPES.items():
        if ALLELE_SPECIFIC:
            groups, samples = get_allele_groupings(samples)
        if wildcards.sample in samples:
            type = cell_type
            break

    return expand('dat/genome/{cell_type}-{re}-restSites.bed',
        cell_type=type, re=config['restrictionSeqs'].keys())


def getRestrictionSeqs(wc):
    enzymes = ''
    for enzyme in config['restrictionSeqs'].values():
        enzyme = enzyme.replace('^', '')
        enzymes += f'{enzyme} '
    return enzymes


def getDanglingSequences(wc):
    danglingSequences = ''
    for enzyme in config['restrictionSeqs'].values():
        sequence = enzyme.replace('^', '')
        cutIndex = enzyme.index('^')
        danglingSequence = sequence[cutIndex:len(sequence) - cutIndex]
        danglingSequences += f'{danglingSequence} '
    return danglingSequences


rule buildBaseMatrix:
    input:
        bams = expand('dat/mapped/split/{{sample}}-{read}.bam', read=READS),
        restSites = getRestSites
    output:
        hic = f'dat/matrix/{{region}}/base/raw/{{sample}}-{{region}}.{BASE_BIN}.h5',
        bam = 'dat/matrix/{region}/{sample}-{region}.bam',
        qc = directory(f'qc/hicexplorer/{{sample}}-{{region}}.{BASE_BIN}_QC')
    params:
        bin = BASE_BIN,
        region = REGIONS.index,
        chr = lambda wc: REGIONS['chr'][wc.region],
        start = lambda wc: REGIONS['start'][wc.region] + 1,
        end = lambda wc: REGIONS['end'][wc.region],
        reSeqs = getRestrictionSeqs,
        danglingSequences = getDanglingSequences,
        maxLibraryInsertSize = config['HiCParams']['maxLibraryInsertSize'],
        minDistance = config['HiCParams']['minDistance'],
        removeSelfLigation = (
            'True' if config['HiCParams']['removeSelfLigation'] else 'False'),
        keepSelfCircles = (
            '--keepSelfCircles' if config['HiCParams']['keepSelfCircles'] else ''),
        skipDuplicationCheck = (
            '--skipDuplicationCheck' if config['HiCParams']['skipDuplicationCheck'] else '')
    log:
        'logs/buildBaseMatrix/{sample}-{region}.log'
    threads:
        4 if THREADS > 4 else THREADS
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicBuildMatrix --samFiles {input.bams} '
        '--region {params.chr}:{params.start}-{params.end} '
        '--restrictionCutFile {input.restSites} '
        '--restrictionSequence {params.reSeqs} '
        '--maxLibraryInsertSize {params.maxLibraryInsertSize} '
        '--minDistance {params.minDistance} '
        '--removeSelfLigation {params.removeSelfLigation} '
        '--danglingSequence {params.danglingSequences} '
        '{params.keepSelfCircles} '
        '{params.skipDuplicationCheck} --binSize {params.bin} '
        '--outFileName {output.hic} --outBam {output.bam} '
        '--QCfolder {output.qc} --threads {threads} '
        '&> {log}  || mkdir -p {output.qc}; touch {output.hic} {output.bam}'


rule mergeValidHiC:
    input:
        expand('dat/matrix/{region}/{{sample}}-{region}.bam',
            region=REGIONS.index)
    output:
        'dat/mapped/{sample}-validHiC.bam'
    log:
        'logs/mergeValidHiC/{sample}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    threads:
        THREADS
    shell:
        'samtools merge -@ {threads} {output} {input} 2> {log}'


rule mergeBins:
    input:
        f'dat/matrix/{{region}}/base/raw/{{sample}}-{{region}}.{BASE_BIN}.h5'
    output:
        'dat/matrix/{region}/{bin}/raw/{sample}-{region}-{bin}.h5'
    params:
        bin = config['binsize'],
        nbins = lambda wildcards: int(int(wildcards.bin) / BASE_BIN)
    group:
        'processHiC' if config['groupJobs'] else 'mergeBins'
    log:
        'logs/mergeBins/{sample}-{region}-{bin}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicMergeMatrixBins --matrix {input} --numBins {params.nbins} '
        '--outFileName {output} &> {log} || touch {output}'


rule readCountNormalise:
    input:
        expand('dat/matrix/{{region}}/{{bin}}/raw/{sample}-{{region}}-{{bin}}.h5',
               sample=SAMPLES)
    output:
        expand('dat/matrix/{{region}}/{{bin}}/norm/{sample}-{{region}}-{{bin}}.h5',
               sample=SAMPLES)
    params:
        method = 'smallest'
    group:
        'processHiC' if config['groupJobs'] else 'readCountNormalise'
    log:
        'logs/readCountNormalise/{region}-{bin}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicNormalize --matrices {input} --setToZeroThreshold 1.0 '
        '--outFileName {output} --normalize {params.method} '
        '&> {log} || touch {output} '


rule sumReplicates:
    input:
        lambda wildcards: expand(
            'dat/matrix/{{region}}/{{bin}}/norm/{group}-{rep}-{{region}}-{{bin}}.h5',
            group=wildcards.group, rep=GROUPS[wildcards.group])
    output:
        'dat/matrix/{region}/{bin}/norm/{group}-{region}-{bin}.h5'
    group:
        'processHiC' if config['groupJobs'] else 'sumReplicates'
    log:
        'logs/sumReplicates/{group}-{bin}-{region}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicSumMatrices --matrices {input} --outFileName {output} '
        '&> {log} || touch {output}'


rule IceMatrix:
    input:
        'dat/matrix/{region}/{bin}/norm/{all}-{region}-{bin}.h5'
    output:
        plot = 'qc/IceMatrix/{all}-{region}-{bin}-diagnosic_plot.png',
        matrix = 'dat/matrix/{region}/{bin}/ice/{all}-{region}-{bin}.h5'
    params:
        iternum = 1000,
        upper_threshold = 5
    group:
        'processHiC' if config['groupJobs'] else 'IceMatrix'
    log:
        'logs/IceMatrix/{all}-{region}-{bin}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        '{SCRIPTS}/hicCorrect.sh -p {output.plot} '
        '-o {output.matrix} -u {params.upper_threshold} '
        '-i {params.iternum} {input} &> {log} || touch {output}'


rule distanceNormalise:
    input:
        rules.IceMatrix.output.matrix
    output:
        'dat/matrix/{region}/{bin}/ice/obs_exp/{all}-{region}-{bin}.h5'
    params:
        method = 'obs_exp'
    group:
        'processHiC' if config['groupJobs'] else 'distanceNormalise'
    log:
        'logs/distanceNormalise/{all}-{region}-{bin}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicTransform -m {input} --method {params.method} -o {output} '
        '&> {log} || touch {output}'


rule plotMatrix:
    input:
        rules.distanceNormalise.output
    output:
        'plots/{region}/{bin}/obs_exp/{all}-{region}-{bin}.png'
    params:
        chr = lambda wc: REGIONS['chr'][wc.region],
        start = lambda wc: REGIONS['start'][wc.region] + 1,
        end = lambda wc: REGIONS['end'][wc.region],
        title = '"{all} : {region} at {bin} bin size"',
        dpi = 600,
        colour = 'YlGn'
    group:
        'processHiC' if config['groupJobs'] else 'plotMatrix'
    log:
        'logs/plotMatrix/{all}-{region}-{bin}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicPlotMatrix --matrix {input} '
        '--outFileName {output} '
        '--region {params.chr}:{params.start}-{params.end} '
        '--colorMap {params.colour} '
        '--title {params.title} '
        '--vMin 0 --vMax 2 --dpi {params.dpi} '
        '&> {log} || touch {output}'


rule TadInsulation:
    input:
        rules.IceMatrix.output.matrix
    output:
        expand(
            'dat/matrix/{{region}}/{{bin}}/tads/{{all}}-{{region}}-{{bin}}{ext}',
            ext = ['_boundaries.bed', '_boundaries.gff', '_domains.bed',
                   '_score.bedgraph', '_zscore_matrix.h5']),
        score = 'dat/matrix/{region}/{bin}/tads/{all}-{region}-{bin}_tad_score.bm'
    params:
        method = 'fdr',
        bin = lambda wc: wc.bin,
        region = lambda wc: wc.region,
        all = lambda wc: wc.all,
        min_depth = lambda wc: int(wc.bin) * 3,
        max_depth = lambda wc: int(wc.bin) * 10,
        prefix = 'dat/matrix/{region}/{bin}/tads/{all}-{region}-{bin}'
    group:
        'processHiC' if config['groupJobs'] else 'TadInsulation'
    threads:
        THREADS
    log:
        'logs/TadInsulation/{all}-{region}-{bin}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicFindTADs --matrix {input} '
        '--minDepth {params.min_depth} --maxDepth {params.max_depth} '
        '--step {wildcards.bin} --outPrefix {params.prefix} '
        '--correctForMultipleTesting {params.method} '
        '--numberOfProcessors {threads} &> {log} || touch {output}'


rule detectLoops:
    input:
        rules.IceMatrix.output.matrix
    output:
        'dat/matrix/{region}/{bin}/loops/{all}-{region}-{bin}.bedgraph'
    params:
        minLoop = 5000,
        maxLoop = 1000000,
        windowSize = 10,
        peakWidth = 6,
        pValuePre = 0.05,
        pValue = 0.05,
        peakInter = 5
    group:
        'processHiC' if config['groupJobs'] else 'detectLoops'
    log:
        'logs/detectLoops/{all}-{region}-{bin}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    threads:
        THREADS
    shell:
        'hicDetectLoops --matrix {input} --outFileName {output} '
        '--minLoopDistance {params.minLoop} '
        '--maxLoopDistance {params.maxLoop} '
        '--windowSize {params.windowSize} '
        '--peakWidth {params.peakWidth} '
        '--pValuePreselection {params.pValuePre} '
        '--pValue {params.pValue} '
        '--peakInteractionsThreshold {params.peakInter} '
        '--threads {threads} '
        '&> {log} || touch {output} && touch {output} '


rule hicPCA:
    input:
        rules.IceMatrix.output.matrix
    output:
        'dat/matrix/{region}/{bin}/PCA/{all}-{region}-{bin}.bedgraph'
    params:
        method = "dist_norm",
        format = 'bedgraph'
    group:
        'processHiC' if config['groupJobs'] else 'hicPCA'
    log:
        'logs/hicPCA/{all}-{region}-{bin}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicPCA --matrix {input} --outputFileName {output} '
        '--format {params.format} '
        '--numberOfEigenvectors 1 --method {params.method} '
        '--ignoreMaskedBins &> {log} || touch {output} && touch {output} '


rule fixBedgraph:
    input:
        rules.hicPCA.output
    output:
        'dat/matrix/{region}/{bin}/PCA/{all}-{region}-{bin}-fix.bedgraph'
    params:
        pos = lambda wc: REGIONS['end'][wc.region]
    group:
        'processHiC' if config['groupJobs'] else 'hicPCA'
    log:
        'logs/fixBedgraph/{all}-{region}-{bin}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/fixBedgraph.py {input} --pos {params.pos} '
        '> {output} 2> {log}'


rule reformatHomer:
    input:
        'dat/matrix/{region}/{bin}/{method}/{all}-{region}-{bin}.h5'
    output:
        'dat/matrix/{region}/{bin}/{method}/{all}-{region}-{bin}.gz'
    group:
        'processHiC' if config['groupJobs'] else 'reformatMatrices'
    log:
        'logs/reformatHomer/{all}-{region}-{bin}-{method}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicConvertFormat --matrices {input} --outFileName {output} '
        '--inputFormat h5 --outputFormat homer &> {log} || touch {output}'


rule reformatNxN3p:
    input:
        'dat/matrix/{region}/{bin}/raw/{sample}-{region}-{bin}.gz'
    output:
        'dat/matrix/{region}/{bin}/raw/{sample}-{region}-{bin}.nxnp3.tsv'
    params:
        region = REGIONS.index,
    group:
        'processHiC' if config['groupJobs'] else 'reformatMatrices'
    log:
        'logs/reformatNxN3p/{sample}-{region}-{bin}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/reformatNxN3p.py {wildcards.bin} {wildcards.region} '
        '<(zcat {input}) > {output} 2> {log}'


rule HiCRep:
    input:
        expand(
            'dat/matrix/{{region}}/{{bin}}/raw/{sample}-{{region}}-{{bin}}.nxnp3.tsv',
            sample = SAMPLES)
    output:
        'qc/hicrep/{region}-{bin}-hicrep.png'
    params:
        bin = BINS,
        region = REGIONS.index,
        start = lambda wildcards: REGIONS['start'][wildcards.region] + 1,
        end = lambda wildcards: REGIONS['end'][wildcards.region]
    group:
        'HiCRep'
    log:
        'logs/HiCRep/{region}-{bin}.log'
    conda:
        f'{ENVS}/hicrep.yaml'
    shell:
        '{SCRIPTS}/runHiCRep.R {output} {wildcards.bin} '
        '{params.start} {params.end} {input} &> {log}'


rule aggregateHiCRep:
    input:
        expand('qc/hicrep/{region}-{bin}-hicrep.png',
            region=REGIONS.index, bin=BINS)
    output:
        touch(temp('qc/hicrep/.tmp.{region}-{bin}-hicrep'))
    group:
        'HiCRep' if config['groupJobs'] else 'aggregateTarget'


rule reformatNxN:
    input:
        'dat/matrix/{region}/{bin}/ice/{all}-{region}-{bin}.gz'
    output:
        'dat/matrix/{region}/{bin}/ice/{all}-{region}-{bin}.nxn.tsv'
    group:
        'processHiC' if config['groupJobs'] else 'OnTAD'
    log:
        'logs/reformatNxN/{region}/{bin}/{all}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/reformatNxN.py <(zcat {input}) '
        '> {output} 2> {log} || touch {output}'


rule OnTAD:
    input:
        rules.reformatNxN.output
    output:
        bed = 'dat/matrix/{region}/{bin}/tads/{all}-{region}-{bin}-ontad.bed',
        tad = 'dat/matrix/{region}/{bin}/tads/{all}-{region}-{bin}-ontad.tad'
    params:
        bin = BINS,
        region = REGIONS.index,
        chr = lambda wc: re.sub('chr', '', str(REGIONS['chr'][wc.region])),
        length = lambda wc: REGIONS['length'][wc.region],
        outprefix = 'dat/matrix/{region}/{bin}/tads/{all}-{region}-{bin}-ontad'
    group:
        'processHiC' if config['groupJobs'] else 'OnTAD'
    log:
        'logs/OnTAD/{region}/{bin}/{all}.log'
    shell:
        '{SCRIPTS}/OnTAD {input} -o {params.outprefix} -bedout chr{params.chr} '
        '{params.length} {wildcards.bin} &> {log} || touch {output}'


rule reformatLinks:
    input:
        rules.OnTAD.output.bed
    output:
        'dat/matrix/{region}/{bin}/tads/{all}-{region}-{bin}-ontad.links'
    params:
        region = REGIONS.index,
        start = lambda wildcards: REGIONS['start'][wildcards.region]
    group:
        'processHiC' if config['groupJobs'] else 'OnTAD'
    log:
        'logs/reformatLinks/{region}/{bin}/{all}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/reformatLinks.py {params.start} {wildcards.bin} {input} '
        '> {output} 2> {log}'


def getTracks(wc):
    """ Build track command for generate config """
    command = ''
    for title, track in config['bigWig'].items():
        command += f'--bigWig {title},{track} '
    for title, track in config['bed'].items():
        command += f'--bed {title},{track} '
    return command


rule createConfig:
    input:
        matrix = 'dat/matrix/{region}/{bin}/ice/{group}-{region}-{bin}.h5',
        loops = 'dat/matrix/{region}/{bin}/loops/{group}-{region}-{bin}.bedgraph',
        insulations = 'dat/matrix/{region}/{bin}/tads/{group}-{region}-{bin}_tad_score.bm',
        tads = 'dat/matrix/{region}/{bin}/tads/{group}-{region}-{bin}-ontad.links',
        pca = 'dat/matrix/{region}/{bin}/PCA/{group}-{region}-{bin}-fix.bedgraph'
    output:
        'plots/{region}/{bin}/pyGenomeTracks/configs/{group}-{region}-{bin}.ini'
    params:
        tracks = getTracks,
        depth = lambda wc: int(REGIONS['length'][wc.region]),
        colourmap = config['colourmap']
    group:
        'processHiC' if config['groupJobs'] else 'plotHiC'
    conda:
        f'{ENVS}/python3.yaml'
    log:
        'logs/createConfig/{region}/{bin}/{group}.log'
    shell:
        '{SCRIPTS}/generate_config.py --matrix {input.matrix} '#--flip '
        '--insulations {input.insulations} --log '
        '--loops {input.loops} --colourmap {params.colourmap} '
        '--bigWig PCA1,{input.pca} '
        '--tads {input.tads} {params.tracks} '
        '--depth {params.depth} > {output} 2> {log}'


def setRegion(wc):
    """ Replace underscores with : and - for valid --region argument. """
    region = list(wc.coord)
    # Find indices of all underscores
    inds = [i for i,c in enumerate(region) if c == '_']
    # Replace penultimate and last underscore with : and -
    region[inds[-1]] = '-'
    region[inds[-2]] = ':'
    return ''.join(region)


rule plotHiC:
    input:
        rules.createConfig.output
    output:
        'plots/{region}/{bin}/pyGenomeTracks/{group}-{region}-{coord}-{bin}.png'
    params:
        region = setRegion,
        title = '"{group} : {region} at {bin} bin size"',
        dpi = 600
    group:
        'processHiC' if config['groupJobs'] else 'plotHiC'
    conda:
        f'{ENVS}/pygenometracks.yaml'
    log:
        'logs/plotHiC/{region}/{bin}/{group}-{coord}.log'
    threads:
        THREADS
    shell:
        'export NUMEXPR_MAX_THREADS=1; pyGenomeTracks --tracks {input} '
        '--region {params.region} '
        '--outFileName {output} '
        '--title {params.title} '
        '--dpi {params.dpi} &> {log}'


rule mergeBamByReplicate:
    input:
        lambda wildcards: expand(
            'dat/matrix/{{region}}/{group}-{rep}-{{region}}.bam',
            group = wildcards.group, rep = GROUPS[wildcards.group])
    output:
        'dat/matrix/{region}/{group}-{region}.bam'
    log:
        'logs/mergeBamByReplicate/{region}/{group}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    threads:
        THREADS
    shell:
        'samtools merge -@ {threads} {output} {input} 2> {log}'


rule reformatPre:
    input:
        'dat/matrix/{region}/{all}-{region}.bam'
    output:
        'dat/matrix/{region}/base/raw/{all}-{region}.pre.tsv'
    group:
        'bam2hic'
    log:
        'logs/reformatPre/{region}/{all}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    threads:
        THREADS
    shell:
        '(samtools view -@ {threads} {input} '
        '| awk -f {SCRIPTS}/bam2pre.awk > {output}) 2> {log} '


def getChromSizes(wildcards):
    """ Retrieve chromSizes file associated with group or sample. """

    for cell_type, samples in CELL_TYPES.items():
        if ALLELE_SPECIFIC:
            groups, samples = get_allele_groupings(samples)
            groups = list(groups) # Get keys from dictionary as list
        else:
            groups = [sample.split('-')[0] for sample in samples]
        all = samples + groups
        if wildcards.all in all:
            type = cell_type
            break

    return expand('dat/genome/chrom_sizes/{cell_type}.chrom.sizes', cell_type=type)


rule juicerPre:
    input:
        tsv = 'dat/matrix/{region}/base/raw/{all}-{region}.pre.tsv',
        chrom_sizes = getChromSizes
    output:
        'UCSCcompatible/{region}/{all}-{region}.hic'
    params:
        chr = lambda wildcards: REGIONS['chr'][wildcards.region],
        resolutions = ','.join([str(bin) for bin in BINS])
    group:
        'bam2hic'
    log:
        'logs/juicerPre/{region}/{all}.log'
    conda:
        f'{ENVS}/openjdk.yaml'
    shell:
        'java -jar {SCRIPTS}/juicer_tools_1.14.08.jar pre '
        '-c {params.chr} -r {params.resolutions} '
        '{input.tsv} {output} {input.chrom_sizes} &> {log}'


# Reform for HiCcompare input
rule straw:
    input:
        rules.juicerPre.output
    output:
        'dat/matrix/{region}/{bin}/{all}-{region}-{bin}-sutm.txt'
    params:
        # Strip 'chr' as juicer removes by default
        chr = lambda wc: re.sub('chr', '', str(REGIONS['chr'][wc.region])),
        start = lambda wc: REGIONS['start'][wc.region],
        end = lambda wc: REGIONS['end'][wc.region]
    group:
        'processHiC' if config['groupJobs'] else 'straw'
    log:
        'logs/straw/{region}/{bin}/{all}.log'
    conda:
        f'{ENVS}/hic-straw.yaml'
    shell:
        '{SCRIPTS}/run-straw.py NONE {input} '
        '{params.chr}:{params.start}:{params.end} '
        '{params.chr}:{params.start}:{params.end} '
        'BP {wildcards.bin} {output} &> {log}'


rule HiCcompare:
    input:
        'dat/matrix/{region}/{bin}/{group1}-{region}-{bin}-sutm.txt',
        'dat/matrix/{region}/{bin}/{group2}-{region}-{bin}-sutm.txt'
    output:
        all = 'dat/HiCcompare/{region}/{bin}/{group1}-vs-{group2}.homer',
        sig = 'dat/HiCcompare/{region}/{bin}/{group1}-vs-{group2}-sig.homer',
        fdr = 'dat/HiCcompare/{region}/{bin}/{group1}-vs-{group2}-fdr.homer',
        links = 'dat/HiCcompare/{region}/{bin}/{group1}-vs-{group2}.links',
        absZ = 'dat/HiCcompare/{region}/{bin}/{group1}-vs-{group2}-absZ.bedgraph'
    params:
        dir = lambda wc: f'dat/HiCcompare/{wc.region}/{wc.bin}',
        qcdir = directory('qc/HiCcompare'),
        chr = lambda wc: REGIONS['chr'][wc.region],
        start = lambda wc: REGIONS['start'][wc.region] + 1,
        end = lambda wc: REGIONS['end'][wc.region],
        fdr = config['HiCcompare']['fdr']
    group:
        'processHiC' if config['groupJobs'] else 'HiCcompare'
    log:
        'logs/HiCcompare/{region}/{bin}/{group1}-vs-{group2}.log'
    conda:
        f'{ENVS}/HiCcompare.yaml'
    shell:
        '{SCRIPTS}/HiCcompare.R {params.dir} {params.qcdir} {params.chr} '
        '{params.start} {params.end} {wildcards.bin} {params.fdr} {input} '
        '&> {log}'


rule multiHiCcompare:
    input:
        group1 = lambda wildcards: expand(
            'dat/matrix/{{region}}/{{bin}}/{group1}-{rep}-{{region}}-{{bin}}-sutm.txt',
            group1=wildcards.group1, rep=GROUPS[wildcards.group1]),
        group2 = lambda wildcards: expand(
            'dat/matrix/{{region}}/{{bin}}/{group2}-{rep}-{{region}}-{{bin}}-sutm.txt',
            group2=wildcards.group2, rep=GROUPS[wildcards.group2])
    output:
        all = 'dat/multiHiCcompare/{region}/{bin}/{group1}-vs-{group2}.homer',
        sig = 'dat/multiHiCcompare/{region}/{bin}/{group1}-vs-{group2}-sig.homer',
        fdr = 'dat/multiHiCcompare/{region}/{bin}/{group1}-vs-{group2}-fdr.homer',
        links = 'dat/multiHiCcompare/{region}/{bin}/{group1}-vs-{group2}.links'
    params:
        dir = lambda wc: f'dat/multiHiCcompare/{wc.region}/{wc.bin}',
        qcdir = directory('qc/multiHiCcompare'),
        chr = lambda wc: REGIONS['chr'][wc.region],
        start = lambda wc: REGIONS['start'][wc.region] + 1,
        end = lambda wc: REGIONS['end'][wc.region],
        fdr = config['HiCcompare']['fdr']
    group:
        'processHiC' if config['groupJobs'] else 'HiCcompare'
    log:
        'logs/multiHiCcompare/{region}/{bin}/{group1}-vs-{group2}.log'
    conda:
        f'{ENVS}/multiHiCcompare.yaml'
    shell:
        '{SCRIPTS}/multiHiCcompare.R {params.dir} {params.qcdir} '
        '{params.chr} {params.start} {params.end} '
        '{wildcards.bin} {params.fdr} '
        '{input.group1} {input.group2} &> {log}'


rule applyMedianFilter:
    input:
        'dat/{compare}/{region}/{bin}/{group1}-vs-{group2}.homer'
    output:
        'dat/{compare}/{region}/{bin}/{group1}-vs-{group2}-logFC.homer'
    params:
        size = config['compareMatrices']['size']
    group:
        'processHiC' if config['groupJobs'] else 'HiCcompare'
    log:
        'logs/applyMedianFilter/{compare}/{region}/{bin}/{group1}-vs-{group2}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/smoothHiC.py {input} --size {params.size} '
        '> {output} 2> {log}'


rule homerToH5:
    input:
        'dat/{compare}/{region}/{bin}/{group1}-vs-{group2}-{set}.homer'
    output:
        'dat/{compare}/{region}/{bin}/{group1}-vs-{group2}-{set}.h5'
    group:
        'processHiC' if config['groupJobs'] else 'HiCcompare'
    log:
        'logs/homerToH5/{compare}/{region}/{bin}/{group1}-vs-{group2}-{set}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        '(hicConvertFormat --matrices {input} --outFileName {output} '
        '--inputFormat homer --outputFormat h5 || touch {output})  &> {log}'


rule filterHiCcompare:
    input:
        'dat/{compare}/{region}/{bin}/{group1}-vs-{group2}.links'
    output:
        up = 'dat/{compare}/{region}/{bin}/{group1}-vs-{group2}-up.links',
        down = 'dat/{compare}/{region}/{bin}/{group1}-vs-{group2}-down.links'
    params:
        p_value = config['HiCcompare']['fdr'],
        log_fc = config['HiCcompare']['logFC'],
    group:
        'processHiC' if config['groupJobs'] else 'HiCcompare'
    log:
        'logs/filterHiCcompare/{compare}/{region}/{bin}/{group1}-vs-{group2}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/filterHiCcompare.py '
        '--up {output.up} --down {output.down} '
        '--p_value {params.p_value} --log_fc {params.log_fc} {input} &> {log}'


rule createCompareConfig:
    input:
        mat = 'dat/{compare}/{region}/{bin}/{group1}-vs-{group2}-{set}.h5',
        absZ = 'dat/HiCcompare/{region}/{bin}/{group1}-vs-{group2}-absZ.bedgraph'
    output:
        'plots/{region}/{bin}/HiCcompare/configs/{group1}-vs-{group2}-{compare}-{set}.ini',
    params:
        depth = lambda wc: int(REGIONS['length'][wc.region]),
        colourmap = 'bwr',
        tracks = getTracks,
        vMin = lambda wc: -1 if wc.set == 'fdr' else config['compareMatrices']['vMin'],
        vMax = lambda wc: 1 if wc.set == 'fdr' else config['compareMatrices']['vMax'],
    group:
        'processHiC' if config['groupJobs'] else 'HiCcompare'
    log:
        'logs/createCompareConfig/{compare}/{region}/{bin}/{group1}-{group2}-{set}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/generate_config.py --matrix {input.mat} --compare '
        '--bigWig absZ,{input.absZ} {params.tracks} '
        '--depth {params.depth} --colourmap {params.colourmap} '
        '--vMin {params.vMin} --vMax {params.vMax} > {output} 2> {log}'


def round_down(wc):
    start = REGIONS['start'][wc.region]
    bin = int(wc.bin)
    return start - (start%bin)


def round_up(wc):
    end = REGIONS['end'][wc.region]
    bin = int(wc.bin)
    return end - (end%bin) + bin


def title(wc):
    title = f'"{wc.group1} vs {wc.group2} - {wc.region} at {wc.bin} bin size - '
    if wc.set == 'sig':
        threshold = config['HiCcompare']['fdr']
        title += f'adj. logFC (FDR <= {threshold})"'
    elif wc.set == 'logFC':
        title += 'adj. logFC"'
    else:
        title += 'FDR"'
    return title

rule plotCompare:
    input:
        rules.createCompareConfig.output
    output:
        'plots/{region}/{bin}/{compare}/{set}/{group1}-vs-{group2}-{region}-{coord}-{bin}-{set}.png'
    params:
        title = title,
        region = setRegion,
        dpi = 600
    group:
        'processHiC' if config['groupJobs'] else 'HiCcompare'
    conda:
        f'{ENVS}/pygenometracks.yaml'
    log:
        'logs/plotAnalysis/{compare}/{region}/{bin}/{group1}-vs-{group2}-{coord}-{set}.log'
    threads:
        THREADS
    shell:
        'export NUMEXPR_MAX_THREADS=1; pyGenomeTracks --tracks {input} '
        '--region {params.region} '
        '--outFileName {output} '
        '--title {params.title} '
        '--dpi {params.dpi} &> {log}'


rule aggregateProcessHiC:
    input:
        lambda wc: expand('plots/{{region}}/{{bin}}/{tool}/{set}/{compare}-{{region}}-{coords}-{{bin}}-{set}.png',
            coords=COORDS[wc.region], compare=COMPARES, set=['logFC', 'sig', 'fdr'],
            tool = ['HiCcompare', 'multiHiCcompare'] if config['HiCcompare']['multi'] else ['HiCcompare']),
        lambda wc: expand('plots/{{region}}/{{bin}}/pyGenomeTracks/{group}-{{region}}-{coords}-{{bin}}.png',
            coords=COORDS[wc.region], group=list(GROUPS)),
        expand('plots/{{region}}/{{bin}}/obs_exp/{all}-{{region}}-{{bin}}.png',
            all=SAMPLES+list(GROUPS))
    output:
        touch(temp('plots/{region}/{bin}/.tmp.aggregateProcessHiC'))
    group:
        'processHiC' if config['groupJobs'] else 'aggregateTarget'


if not ALLELE_SPECIFIC:

    rule sortBam:
        input:
            rules.fixmateBam.output
        output:
            pipe('dat/mapped/{pre_sample}.sorted.bam')
        params:
            mem = '1G'
        threads:
            max(math.ceil(THREADS * 0.5), 1)
        log:
            'logs/sortBam/{pre_sample}.log'
        conda:
            f'{ENVS}/samtools.yaml'
        shell:
            'samtools sort -@ {threads} -O bam,level=0 '
            '-m {params.mem} {input} > {output} 2> {log}'


    rule deduplicate:
        input:
            rules.sortBam.output
        output:
            bam = 'dat/mapped/{pre_sample}.dedup.bam',
            qc = 'qc/deduplicate/{pre_sample}.txt'
        threads:
            max(math.floor(THREADS * 0.5), 1)
        log:
            'logs/deduplicate/{pre_sample}.log'
        conda:
            f'{ENVS}/samtools.yaml'
        shell:
            'samtools markdup -@ {threads} -O bam,level=-1 '
            '-rsf {output.qc} {input} {output.bam} &> {log}'


    rule mergeBamByCellType:
        input:
            lambda wc: expand('dat/mapped/{pre_sample}.dedup.bam',
                pre_sample = CELL_TYPES[wc.cell_type])
        output:
            'dat/mapped/mergeByCell/{cell_type}.merged.bam'
        group:
            'mergeCellType'
        log:
            'logs/mergeBamByCellType/{cell_type}.log'
        conda:
            f'{ENVS}/samtools.yaml'
        threads:
            THREADS
        shell:
            'samtools merge -@ {threads} {output} {input} &> {log}'


    rule indexMergedBam:
        input:
            rules.mergeBamByCellType.output
        output:
            f'{rules.mergeBamByCellType.output}.bai'
        threads:
            THREADS
        log:
            'logs/indexMergedBam/{cell_type}.log'
        conda:
            f'{ENVS}/samtools.yaml'
        shell:
            'samtools index -@ {threads} {input} &> {log}'

    # GATK PHASE MODE #

    rule createSequenceDictionary:
        input:
            rules.bgzipGenome.output
        output:
            'dat/genome/{cell_type}.dict'
        params:
            tmp = config['tmpdir']
        log:
            'logs/gatk/createSequenceDictionary/{cell_type}.log'
        conda:
            f'{ENVS}/picard.yaml'
        shell:
            'picard CreateSequenceDictionary R={input} O={output} '
            'TMP_DIR={params.tmp} &> {log}'


    def known_sites(input_known):
        input_known_string = ""
        if input_known is not None:
            for known in input_known:
                input_known_string += f' --known-sites {known}'
        return input_known_string


    rule baseRecalibrator:
        input:
            bam = rules.mergeBamByCellType.output,
            bam_index = rules.indexMergedBam.output,
            ref = rules.bgzipGenome.output,
            ref_index = rules.indexGenome.output,
            ref_dict = rules.createSequenceDictionary.output
        output:
            recal_table = 'dat/gatk/baseRecalibrator/{cell_type}.recal.table'
        params:
            tmp = config['tmpdir'],
            known = known_sites(config['gatk']['all_known']),
            extra = ''
        log:
            'logs/gatk/baseRecalibrator/{cell_type}.log'
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
             'gatk BaseRecalibrator {params.extra} {params.known} '
             '--input {input.bam} --reference {input.ref} '
             '--output {output.recal_table} '
             '--sequence-dictionary {input.ref_dict} '
             '--tmp-dir {params.tmp} &> {log}'


    rule applyBQSR:
        input:
            bam = rules.mergeBamByCellType.output,
            bam_index = rules.indexMergedBam.output,
            ref = rules.bgzipGenome.output,
            ref_index = rules.indexGenome.output,
            ref_dict = rules.createSequenceDictionary.output,
            recal_table = rules.baseRecalibrator.output
        output:
            'dat/mapped/mergeByCell/{cell_type}.recalibrated.bam'
        params:
            tmp = config['tmpdir'],
            extra = ''
        log:
            'logs/gatk/applyBQSR/{cell_type}.log'
        threads:
            THREADS
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
            'gatk ApplyBQSR {params.extra} '
            '--input {input.bam} --reference {input.ref} '
            '--bqsr-recal-file {input.recal_table} --output {output} '
            '--tmp-dir {params.tmp} &> {log}'


    rule haplotypeCaller:
        input:
            bam = rules.applyBQSR.output,
            bam_index = rules.indexMergedBam.output,
            ref = rules.bgzipGenome.output,
            ref_index = rules.indexGenome.output,
            ref_dict = rules.createSequenceDictionary.output
        output:
            'dat/gatk/split/{cell_type}-{region}-g.vcf.gz'
        params:
            chr = lambda wildcards: REGIONS['chr'][wildcards.region],
            start = lambda wildcards: REGIONS['start'][wildcards.region],
            end = lambda wildcards: REGIONS['end'][wildcards.region],
            intervals = config['regions'],
            java_opts = '-Xmx6G',
            min_prune = 2, # Increase to speed up
            downsample = 50, # Decrease to speed up
            tmp = config['tmpdir'],
            extra = ''
        log:
            'logs/gatk/haplotypeCaller/{cell_type}-{region}.log'
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
            'gatk --java-options {params.java_opts} HaplotypeCaller '
            '{params.extra} --input {input.bam} --output {output} '
            '--max-reads-per-alignment-start {params.downsample} '
            '--min-pruning {params.min_prune} --reference {input.ref} '
            '--intervals {params.chr}:{params.start}-{params.end} '
            '--tmp-dir {params.tmp} -ERC GVCF &> {log}'


    def gatherVCFsInput(wc):
        input = ''
        gvcfs = expand('dat/gatk/split/{cell_type}-{region}-g.vcf.gz',
            region=REGIONS.index, cell_type=wc.cell_type)
        for gvcf in gvcfs:
            input += f' -I {gvcf}'
        return input


    rule gatherVCFs:
        input:
            expand('dat/gatk/split/{{cell_type}}-{region}-g.vcf.gz',
                region=REGIONS.index)
        output:
            'dat/gatk/{cell_type}-g.vcf.gz'
        params:
            gvcfs = gatherVCFsInput,
            java_opts = '-Xmx4G',
            extra = '',  # optional
        log:
            'logs/gatk/gatherGVCFs/{cell_type}.log'
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
             'gatk --java-options {params.java_opts} GatherVcfs '
             '{params.gvcfs} -O {output} &> {log}'


    rule indexFeatureFile:
        input:
            rules.gatherVCFs.output
        output:
            f'{rules.gatherVCFs.output}.tbi'
        params:
            java_opts = '-Xmx4G',
            extra = '',  # optional
        log:
            'logs/gatk/indexFeatureFile/{cell_type}.log'
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
             'gatk --java-options {params.java_opts} IndexFeatureFile '
             '-I {input} &> {log}'


    rule genotypeGVCFs:
        input:
            gvcf = rules.gatherVCFs.output,
            gvcf_idex = rules.indexFeatureFile.output,
            ref = rules.bgzipGenome.output,
            ref_index = rules.indexGenome.output,
            ref_dict = rules.createSequenceDictionary.output
        output:
            'dat/gatk/{cell_type}.vcf.gz'
        params:
            tmp = config['tmpdir'],
            java_opts = '-Xmx4G',
            extra = '',  # optional
        log:
            'logs/gatk/genotypeGVCFs/{cell_type}.log'
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
             'gatk --java-options {params.java_opts} GenotypeGVCFs '
             '--reference {input.ref} --variant {input.gvcf} '
             '--tmp-dir {params.tmp} --output {output} &> {log}'


    rule selectVariants:
        input:
            vcf = rules.genotypeGVCFs.output,
            ref = rules.bgzipGenome.output,
            ref_index = rules.indexGenome.output,
            ref_dict = rules.createSequenceDictionary.output
        output:
            'dat/gatk/{cell_type}-{mode}.vcf.gz'
        params:
            tmp = config['tmpdir']
        log:
            'logs/gatk/selectVariants/{cell_type}-{mode}.log'
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
            'gatk SelectVariants --reference {input.ref} '
            '--variant {input.vcf} --select-type-to-include {wildcards.mode} '
            '--tmp-dir {params.tmp} --output {output} &> {log}'



    rule variantRecalibratorSNPs:
        input:
            vcf = 'dat/gatk/{cell_type}-SNP.vcf.gz',
            ref = rules.bgzipGenome.output,
            ref_index = rules.indexGenome.output,
            ref_dict = rules.createSequenceDictionary.output
        output:
            recal = 'dat/gatk/{cell_type}-SNP.vcf.recal',
            tranches = 'dat/gatk/{cell_type}-SNP.vcf.tranches'
        params:
            tmp = config['tmpdir'],
            true_snp1 = f'--resource:hapmap,known=false,training=true,truth=true,'
            f'prior=15.0 {config["gatk"]["true_snp1"]}' if config["gatk"]["true_snp1"]  else '',
            true_snp2 = f'--resource:omni,known=false,training=true,truth=true,'
            f'prior=12.0 {config["gatk"]["true_snp2"]}' if config["gatk"]["true_snp2"]  else '',
            nontrue_snp = f'--resource:1000G,known=false,training=true,truth=false,'
            f'prior=10.0 {config["gatk"]["nontrue_snp"]}' if config["gatk"]["nontrue_snp"]  else '',
            known = f'--resource:dbsnp,known=true,training=false,truth=false,'
            f'prior=2.0 {config["gatk"]["known"]}' if config["gatk"]["known"]  else '',
            max_gaussians = 3,
            java_opts = '-Xmx4G',
            extra = '',  # optional
        log:
            'logs/gatk/variantRecalibrator/{cell_type}-SNP.log'
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
            'gatk --java-options {params.java_opts} VariantRecalibrator '
            '--reference {input.ref} --variant {input.vcf} --mode SNP '
            '-an QD -an MQ -an MQRankSum -an ReadPosRankSum -an FS -an SOR '
            '--output {output.recal} --tranches-file {output.tranches} '
            '--max-gaussians {params.max_gaussians} '
            '{params.known} {params.true_snp1} {params.true_snp2} '
            '{params.nontrue_snp} {params.extra} '
            '--tmp-dir {params.tmp} &> {log}'


    rule variantRecalibratorINDELS:
        input:
            vcf = 'dat/gatk/{cell_type}-INDEL.vcf.gz',
            ref = rules.bgzipGenome.output,
            ref_index = rules.indexGenome.output,
            ref_dict = rules.createSequenceDictionary.output
        output:
            recal = 'dat/gatk/{cell_type}-INDEL.vcf.recal',
            tranches = 'dat/gatk/{cell_type}-INDEL.vcf.tranches'
        params:
            tmp = config['tmpdir'],
            true_indel = f'--resource:mills,known=false,training=true,truth=true,'
            f'prior=12.0 {config["gatk"]["true_indel"]}' if config["gatk"]["true_indel"]  else '',
            known = f'--resource:dbsnp,known=true,training=false,truth=false,'
            f'prior=2.0 {config["gatk"]["known"]}' if config["gatk"]["known"]  else '',
            max_gaussians = 3,
            java_opts = '-Xmx4G',
            extra = '',  # optional
        log:
            'logs/gatk/variantRecalibrator/{cell_type}-INDEL.log'
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
            'gatk --java-options {params.java_opts} VariantRecalibrator '
            '--reference {input.ref} --variant {input.vcf} --mode INDEL '
            '-an QD -an MQ -an MQRankSum -an ReadPosRankSum -an FS -an SOR '
            '--output {output.recal} --tranches-file {output.tranches} '
            '--max-gaussians {params.max_gaussians} '
            '{params.known} {params.true_indel} {params.extra} '
            '--tmp-dir {params.tmp} &> {log}'

    rule applyVQSR:
        input:
            vcf = rules.selectVariants.output,
            tranches = 'dat/gatk/{cell_type}-{mode}.vcf.tranches',
            recal = 'dat/gatk/{cell_type}-{mode}.vcf.recal',
            ref = rules.bgzipGenome.output,
            ref_index = rules.indexGenome.output,
            ref_dict = rules.createSequenceDictionary.output
        output:
            'dat/gatk/{cell_type}-{mode}.filt.vcf.gz'
        params:
            tmp = config['tmpdir']
        log:
            'logs/gatk/applyVQSR/{cell_type}-{mode}.log'
        conda:
            f'{ENVS}/gatk.yaml'
        shell:
            'gatk ApplyVQSR --reference {input.ref} --variant {input.vcf} '
            '--tranches-file {input.tranches} --mode {wildcards.mode} '
            '--exclude-filtered --recal-file {input.recal} '
            '--truth-sensitivity-filter-level 99.0 '
            '--tmp-dir {params.tmp} --output {output} &> {log}'


    rule mergeVCFs:
        input:
            SNP = 'dat/gatk/{cell_type}-SNP.filt.vcf.gz',
            INDEL = 'dat/gatk/{cell_type}-INDEL.filt.vcf.gz',
        output:
            'dat/gatk/{cell_type}-all.filt.vcf.gz'
        params:
            tmp = config['tmpdir']
        log:
            'logs/picard/merge_vcfs/{cell_type}.log'
        conda:
            f'{ENVS}/picard.yaml'
        shell:
            'picard MergeVcfs INPUT={input.SNP} INPUT={input.INDEL} '
            'TMP_DIR={params.tmp} OUTPUT={output} &> {log}'


    rule splitVCFS:
        input:
            rules.mergeVCFs.output
        output:
            'dat/gatk/{cell_type}-all-{region}.filt.vcf'
        params:
            region = REGIONS.index,
            chr = lambda wildcards: REGIONS['chr'][wildcards.region],
            start = lambda wildcards: REGIONS['start'][wildcards.region] + 1,
            end = lambda wildcards: REGIONS['end'][wildcards.region]
        log:
            'logs/splitVCFS/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/bcftools.yaml'
        shell:
            'bcftools view --regions {params.chr}:{params.start}-{params.end} '
            '{input} > {output} 2> {log}'


    # BCFTOOLS PHASE MODE #

    rule mpileup:
        input:
            bam = rules.mergeBamByCellType.output,
            bam_index = rules.indexMergedBam.output,
            genome = rules.bgzipGenome.output,
        output:
            pipe('dat/bcftools/{region}/{cell_type}-{region}-mpileup.bcf')
        params:
            region = REGIONS.index,
            chr = lambda wildcards: REGIONS['chr'][wildcards.region],
            start = lambda wildcards: REGIONS['start'][wildcards.region] + 1,
            end = lambda wildcards: REGIONS['end'][wildcards.region]
        group:
            'bcftoolsVariants'
        log:
            'logs/mpileup/{region}/{cell_type}.log'
        threads:
            (THREADS - 4) * 0.5
        conda:
            f'{ENVS}/bcftools.yaml'
        shell:
            'bcftools mpileup -q 15 --ignore-RG --count-orphans '
            '--regions {params.chr}:{params.start}-{params.end} '
            '--max-depth 100000 --output-type u -f {input.genome} '
            '--threads {threads} {input.bam} > {output} 2> {log} '


    rule callVariants:
        input:
            rules.mpileup.output
        output:
            pipe('dat/bcftools/{region}/{cell_type}-{region}-calls.bcf')
        group:
            'bcftoolsVariants'
        log:
            'logs/callVariants/{region}/{cell_type}.log'
        threads:
            (THREADS - 4) * 0.5
        conda:
            f'{ENVS}/bcftools.yaml'
        shell:
            'bcftools call --multiallelic-caller --variants-only '
            '--output-type u --threads {threads} '
            '{input} > {output} 2> {log}'


    rule filterVariants:
        input:
            rules.callVariants.output
        output:
            'dat/bcftools/{region}/{cell_type}-{region}.filt.vcf'
        group:
            'bcftoolsVariants'
        log:
            'logs/filterVariants/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/bcftools.yaml'
        shell:
            'bcftools view -i "%QUAL>=20" --output-type v '
            '{input} > {output} 2> {log}'


    def hapCut2Input(wildcards):
        if PHASE_MODE == 'GATK':
            return rules.splitVCFS.output
        else:
            return rules.filterVariants.output


    rule extractHAIRS:
        input:
            vcf = hapCut2Input,
            bam = rules.deduplicate.output.bam
        output:
            'dat/phasing/{region}/{cell_type}-{region}.fragments'
        params:
            region = REGIONS.index,
            chr = lambda wildcards: REGIONS['chr'][wildcards.region],
            start = lambda wildcards: REGIONS['start'][wildcards.region],
            end = lambda wildcards: REGIONS['end'][wildcards.region]
        group:
            'hapcut2'
        log:
            'logs/extractHAIRS/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/hapcut2.yaml'
        shell:
            'extractHAIRS --hic 1 --bam {input.bam} '
            '--region {params.chr}:{params.start}-{params.end} '
            '--VCF {input.vcf} --out {output} &> {log}'


    rule hapCut2:
        input:
            fragments = rules.extractHAIRS.output,
            vcf = hapCut2Input
        output:
            block = 'dat/phasing/{region}/{cell_type}-{region}',
            vcf = 'dat/phasing/{region}/{cell_type}-{region}.phased.VCF'
        group:
            'hapcut2'
        log:
            'logs/hapCut2/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/hapcut2.yaml'
        shell:
            'HAPCUT2 --hic 1 --fragments {input.fragments} '
            '--VCF {input.vcf} --outvcf 1 --out {output.block} &> {log}'


    rule bgzipPhased:
        input:
            rules.hapCut2.output.vcf
        output:
            f'{rules.hapCut2.output.vcf}.gz'
        log:
            'logs/bgzip_phased/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/tabix.yaml'
        shell:
            'bgzip -c {input} > {output} 2> {log}'


    rule indexPhased:
        input:
            rules.bgzipPhased.output
        output:
            f'{rules.bgzipPhased.output}.tbi'
        log:
            'logs/index_phased/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/tabix.yaml'
        shell:
            'tabix {input} &> {log}'


    rule extractBestBlock:
        input:
            rules.hapCut2.output.block
        output:
            'dat/phasing/{region}/{cell_type}-{region}.tsv'
        log:
            'logs/extractBestPhase/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/python3.yaml'
        shell:
            '{SCRIPTS}/extractBestHapcut2.py {input} > {output} 2> {log}'


    rule extractVCF:
        input:
            block = rules.extractBestBlock.output,
            vcf = rules.bgzipPhased.output,
            vcf_index = rules.indexPhased.output
        output:
            'dat/phasing/{region}/{cell_type}-{region}-best.vcf'
        log:
            'logs/extractVCF/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/bcftools.yaml'
        shell:
            'bcftools view -R {input.block} {input.vcf} '
            '> {output} 2> {log} || touch {output}'


    rule bgzipVCF:
        input:
             rules.extractVCF.output
        output:
            f'{rules.extractVCF.output}.gz'
        log:
            'logs/bgzipVCF/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/bcftools.yaml'
        shell:
            'bcftools view -O z {input} > {output} 2> {log} || touch {output}'


    rule indexVCF:
        input:
            rules.bgzipVCF.output
        output:
            f'{rules.bgzipVCF.output}.csi'
        log:
            'logs/indexVCF/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/bcftools.yaml'
        shell:
            'bcftools index -f {input} 2> {log} || touch {output}'


    def validVCFS(wildcards):
        """ Remove empty files which break bcftools concat. """
        VCFs = []
        allVCFs = expand(
            'dat/phasing/{region}/{cell_type}-{region}-best.vcf.gz',
            region=REGIONS.index, cell_type=wildcards.cell_type)
        for vcf in allVCFs:
            if os.path.exists(vcf) and os.path.getsize(vcf) > 0:
                VCFs.append(vcf)
        return VCFs

    def mergeCommand():
        """ Do not run merge with only 1 region. """
        if len(REGIONS) > 1:
            return ('bcftools concat --allow-overlaps {input.vcfs} '
                    '> {output} 2> {log}')
        else:
            return 'bcftools view {input.vcfs} > {output} 2> {log}'


    rule mergeVCFsbyRegion:
        input:
            expand(
                'dat/phasing/{region}/{{cell_type}}-{region}-best.vcf.gz',
                region=REGIONS.index),
            expand(
                'dat/phasing/{region}/{{cell_type}}-{region}-best.vcf.gz.csi',
                region=REGIONS.index),
            vcfs = validVCFS
        output:
            'phasedVCFs/{cell_type}-phased.vcf'
        log:
            'logs/mergeVCFsbyRegion/{cell_type}.log'
        conda:
            f'{ENVS}/bcftools.yaml'
        shell:
            mergeCommand()


    rule bcftoolsStats:
        input:
            rules.filterVariants.output
        output:
            'qc/bcftools/{region}/{cell_type}-{region}-bcftoolsStats.txt'
        group:
            'bcftoolsVariants'
        log:
            'logs/bcftoolsStats/{region}/{cell_type}.log'
        conda:
            f'{ENVS}/bcftools.yaml'
        shell:
            'bcftools stats {input} > {output} 2> {log}'


def multiQCconfig():
    if config['multiQCconfig']:
        return f'--config {config["multiQCconfig"]}'
    else:
        return ''



rule sampleReads:
    input:
        'dat/mapped/{sample}.fixed.bam'
    output:
        'dat/mapped/subsampled/{sample}-subsample.sam'
    group:
        'filterQC'
    params:
        seed = '42',
        frac = '20'
    threads:
        2 if THREADS > 2 else THREADS
    log:
        'logs/sampleReads/{sample}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    shell:
        'samtools view -@ {threads} -s {params.seed}.{params.frac} {input} '
        '> {output} 2> {log}'


rule processHiC:
    input:
        reads = rules.sampleReads.output,
        digest = getRestSites
    output:
        'dat/mapped/subsampled/{sample}-processed.txt'
    group:
        'filterQC'
    log:
        'logs/process/{sample}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/processHiC.py {input.digest} {input.reads} '
        '> {output} 2> {log}'


rule plotQC:
    input:
        expand('dat/mapped/subsampled/{sample}-processed.txt',
            sample=ORIGINAL_SAMPLES)
    output:
        expand('qc/filterQC/{fig}',
               fig=['trans_stats.csv', 'insert_size_frequency.png',
                    'ditag_length.png'])
    params:
        outdir = 'qc/filterQC'
    group:
        'filterQC' if config['groupJobs'] else 'plotQC'
    log:
        'logs/plotQC/plot_subsample.log'
    conda:
        f'{ENVS}/ggplot2.yaml'
    shell:
        '{SCRIPTS}/plotQC.R {params.outdir} {input} 2> {log}'


rule mergeHicupQC:
    input:
        rules.hicupTruncate.output.summary,
    output:
        'qc/hicup/HiCUP_summary_report-{pre_sample}.txt'
    log:
        'logs/mergeHicupQC/{pre_sample}.log'
    conda:
        f'{ENVS}/hicup.yaml'
    shell:
        '{SCRIPTS}/hicup/mergeHicupSummary.py --truncater {input.truncater} '
        '> {output} 2> {log}'


rule multiqc:
    input:
        [expand('qc/fastqc/{sample}-{read}.raw_fastqc.zip',
            sample=ORIGINAL_SAMPLES, read=READS),
         expand('qc/cutadapt/{sample}.cutadapt.txt', sample=ORIGINAL_SAMPLES),
         expand('qc/fastqc/{sample}-{read}.trim_fastqc.zip',
            sample=ORIGINAL_SAMPLES, read=READS),
         expand('qc/hicup/HiCUP_summary_report-{sample}.txt', sample=ORIGINAL_SAMPLES),
         expand('qc/bowtie2/{sample}-{read}.bowtie2.txt',
            sample=ORIGINAL_SAMPLES, read=READS),
         expand('qc/hicexplorer/{sample}-{region}.{bin}_QC',
            sample=SAMPLES, region=REGIONS.index, bin=BASE_BIN),
         expand('qc/fastq_screen/{sample}-{read}.fastq_screen.txt',
            sample=ORIGINAL_SAMPLES, read=READS) if config['fastq_screen'] else [],
         expand('qc/bcftools/{region}/{cell_type}-{region}-bcftoolsStats.txt',
            region=REGIONS.index, cell_type=CELL_TYPES) if PHASE_MODE=='BCFTOOLS' else []]
    output:
        directory('qc/multiqc')
    params:
        config = multiQCconfig()
    log:
        'logs/multiqc/multiqc.log'
    conda:
        f'{ENVS}/multiqc.yaml'
    shell:
        'multiqc --outdir {output} --force {params.config} {input} &> {log}'
