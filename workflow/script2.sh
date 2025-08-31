
# Load required modules
module load chpc/BIOMODULES
module load bwa
module load samtools/1.9
module load trimmomatic/0.39   

# Reference genome
REF="sequence.fasta"
GENOME_LENGTH=29903

# Index reference
bwa index $REF
samtools faidx $REF

# Output directory (avoid writing to / )
OUT_DIR="/results"
mkdir -p $OUT_DIR

FASTQ_DIR="/data"

# Initialize QC summary file
echo -e "Sample\tMappedPct\tBreadth10\tBreadth20\tMedianDepth" > $OUT_DIR/QC_summary.tsv

# Loop over all R1 files
for R1 in ${FASTQ_DIR}/*_1.fastq.gz
do
    R2=${R1/_1.fastq.gz/_2.fastq.gz}
    SAMPLE=$(basename $R1 _1.fastq.gz)

    echo "Processing sample: $SAMPLE"

    # Step 1: Map raw reads
    bwa mem $REF $R1 $R2 > $OUT_DIR/${SAMPLE}.aligned.sam
    samtools view -bS $OUT_DIR/${SAMPLE}.aligned.sam > $OUT_DIR/${SAMPLE}.aligned.bam
    samtools sort -o $OUT_DIR/${SAMPLE}.aligned.sorted.bam $OUT_DIR/${SAMPLE}.aligned.bam
    samtools index $OUT_DIR/${SAMPLE}.aligned.sorted.bam
    rm $OUT_DIR/${SAMPLE}.aligned.sam $OUT_DIR/${SAMPLE}.aligned.bam

    # Step 2: Trimming (only if Trimmomatic is installed)
    if command -v trimmomatic &> /dev/null
    then
        trimmomatic PE -threads 8 \
            $R1 $R2 \
            $OUT_DIR/${SAMPLE}_R1_paired.fastq.gz $OUT_DIR/${SAMPLE}_R1_unpaired.fastq.gz \
            $OUT_DIR/${SAMPLE}_R2_paired.fastq.gz $OUT_DIR/${SAMPLE}_R2_unpaired.fastq.gz \
            SLIDINGWINDOW:4:20 MINLEN:50

        bwa mem $REF $OUT_DIR/${SAMPLE}_R1_paired.fastq.gz $OUT_DIR/${SAMPLE}_R2_paired.fastq.gz > $OUT_DIR/${SAMPLE}.trimmed.sam
        samtools view -bS $OUT_DIR/${SAMPLE}.trimmed.sam > $OUT_DIR/${SAMPLE}.trimmed.bam
        samtools sort -o $OUT_DIR/${SAMPLE}.trimmed.sorted.bam $OUT_DIR/${SAMPLE}.trimmed.bam
        samtools index $OUT_DIR/${SAMPLE}.trimmed.sorted.bam
    else
        echo "trimmomatic not found, skipping trimming for $SAMPLE"
        cp $OUT_DIR/${SAMPLE}.aligned.sorted.bam $OUT_DIR/${SAMPLE}.trimmed.sorted.bam
        cp $OUT_DIR/${SAMPLE}.aligned.sorted.bam.bai $OUT_DIR/${SAMPLE}.trimmed.sorted.bam.bai
    fi

    # Step 3: QC metrics
    TOTAL=$(samtools flagstat $OUT_DIR/${SAMPLE}.aligned.sorted.bam | grep "in total" | awk '{print $1}')
    MAPPED=$(samtools flagstat $OUT_DIR/${SAMPLE}.aligned.sorted.bam | grep "mapped (" | head -n1 | awk '{print $1}')
    MAPPED_PCT=$(awk -v m=$MAPPED -v t=$TOTAL 'BEGIN{printf "%.2f", (m/t)*100}')

    samtools depth -a $OUT_DIR/${SAMPLE}.trimmed.sorted.bam > $OUT_DIR/${SAMPLE}.depth.txt
    GE10=$(awk '{if($3>=10) c++} END{print c}' $OUT_DIR/${SAMPLE}.depth.txt)
    BREADTH10=$(awk -v g=$GENOME_LENGTH -v c=$GE10 'BEGIN{printf "%.2f", (c/g)*100}')
    GE20=$(awk '{if($3>=20) c++} END{print c}' $OUT_DIR/${SAMPLE}.depth.txt)
    BREADTH20=$(awk -v g=$GENOME_LENGTH -v c=$GE20 'BEGIN{printf "%.2f", (c/g)*100}')
    MEDIANDEPTH=$(cut -f3 $OUT_DIR/${SAMPLE}.depth.txt | sort -n | awk '{a[NR]=$1} END{ if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[(NR/2)+1])/2 }')

    echo -e "$SAMPLE\t$MAPPED_PCT\t$BREADTH10\t$BREADTH20\t$MEDIANDEPTH" >> $OUT_DIR/QC_summary.tsv
done

