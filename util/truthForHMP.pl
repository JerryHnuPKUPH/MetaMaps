use strict;
use warnings;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../perlLib"; 
$| = 1;

use taxTree;
use simulation;

my $prefix_out = '../tmp/truthHMP7';


my $targetDB = '../databases/miniSeq';

my $HMP_fastQ = '/scratch/tmp/hmp_set7_combined.fastq';
my $HMP_readIDs_href = getReadIDs($HMP_fastQ);

my $masterTaxonomy_dir = '/data/projects/phillippy/projects/MetaMap/downloads/taxonomy';
my $MetaMap_taxonomy = taxTree::readTaxonomy($masterTaxonomy_dir);
my $MetaMap_taxonomy_merged = taxTree::readMerged($masterTaxonomy_dir);

my %taxa_genome_lengths;
open(GL, '<', '../tmp/HMP_genome_lengths.txt') or die "Cannot open ../tmp/HMP_genome_lengths.txt";
while(<GL>)
{
	my $l = $_;
	chomp($l);
	next unless($l);
	my @f = split(/\t/, $l);
	die unless(scalar(@f) == 2);
	$taxa_genome_lengths{$f[0]} = $f[1];
}
close(GL);

foreach my $config (['blasr', '/data/projects/phillippy/projects/mash_map/Jobs/blasr/hmp/target/all.m4'], ['bwa', '/data/projects/phillippy/projects/mash_map/Jobs/blasr/hmp/targetAll/mock.all.genome.fa.pacbioReads.bam'])
{
	my $fn_out_reads = $prefix_out . '_' . $config->[0] . '.perRead';
	my $fn_out_distribution = $prefix_out . '_' . $config->[0] . '.distribution';
	my $fn_out_distribution_genomeFreqs = $prefix_out . '_' . $config->[0] . '.distribution_genomes';

	my %alignments_per_readID;
	my %alignments_per_longReadID;
	my %read_2_gis;
	my %haveReadInFastQ;
	my %noReadInFastQ;
	my %readID_2_length;
	if($config->[1] =~ /\.m4/)
	{
		my $n_read_blasr = 0;
		open(BLASRTRUTH, '<', $config->[1]) or die "Cannot open $config->[1]";

		while(<BLASRTRUTH>)
		{
			my $line = $_;
			chomp($line);
			my @fields = split(/\s+/, $line);
			my $longReadID = $fields[0];
			die "Can't parse read ID $longReadID" unless($longReadID =~ /(^.+)\/\d+_\d+$/);
			my $readID = $1;
			if(exists $HMP_readIDs_href->{$readID})
			{
				#next;
				#die "Read ID $readID not in HMP FASTQ $HMP_fastQ";
				$haveReadInFastQ{$readID}++;
			}
			else
			{
				$noReadInFastQ{$readID}++;
				next;
			}
			# print join("\t", $longReadID, $readID), "\n";
			my $contigID = $fields[1];
			my $identity = $fields[3];
			die unless($identity >= 2); die unless($identity <= 100);
			
			my $alignment_read_start = $fields[5];
			my $alignment_read_stop = $fields[6];
			die unless($alignment_read_start < $alignment_read_stop);
			my $alignment_read_length = $alignment_read_stop - $alignment_read_start + 1;
			
			my $read_length = $fields[7];
			die Dumper($read_length, $alignment_read_stop) unless($read_length >= $alignment_read_stop);
			
			my $alignment_cover = $alignment_read_length/$read_length;
			#next unless($alignment_cover >= 0.7);
			$alignments_per_readID{$readID}++;
			$alignments_per_longReadID{$longReadID}++;
			
			die "Invalid contig ID - no GI! $contigID" unless($contigID =~ /gi\|(\d+)\|/);
			my $gi = $1;
			push(@{$read_2_gis{$readID}}, [$gi, $alignment_read_length * ($identity/100)]);
			if(exists $readID_2_length{$readID})
			{
				die unless($readID_2_length{$readID} == $read_length);
			}
			$readID_2_length{$readID} = $read_length;
			
			$n_read_blasr++;
		}
		close(BLASRTRUTH);
	}
	elsif($config->[1] =~ /\.bam/)
	{
		my $n_reads = 0;
					
		open(BAM, '-|', "samtools view -F 0x800 -F 0x100 -F 0x4 $config->[1]") or die "Cannot pipe-open $config->[1]";

		while(<BAM>)
		{
			my $line = $_;
			chomp($line);
			my @fields = split(/\s+/, $line);
			my $longReadID = $fields[0];
			die "Can't parse read ID $longReadID" unless($longReadID =~ /(^.+)\/\d+_\d+$/);
			my $readID = $1;
			if(exists $HMP_readIDs_href->{$longReadID})
			{
				#next;
				#die "Read ID $readID not in HMP FASTQ $HMP_fastQ";
				die if($haveReadInFastQ{$longReadID});
				$haveReadInFastQ{$longReadID}++;
			}
			else
			{
				$noReadInFastQ{$longReadID}++;
				next;
			}
			# print join("\t", $longReadID, $readID), "\n";
			my $contigID = $fields[2];
			my $mapQ = $fields[4];
			my $seq = $fields[9];
			
			die unless($mapQ =~ /^\d+$/);
			die "Invalid contig ID - no GI! $contigID" unless($contigID =~ /gi\|(\d+)\|/);
			my $gi = $1;
			die "Duplicate short read ID $readID from $longReadID in file $config->[1]" if(exists $read_2_gis{$readID});
			push(@{$read_2_gis{$readID}}, [$gi, $mapQ]);
			
			$n_reads++;
			$alignments_per_readID{$readID}++;
			$alignments_per_longReadID{$longReadID}++;
		
			if(exists $readID_2_length{$readID})
			{
				die unless($readID_2_length{$readID} = length($seq));
			}
			$readID_2_length{$readID} = length($seq);			
		}
		close(BAM);	
	}
	else
	{
		die "Not sure how to deal with config $config->[1]";
	}
	
	print "Reads - no alignments   - also in FASTQ:", scalar(grep {not exists $alignments_per_longReadID{$_}} keys %$HMP_readIDs_href), "\n";
	print "Reads - with alignments - also in FASTQ:", scalar(keys %haveReadInFastQ), "\n";
	print "Reads - with alignments - not  in FASTQ: ", scalar(keys %noReadInFastQ), "\n";

	# statistics

	my %histogram_n_alignments;
	foreach my $readID (keys %alignments_per_readID)
	{
		my $n_alignments = $alignments_per_readID{$readID};
		$histogram_n_alignments{$n_alignments}++;
	}

	print "Number of reads: ", scalar(keys %alignments_per_readID), "\n";
	print "Number-of-alignments histogram:\n";
	foreach my $n_alignment (sort keys %histogram_n_alignments)
	{
		print "\t", $n_alignment, "\t", $histogram_n_alignments{$n_alignment}, "\n";
	}

	my %gis_present;
	foreach my $readID (keys %read_2_gis)
	{
		my @alignments = @{$read_2_gis{$readID}};
		my $sortAlignments = sub {
			my $a = shift;
			my $b = shift;
			if($a->[1] == $b->[1])
			{
				return ($a->[0] cmp $b->[0]);
			}
			else
			{
				return ($a->[1] <=> $b->[1]);
			}
		};	
		if(scalar(@alignments) > 1)
		{
			@alignments = sort {$sortAlignments->($a, $b)} @alignments;
			@alignments = reverse @alignments;
			die unless($alignments[0][1] >= $alignments[1][1]);
		}
		$read_2_gis{$readID} = $alignments[0][0];
		$gis_present{$alignments[0][0]}++;
	}

	# print "\nGIs present: ", scalar(keys %gis_present), "\n";

	# gi 2 taxon ID

	print "Reading gi-2-taxon...\n";
	unless(-e '/data/projects/phillippy/projects/mashsim/db/gi_taxid_nucl.dmp.HMP')
	{
		open(GI2TAXON, '<', '/data/projects/phillippy/projects/mashsim/db/gi_taxid_nucl.dmp') or die;
		open(GI2TAXONOUT, '>', '/data/projects/phillippy/projects/mashsim/db/gi_taxid_nucl.dmp.HMP') or die;
		while(<GI2TAXON>)
		{
			my $line = $_; 
			chomp($line);
			my @f = split(/\s+/, $line);
			die unless($#f == 1);	
			if($gis_present{$f[0]})
			{
				print GI2TAXONOUT $line, "\n";
			}
			if(($. % 100000) == 0)
			{
				print "\rGI line $. ...";
			}		
		}
		close(GI2TAXON);
		print "\n";
	}

	my %gi_2_taxon;
	open(GI2TAXON, '<', '/data/projects/phillippy/projects/mashsim/db/gi_taxid_nucl.dmp.HMP') or die;
	while(<GI2TAXON>)
	{
		my $line = $_; 
		chomp($line);
		my @f = split(/\s+/, $line);
		die unless($#f == 1);	
		$gi_2_taxon{$f[0]} = $f[1];
	}
	close(GI2TAXON);

	$gi_2_taxon{126640115} = '400667';
	$gi_2_taxon{126640097} = '400667';
	$gi_2_taxon{126640109} = '400667';
	$gi_2_taxon{161510924} = '451516';
	$gi_2_taxon{32470532} = '176280';
				
	open(OUT_PERREAD, '>', $fn_out_reads) or die "Cannot open file $fn_out_reads";
	my %read_2_taxonID;
	my %taxonID_read_counts;
	my %taxonID_2_bases;
	foreach my $readID (keys %read_2_gis)
	{
		my $gi = $read_2_gis{$readID};
		my $taxonID_original = $gi_2_taxon{$gi};
		die "No translation for GI number $gi" unless(defined $taxonID_original);
		my $taxonID_current = taxTree::findCurrentNodeID($MetaMap_taxonomy, $MetaMap_taxonomy_merged, $taxonID_original);
		print OUT_PERREAD join("\t", $readID, $taxonID_current), "\n";
		$read_2_taxonID{$readID} = $taxonID_current;
		$taxonID_read_counts{$taxonID_current}++;
		my $length = $readID_2_length{$readID};
		die unless(defined $length);
		$taxonID_2_bases{$taxonID_current} += $length;
	}	

	foreach my $readID (keys %$HMP_readIDs_href)
	{
		next if(defined $read_2_taxonID{$readID});
		print OUT_PERREAD join("\t", $readID, 0), "\n";
		$taxonID_read_counts{0}++;
	}

	close(OUT_PERREAD);

	foreach my $taxonID (keys %taxonID_2_bases)
	{
		unless(exists $taxa_genome_lengths{$taxonID})
		{
			die "Missing length information for taxon $taxonID";
		}
	}
	
	simulation::truthReadFrequenciesFromReadCounts($fn_out_distribution, \%taxonID_read_counts, $MetaMap_taxonomy);
	simulation::truthGenomeFrequenciesFromReadCounts($fn_out_distribution_genomeFreqs, \%taxonID_2_bases, \%taxonID_read_counts, \%taxa_genome_lengths, $MetaMap_taxonomy);

	print "\n\nDone $config->[0] . Produced files:\n";
	print "\t - $fn_out_reads \n";
	print "\t - $fn_out_distribution \n";
	print "\t - $fn_out_distribution_genomeFreqs \n";
}

sub getReadIDs
{
	my $fn = shift;
	
	my %forReturn;
	open(F, '<', $fn) or die;
	while(<F>)
	{
		chomp;
		next unless($_);
		my $readID = $_;
		die unless(substr($readID, 0, 1) eq '@');
		substr($readID, 0, 1) = '';
		<F>;
		my $plus = <F>;
		die unless(substr($plus, 0, 1) eq '+');
		<F>;
		$forReturn{$readID}++;
	}
	close(F);
	return \%forReturn;
}