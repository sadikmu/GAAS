#!/usr/bin/perl

## if IUPAC:
## We consider a stop only if we are sure it is one
## CDS can contains putative stop codon (but not sure stop one like YAA that can be TAA or CAA).
## We consider a start even if is not sure like AYG that can be ATG or ACG

use Carp;
use Clone 'clone';
use strict;
use File::Basename;
use Getopt::Long;
use Statistics::R;
use Pod::Usage;
use Data::Dumper;
use List::MoreUtils qw(uniq);
use Bio::Tools::GFF;
use Bio::DB::Fasta;
#use Bio::Seq;
use Bio::SeqIO;
use BILS::Handler::GXFhandler qw(:Ok);
use BILS::Handler::GFF3handler qw(:Ok);
use BILS::Plot::R qw(:Ok);

my $SIZE_OPT=21;

my $header = qq{
########################################################
# BILS 2015 - Sweden                                   #  
# jacques.dainat\@bils.se                               #
# Please cite BILS (www.bils.se) when using this tool. #
########################################################
};

my $outfile = undef;
my $gff = undef;
my $file_fasta=undef;
my $stranded=undef;
my $threshold=undef;
my $help= 0;

if ( !GetOptions(
    "help|h" => \$help,
    "gff=s" => \$gff,
    "fasta|fa=s" => \$file_fasta,
    "stranded|s" => \$stranded,
    "threshold|t=i" => \$threshold,
    "output|outfile|out|o=s" => \$outfile))

{
    pod2usage( { -message => 'Failed to parse command line',
                 -verbose => 1,
                 -exitval => 1 } );
}

# Print Help and exit
if ($help) {
    pod2usage( { -verbose => 2,
                 -exitval => 2,
                 -message => "$header\n" } );
}
 
if ( ! (defined($gff)) or !(defined($file_fasta)) ){
    pod2usage( {
           -message => "$header\nAt least 2 parameter is mandatory:\nInput reference gff file (--gff) and Input fasta file (--fasta)\n\n",
           -verbose => 0,
           -exitval => 1 } );
}

######################
# Manage output file #
my $gffout;
my $gffout2;
my $gffout3;
my $gffout4;
if ($outfile) {
  $outfile=~ s/.gff//g;
open(my $fh, '>', $outfile."-intact.gff") or die "Could not open file '$outfile' $!";
  $gffout= Bio::Tools::GFF->new(-fh => $fh, -gff_version => 3 );
open(my $fh2, '>', $outfile."-only_modified.gff") or die "Could not open file '$outfile' $!";
  $gffout2= Bio::Tools::GFF->new(-fh => $fh2, -gff_version => 3 );
open(my $fh3, '>', $outfile."-all.gff") or die "Could not open file '$outfile' $!";
  $gffout3= Bio::Tools::GFF->new(-fh => $fh3, -gff_version => 3 );
open($gffout4, '>', $outfile."-report.txt") or die "Could not open file '$outfile' $!";
}
else{
  $gffout = Bio::Tools::GFF->new(-fh => \*STDOUT, -gff_version => 3);
}

if(!$threshold){
  $threshold=100;
}
print "Minimum protein length taken in account = $threshold AA\n";

if($stranded){
  $stranded=1;
  print "You say that annotation has been done using stranded RNA. So, most probable fusion will be between close gene in same direction. We will focuse on that !\n";
}
else{ print "You didn't use the option stranded. We will look for fusion in all strand (+ and -)!\n";}

                #####################
                #     MAIN          #
                #####################


######################
### Parse GFF input #
my ($hash_omniscient, $hash_mRNAGeneLink) = BILS::Handler::GFF3handler->slurp_gff3_file_JD($gff);
print ("GFF3 file parsed\n");


####################
# index the genome #
my $db = Bio::DB::Fasta->new($file_fasta);
print ("Genome fasta parsed\n");

####################
my $pseudo_threshold=70;
#counters
my $counter_case21=0;
my $geneCounter=0;
my $mRNACounter=0;
my $mRNACounter_fixed=0;
my $special_or_partial_mRNA=0;

my %omniscient_modified_gene;
my @intact_gene_list;

# create the hash temp
my %tmpOmniscientR;
my $tmpOmniscient=\%tmpOmniscientR;
my @mRNAlistToTakeCareR;
my $mRNAlistToTakeCare=\@mRNAlistToTakeCareR;

foreach my $primary_tag_key_level1 (keys %{$hash_omniscient->{'level1'}}){ # primary_tag_key_level1 = gene or repeat etc...
  foreach my $gene_id (keys %{$hash_omniscient->{'level1'}{$primary_tag_key_level1}}){
    
    my $gene_feature=$hash_omniscient->{'level1'}{$primary_tag_key_level1}{$gene_id};

    my $oneMRNAmodified=undef;
    my $mrna_pseudo=0;
    my @list_mrna_pseudo;
    my $one_level2_modified; # check if one of the level2 feature will be modified
    my $number_mrna=0;

    # COPY gene and subfeatures.
    %$tmpOmniscient = (); # empty the hash
    @$mRNAlistToTakeCare = (); # empty the list    
    my @tmpListID=($gene_id);
    fill_omniscient_from_other_omniscient_level1_id(\@tmpListID,$hash_omniscient,$tmpOmniscient);
    
    foreach my $primary_tag_key_level2 (keys %{$hash_omniscient->{'level2'}}){ # primary_tag_key_level2 = mrna or mirna or ncrna or trna etc...
      foreach my $level2_feature ( @{$hash_omniscient->{'level2'}{$primary_tag_key_level2}{$gene_id}}) {
       
        # get multiple info
        $number_mrna=$#{$hash_omniscient->{'level2'}{$primary_tag_key_level2}{$gene_id}}+1;
        my $id_level2 = lc($level2_feature->_tag_value('ID'));
        push (@$mRNAlistToTakeCare,$id_level2);

        ##############################
        #If UTR3 #
        my $oneRoundAgain="yes";
        my $nbNewUTR3gene=0;
        if ( exists ($hash_omniscient->{'level3'}{'three_prime_utr'}{$id_level2} ) ){
          
          while($oneRoundAgain){
            my ($breakRound, $nbNewUTRgene, $mRNAlistToTakeCare) = take_care_utr('three_prime_utr', $tmpOmniscient, $mRNAlistToTakeCare, $stranded, $gffout);
            $oneRoundAgain =  $breakRound;
            $nbNewUTR3gene = $nbNewUTR3gene+$nbNewUTRgene;
          }
        }
        ##############################
        #If UTR5 #
        $oneRoundAgain="yes";
        my $nbNewUTR5gene=0;
        if ( exists ($hash_omniscient->{'level3'}{'five_prime_utr'}{$id_level2} ) ){
        
        while($oneRoundAgain){
            my ($breakRound, $nbNewUTRgene, $mRNAlistToTakeCare) = take_care_utr('five_prime_utr', $tmpOmniscient, $mRNAlistToTakeCare, $stranded, $gffout);
            $oneRoundAgain =  $breakRound;
            $nbNewUTR5gene = $nbNewUTR5gene+$nbNewUTRgene;
          }
        }
        ##########################
        #If UTR not well defined #
        if ( exists ($hash_omniscient->{'level3'}{'utr'}{$id_level2} ) ){
          print "Sorry but we need to know which utr it is ... 5 or 3 ?\n";exit;
        }

        #############
        # CHECK AFTER ALL UTR ANALIZED
        my $totalNewUTRgene=$nbNewUTR3gene+$nbNewUTR5gene;
        if($totalNewUTRgene > 0){
          $oneMRNAmodified="yes";
          $mRNACounter_fixed++; # Count only mRNA modified
        }
        @$mRNAlistToTakeCare = (); # empty the list
        #print "ONLY ONE ROUND TO CHECK !\n";print_omniscient($tmpOmniscient, $gffout2); exit;
      } # End foreach mRNA

      if($oneMRNAmodified){
        $geneCounter++;
        $mRNACounter=$mRNACounter+$number_mrna; #add all the mRNA if at least one modified
        #save remodelate gene name

        fill_omniscient_from_other_omniscient($tmpOmniscient, \%omniscient_modified_gene);
      }
      else{push(@intact_gene_list, $gene_id);}
    }
  }
}
###
# Fix frame
fil_cds_frame(\%omniscient_modified_gene);
fil_cds_frame($hash_omniscient);

########
# Print results
if ($outfile) {
  #print all in file1
  print_omniscient_from_level1_id_list($hash_omniscient, \@intact_gene_list, $gffout); #print intact gene to the file
  
  print_omniscient(\%omniscient_modified_gene, $gffout2); #print gene modified in file 
  
  print_omniscient_from_level1_id_list($hash_omniscient, \@intact_gene_list, $gffout3);
  print_omniscient(\%omniscient_modified_gene, $gffout3);
}
else{
  #print_omniscient_from_level1_id_list($hash_omniscient, \@intact_gene_list, $gffout); #print gene intact
  print_omniscient(\%omniscient_modified_gene, $gffout); #print gene modified
}

#END
my $string_to_print="Results:\n";
$string_to_print .="$geneCounter genes affected and $mRNACounter_fixed mRNA.\n";

$string_to_print .="\n/!\\Remind:\n L and M are AA are possible start codons.\nParticular case: If we have a triplet as WTG, AYG, RTG, RTR or ATK it will be seen as a possible Methionine codon start (it's a X aa)\n".
"An arbitrary choisce has been done: The longer translate can begin by a L only if it's longer by 21 AA than the longer translate beginning by M. It's happened $counter_case21 times here.\n";

#print $string_to_print;
if($outfile){
  print $gffout4 $string_to_print
}
print $string_to_print;
print "Bye Bye.\n";
#######################################################################################################################
        ####################
         #     METHODS    #
          ################
           ##############
            ############
             ##########
              ########
               ######
                ####
                 ##          


sub take_care_utr{

  my ($utr_tag, $tmpOmniscient, $mRNAlistToTakeCare, $stranded, $gffout)=@_;

  my $oneRoundAgain=undef;
  my $nbNewUTRgene=0;      

  foreach my $primary_tag_key_level1 (keys %{$tmpOmniscient->{'level1'}}){ # primary_tag_key_level1 = gene or repeat etc...
  foreach my $gene_id (keys %{$tmpOmniscient->{'level1'}{$primary_tag_key_level1}}){
    
  my $gene_feature=$tmpOmniscient->{'level1'}{$primary_tag_key_level1}{$gene_id};
  my $gene_id = lc($gene_feature->_tag_value('ID'));  
  #print "\ntake care utr GeneID = $gene_id\n";

  foreach my $primary_tag_key_level2 (keys %{$tmpOmniscient->{'level2'}}){ # primary_tag_key_level2 = mrna or mirna or ncrna or trna etc...
    foreach my $level2_feature ( @{$tmpOmniscient->{'level2'}{$primary_tag_key_level2}{$gene_id}}) {
      
      my $id_level2=lc($level2_feature->_tag_value('ID'));   
      foreach my $mRNAtoTakeCare (@{$mRNAlistToTakeCare}){
        #print "id_level2 -- $id_level2 ***** to take_care -- $mRNAtoTakeCare  \n";
        if($mRNAtoTakeCare eq $id_level2){ # ok is among the list of those to analyze

          if(exists ($tmpOmniscient->{'level3'}{$utr_tag}) and exists ($tmpOmniscient->{'level3'}{$utr_tag}{$id_level2}) ){
            
            ##################################################
            # extract the concatenated exon and cds sequence #
            my $oppDir=undef;
            my $original_strand=$level2_feature->strand;
            ###############
            # Manage UTRS #
            my @utr_feature_list = sort {$a->start <=> $b->start} @{$tmpOmniscient->{'level3'}{$utr_tag}{$id_level2}}; # be sure that list is sorted
            my ($utrExtremStart, $utr_seq, $utrExtremEnd) = concatenate_feature_list(\@utr_feature_list);        
            #create the utr object
            my $utr_obj = Bio::Seq->new(-seq => $utr_seq, -alphabet => 'dna' );
            
            #Reverse complement according to strand
            if ($original_strand == -1 or $original_strand eq "-"){
              $utr_obj = $utr_obj->revcom();
            }
            
            # get the revcomp
            my $opposite_utr_obj = $utr_obj->revcom();


            my $longest_ORF_prot_obj;
            my $orf_utr_region;
            #################################
            # Get the longest ORF positive ## record ORF = start, end (half-open), length, and frame
            my $longest_ORF_prot_obj_p;
            my $orf_utr_region_p;
            my ($longest_ORF_prot_objM, $orf_utr_regionM) = translate_JD($utr_obj, 
                                                                        -nostartbyaa => 'L',
                                                                        -orf => 'longest');
            my ($longest_ORF_prot_objL, $orf_utr_regionL) = translate_JD($utr_obj, 
                                                                        -nostartbyaa => 'M',
                                                                        -orf => 'longest');
            if($longest_ORF_prot_objL->length()+$SIZE_OPT > $longest_ORF_prot_objM ){ # In a randomly generated DNA sequence with an equal percentage of each nucleotide, a stop-codon would be expected once every 21 codons. Deonier et al. 2005
              $longest_ORF_prot_obj_p=$longest_ORF_prot_objL;                    # As Leucine L (9/100) occur more often than Metionine M (2.4) JD arbitrary choose to use the L only if we strength the sequence more than 21 AA. Otherwise we use M start codon.
              $orf_utr_region_p=$orf_utr_regionL;
              $counter_case21++;
            }else{
              $longest_ORF_prot_obj_p=$longest_ORF_prot_objM;
              $orf_utr_region_p=$orf_utr_regionM;
            }
            #print "Best same strand as original mRNA = ".$longest_ORF_prot_obj_p->length()."\n";
           
            ########################################
            # Get the longest ORF opposite strand ## record ORF = start, end (half-open), length, and frame
            my $length_longest_ORF_prot_obj_n=0;
            my $longest_ORF_prot_obj_n;
            my $orf_utr_region_n;
            
            if(! $stranded){

              my ($longest_ORF_prot_objM, $orf_utr_regionM) = translate_JD($opposite_utr_obj, 
                                                                          -nostartbyaa => 'L',
                                                                          -orf => 'longest');
              my ($longest_ORF_prot_objL, $orf_utr_regionL) = translate_JD($opposite_utr_obj, 
                                                                          -nostartbyaa => 'M',
                                                                          -orf => 'longest');
              if($longest_ORF_prot_objL->length()+$SIZE_OPT > $longest_ORF_prot_objM ){ # In a randomly generated DNA sequence with an equal percentage of each nucleotide, a stop-codon would be expected once every 21 codons. Deonier et al. 2005
                $longest_ORF_prot_obj_n=$longest_ORF_prot_objL;                    # As Leucine L (9/100) occur more often than Metionine M (2.4) JD arbitrary choose to use the L only if we strength the sequence more than 21 AA. Otherwise we use M start codon.
                $orf_utr_region_n=$orf_utr_regionL;
                $counter_case21++;
              }else{
                $longest_ORF_prot_obj_n=$longest_ORF_prot_objM;
                $orf_utr_region_n=$orf_utr_regionM;
              }
              $length_longest_ORF_prot_obj_n = $longest_ORF_prot_obj_n->length();
              #print "Best opposite strand as original mRNA = ".$longest_ORF_prot_obj_n->length()."\n";
            }

            #################
            # Choose the best
            if($longest_ORF_prot_obj_p->length() >= $length_longest_ORF_prot_obj_n){
              $longest_ORF_prot_obj= $longest_ORF_prot_obj_p;
              $orf_utr_region= $orf_utr_region_p;
              #print "positive $id_level2 !!\n";
            }else{
              #print "Negative  $id_level2 !!\n";
              $longest_ORF_prot_obj= $longest_ORF_prot_obj_n;
              $orf_utr_region= $orf_utr_region_n;
              $oppDir=1;
              #my @cds_feature_list = sort {$a->start <=> $b->start} @{$tmpOmniscient->{'level3'}{'cds'}{$id_level2}}; # be sure that list is sorted
              #($cdsExtremStart, $cds_dna_seq, $cdsExtremEnd) = concatenate_feature_list($cds_feature_list); # we have to change these value because it was not predicted as same direction as mRNA
            }


            ########################
            # prediction is longer than threshold#
            if($longest_ORF_prot_obj->length() > $threshold){
              print "$gene_id Longer AA in utr = ".$longest_ORF_prot_obj->length()."\n".$longest_ORF_prot_obj->seq."\n\n";
               
              my @exons_features = sort {$a->start <=> $b->start} @{$tmpOmniscient->{'level3'}{'exon'}{$id_level2}};# be sure that list is sorted
              my ($exonExtremStart, $mrna_seq, $exonExtremEnd) = concatenate_feature_list(\@exons_features); 
             
              my @cds_feature_list = sort {$a->start <=> $b->start} @{$tmpOmniscient->{'level3'}{'cds'}{$id_level2}}; # be sure that list is sorted  
              my ($cdsExtremStart, $cds_dna_seq, $cdsExtremEnd) = concatenate_feature_list(\@cds_feature_list);

              # set real start and stop to orf
              my $realORFstart;
              my $realORFend;
              #print "mRNA length: ".length($mrna_seq)."  UTR length: ".length($utr_seq)."\n";
              #print "start in UTR piece ".$orf_utr_region->[0]." end ".$orf_utr_region->[1]."\n";
              ####################################
              # Recreate position of start in mRNA positive strand
              my $startUTRinMRNA=length($mrna_seq) - length($utr_seq);
              if ($utr_tag eq 'three_prime_utr' ){    
                if($original_strand == 1 or $original_strand eq "+" ){
                  if(! $oppDir){
                    $orf_utr_region->[0]=$orf_utr_region->[0]+($startUTRinMRNA);
                  }
                  else{ #opposite direction
                    $orf_utr_region->[0]=length($mrna_seq) - $orf_utr_region->[1]; 
                  }
                }
                else{ #minus strand
                    if(! $oppDir){
                      $orf_utr_region->[0]=length($utr_seq) - $orf_utr_region->[1]; #flip position
                    }
                }
              }
              elsif ($utr_tag eq 'five_prime_utr'){
                if($original_strand == 1 or $original_strand eq "+"){
                  if($oppDir){
                    $orf_utr_region->[0]=length($utr_seq) - $orf_utr_region->[1];
                  }
                }
                else{ #minus strand
                  if(! $oppDir){
                    $orf_utr_region->[0]=(length($utr_seq) - $orf_utr_region->[1])+($startUTRinMRNA);
                  }
                  else{ #opposite direction
                     $orf_utr_region->[0]=$orf_utr_region->[0]+($startUTRinMRNA);
                  }
                }
              }

                
              #print "Real start in UTR piece ".$orf_utr_region->[0]." end ".$orf_utr_region->[1]."\n";
              #calcul the real start end stop of utr in genome  
              ($realORFstart, $realORFend) = calcul_real_orf_end_and_start($orf_utr_region, \@exons_features);
              #print "start: $realORFstart end: $realORFend\n"; 
   
              #save the real start and stop
              $orf_utr_region->[0]=$realORFstart;
              $orf_utr_region->[1]=$realORFend;       

              # Now manage splitting the old gene to obtain two genes
              $mRNAlistToTakeCare = split_gene_model($tmpOmniscient, $gene_feature, $level2_feature, \@exons_features, \@cds_feature_list, $cdsExtremStart, $cdsExtremEnd, $realORFstart, $realORFend, $oppDir, $mRNAlistToTakeCare, $gffout);
              #print Dumper($tmpOmniscient)."\n";
              $oneRoundAgain="yes";
              $nbNewUTRgene++;
            } # We predict something in UTR
          } # End there is UTR
        } 
      }
    }
  }
  }
  }
  return $oneRoundAgain, $nbNewUTRgene, $mRNAlistToTakeCare;
}        

#create an Uniq gene ID
sub take_care_gene_id{

      my ($gene_id, $tmpOmniscient) = @_;

      #clean geneid if necessary
      $gene_id =~ /^(new[0-9]+_)?(.*)$/;
      my $clean_id=$2;

      #count current gene number - should be one if first analysis
      my $primary_tag_key_general;
      my $numberOfNewGene=1;

      foreach my $primary_tag_key_level1 (keys %{$tmpOmniscient->{'level1'}}){ # primary_tag_key_level1 = gene or repeat etc...
        foreach my $gene_id_from_hash (keys %{$tmpOmniscient->{'level1'}{$primary_tag_key_level1}}){
          if($gene_id_from_hash =~ /(new[1-9]+_)/){
            $numberOfNewGene++;
          }     
        }
        #primary tag key containg gene name has been found. No need to see the others.
        $primary_tag_key_general=$primary_tag_key_level1;
        last;
      }
      
      # From tmpOmniscient: Between ( new1_geneA, new2_geneA, new3_geneA). It happens that new2_geneA has been deleted. In that case we try to create new3_geneA but as already exists we try new2_geneA (--)
      # If new2_geneA also already exist, it means that it exist in hash_omniscient. so we will try decrementing $numberGeneIDToCheck until 1; Then we will try incrementing $numberGeneIDToCheck over new3_geneA  (in other term we try new4_geneA )
      my $testok=undef;
      my $nbToadd=-1;
      my $numberGeneIDToCheck=$numberOfNewGene;
      my $new_id;
      while (! $testok){
        my $newGenePrefix="new".$numberGeneIDToCheck."_";
        $new_id="$newGenePrefix$clean_id";

        if((! defined ($tmpOmniscient->{'level1'}{$primary_tag_key_general}{lc($new_id)})) and (! defined ($hash_omniscient->{'level1'}{$primary_tag_key_general}{lc($new_id)}))){
            $testok=1;
        }
        else{
          if($numberGeneIDToCheck == 1){
            $nbToadd=1;$numberGeneIDToCheck=$numberOfNewGene;
          }
          $numberGeneIDToCheck=$numberGeneIDToCheck+$nbToadd;}
      }
      #print "old_gene_id --- $gene_id ***** new_gene_id --- $new_id\n";

  return $new_id;
}

#create an Uniq mRNA ID
sub take_care_mrna_id {

      my ($tmpOmniscient, $mRNA_id) = @_;

      #clean geneid if necessary
      $mRNA_id =~ /^(new[0-9]+_)?(.*)$/;
      my $clean_id=$2;

      #count current gene number - should be one if first analysis
      my %id_to_avoid;
      my $numberOfNewMrna=1;

      foreach my $primary_tag_key_level1 (keys %{$tmpOmniscient->{'level1'}}){ # primary_tag_key_level1 = gene or repeat etc...
        foreach my $gene_id_from_hash (keys %{$tmpOmniscient->{'level1'}{$primary_tag_key_level1}}){
          foreach my $primary_tag_key_level2 (keys %{$tmpOmniscient->{'level2'}}){ # primary_tag_key_level1 = gene or repeat etc...
            if( exists( $tmpOmniscient->{'level2'}{$primary_tag_key_level2}{$gene_id_from_hash} )){
              foreach my $featureL2 (@{$tmpOmniscient->{'level2'}{$primary_tag_key_level2}{$gene_id_from_hash}}){
                my $mrna_id_from_hash=$featureL2->_tag_value('ID');
                if($mrna_id_from_hash =~ /(new[1-9]+_)/){
                  $id_to_avoid{lc($mrna_id_from_hash)};
                  $numberOfNewMrna++;
                }     
              }
            }
          }
        }
      }

      my $testok=undef;
      my $nbToadd=-1;
      my $numberMRNA_IDToCheck=$numberOfNewMrna;
      my $new_id;
      while (! $testok){
        my $newPrefix="new".$numberMRNA_IDToCheck."_";
        $new_id="$newPrefix$clean_id";

        if( (! defined ($hash_mRNAGeneLink->{lc($new_id)})) and (! defined ($id_to_avoid{lc($new_id)})) ) {
            $testok=1;
        }
        else{
          if($numberMRNA_IDToCheck == 1){
            $nbToadd=1;$numberMRNA_IDToCheck=$numberOfNewMrna;
          }
          $numberMRNA_IDToCheck=$numberMRNA_IDToCheck+$nbToadd;}
      }
      #print "old_mrna_id --- $mRNA_id ***** new_mrna_id --- $new_id\n";

  return $new_id;
}

#As based on a Uniq mRNA ID, this will create a Uniq ID;
sub take_care_level3_id {

      my ($level3_id, $value) = @_;

      #clean geneid if necessary
      $level3_id =~ /^(new[0-9]+_)?(.*)$/;
      my $clean_id=$2;
      my $newPrefix="new".$value."_";
      my $new_id="$newPrefix$clean_id";

  return $new_id;
}

############ /!\
# P.S: To be perfect, when a gene is newly created, we should verify if it is not created where another one has already been created. If yes, the should be linked together !!
############
sub split_gene_model{

   my ($tmpOmniscient, $gene_feature, $level2_feature, $exons_features, $cds_feature_list, $cdsExtremStart, $cdsExtremEnd, $realORFstart, $realORFend, $oppDir, $mRNAlistToTakeCare, $gffout)=@_;

      my $gene_id = $gene_feature->_tag_value('ID');  
      my $id_level2 = lc($level2_feature->_tag_value('ID'));
      my $newcontainerUsed=0;

                  ######################
                  # Recreate exon list #
                  my $bolean_original_is_first;
                  my $first_end;
                  my $second_start;
                  #if new prediction after on the sequence
                  if($realORFstart >= $cdsExtremEnd){
                    $bolean_original_is_first="true";
                    $first_end=$cdsExtremEnd;
                    $second_start=$realORFstart;
                  }else{ # ($realORFend < $cdsExtremStart)
                    $bolean_original_is_first="false";
                    $first_end=$realORFend;
                    $second_start=$cdsExtremStart;
                  }
                  my ($newOrignal_exon_list, $newPred_exon_list) = create_two_exon_lists($tmpOmniscient, $exons_features, $first_end, $second_start, $bolean_original_is_first, $oppDir);

        ####################################
        # Remodelate ancient gene
        ####################################
                  # print "Remodelate ancient gene\n";
                  #############################################################
                  #  Remove all level3 feature execept cds
                  my @tag_list=('cds');
                  my @l2_id_list=($id_level2);
                  remove_tuple_from_omniscient(\@l2_id_list, $tmpOmniscient, 'level3', 'false', \@tag_list);
                  #############
                  # Recreate original exon 
                  @{$tmpOmniscient->{'level3'}{'exon'}{$id_level2}}=@$newOrignal_exon_list;

                  #########
                  #RE-SHAPE last/first exon if less than 3 nucleotides (1  or 2 must be romved) when the CDS finish 1 or 2 nuclotide before... because cannot be defined as UTR
                  shape_exon_extremity($newOrignal_exon_list,$cds_feature_list);
                 
                  ########
                  # calcul utr
                  print "Remodelate ancient gene\n";
                  my ($original_utr5_list, $variable_not_needed, $original_utr3_list) = modelate_utr_and_cds_features_from_exon_features_and_cds_start_stop($newOrignal_exon_list, $cdsExtremStart, $cdsExtremEnd);
                  @{$tmpOmniscient->{'level3'}{'five_prime_utr'}{$id_level2}}=@$original_utr5_list;
                  @{$tmpOmniscient->{'level3'}{'three_prime_utr'}{$id_level2}}=@$original_utr3_list;

                  ####
                  # Check existance
                  my ($new_gene, $new_mrna, $overlaping_gene_ft, $overlaping_mrna_ft) = must_be_a_new_gene_new_mrna($tmpOmniscient, $cds_feature_list, $newOrignal_exon_list);
                  if ($new_mrna){
                    #########
                    #RE-SHAPE mrna extremities
                    check_mrna_positions($level2_feature, $newOrignal_exon_list);

                  }
                  else{
                    print "*** remove IT *** because exon and CDS IDENTIK ! $id_level2 \n";
                    my @l2_feature_list=($level2_feature);
                    remove_omniscient_elements_from_level2_feature_list($tmpOmniscient, \@l2_feature_list);
                  }
                  
                  #########
                  #RE-SHAPE gene extremities
                  check_gene_positions($tmpOmniscient, $gene_id);


                  
        ###################################
        # Remodelate New Prediction
        ###################################
                  #print "\nRemodelate New Prediction\n";
                  # If newPred_exon_list list is empty we skipt the new gene modeling part
                  if(!@$newPred_exon_list){ 
                    next;
                  }
                  ###############################################
                  # modelate level3 features for new prediction #
                  my ($new_pred_utr5_list, $new_pred_cds_list, $new_pred_utr3_list) = modelate_utr_and_cds_features_from_exon_features_and_cds_start_stop($newPred_exon_list, $realORFstart, $realORFend);

                  ####################################
                  #RE-SHAPE last/first exon if less than 3 nucleotides (1  or 2 must be romved) when the CDS finish 1 or 2 nuclotide before... because cannot be defined as UTR
                  shape_exon_extremity($newPred_exon_list, $new_pred_cds_list);  

                  my @level1_list;
                  my @level2_list;
                  my @level3_list;
                  my $transcript_id = $newPred_exon_list->[0]->_tag_value('Parent');
                  #############################################
                  # Modelate gene features for new prediction #
                  
                  # $containerUsed exist when we already use the gene container. So in the case where we have only one mRNA, the split will give 2 mRNA. One is linked to the original gene container (done before)
                  # The second must be linked to a new gene container. So, even if must_be_a_new_gene method say no, we must create it because the original one has been already used.         
                  my ($new_gene, $new_mrna, $overlaping_gene_ft, $overlaping_mrna_ft) = must_be_a_new_gene_new_mrna($tmpOmniscient, $new_pred_cds_list, $newPred_exon_list);
                  if ( $new_gene ){
                    #print "create_a_new_gene for ".$transcript_id." !!!! 2\n";
                    $newcontainerUsed++;
                    $gene_id = take_care_gene_id($gene_id, $tmpOmniscient);
                    my $new_gene_feature = Bio::SeqFeature::Generic->new(-seq_id => $newPred_exon_list->[0]->seq_id, -source_tag => $newPred_exon_list->[0]->source_tag, -primary_tag => 'gene' , -start => $newPred_exon_list->[0]->start,  -end => $newPred_exon_list->[$#{$newPred_exon_list}]->end, -frame => $newPred_exon_list->[0]->frame, -strand => $newPred_exon_list->[0]->strand , -tag => { 'ID' => $gene_id }) ;
                    @level1_list=($new_gene_feature);
                    
                  }
                  else{ #the new mRNA still overlap an isoform. So we keep the link with the original gene  
                   
                    # change gene ID
                    $gene_id = $overlaping_gene_ft->_tag_value('ID');
                    #print "We use $gene_id\n";
                    check_gene_positions($tmpOmniscient, $gene_id);
                    @level1_list=($overlaping_gene_ft);
                  }

                  #############################################
                  # Modelate mRNA features for new prediction #
                  if ( $new_mrna ){
                    my $new_mRNA_feature = Bio::SeqFeature::Generic->new(-seq_id => $newPred_exon_list->[0]->seq_id, -source_tag => $newPred_exon_list->[0]->source_tag, -primary_tag => 'mRNA' , -start => $newPred_exon_list->[0]->start,  -end => $newPred_exon_list->[$#{$newPred_exon_list}]->end, -frame => $newPred_exon_list->[0]->frame, -strand => $newPred_exon_list->[0]->strand , -tag => { 'ID' => $transcript_id , 'Parent' => $gene_id }) ;
                    push (@$mRNAlistToTakeCare, lc($transcript_id));
                    @level2_list=($new_mRNA_feature);

                    @level3_list=(@$newPred_exon_list, @$new_pred_cds_list, @$new_pred_utr5_list, @$new_pred_utr3_list);
                    
                    #Save the gene (not necesserely new) and mRNA feature (necesseraly new)
                    append_omniscient($tmpOmniscient, \@level1_list, \@level2_list, \@level3_list); 

                    #Now we have the new transcript we can test the gene end and start
                    check_gene_positions($tmpOmniscient, $gene_id);
                  }
                  else{
                    print "*** Not creating mRNA *** because exon and CDS IDENTIK ! \n";
                  }


  return $mRNAlistToTakeCare;
}

# Yes if mRNA doesnt overlap an other existing isoform
# mRNA "true" true mean no overlap at CDS level
sub must_be_a_new_gene_new_mrna{
  my ($omniscient, $new_pred_cds_list, $newPred_exon_list)=@_;

  my $overlaping_mrna_ft=undef;
  my $overlaping_gene_ft=undef;
  my $Need_new_gene="true";
  my $Need_new_mRNA="true";
  my $strand=$new_pred_cds_list->[0]->strand;

  foreach my $primary_tag_key_level1 (keys %{$omniscient->{'level1'}}){ # primary_tag_key_level1 = gene or repeat etc...
    foreach my $gene_id_from_hash (keys %{$omniscient->{'level1'}{$primary_tag_key_level1}}){
      my $gene_feature= $omniscient->{'level1'}{$primary_tag_key_level1}{$gene_id_from_hash};

      if($strand eq $gene_feature->strand){
        foreach my $primary_tag_key_level2 (keys %{$omniscient->{'level2'}}){ # primary_tag_key_level1 = gene or repeat etc...
          if( exists( $omniscient->{'level2'}{$primary_tag_key_level2}{$gene_id_from_hash} )){
            foreach my $featureL2 (@{$omniscient->{'level2'}{$primary_tag_key_level2}{$gene_id_from_hash}}){

            # get level2 id
            my $featureL2_id = lc($featureL2->_tag_value('ID'));       
            my $featureL2_original_id=lc($newPred_exon_list->[0]->_tag_value('Parent'));

              if($featureL2_id ne $featureL2_original_id){

                #Now check if overlap
                my @cds_feature_list = @{$omniscient->{'level3'}{'cds'}{$featureL2_id}}; 
                my @exon_feature_list = @{$omniscient->{'level3'}{'exon'}{$featureL2_id}}; 

                my $overlap_cds = featuresList_overlap(\@cds_feature_list, $new_pred_cds_list);
                if(defined ($overlap_cds)){ #If CDS overlap
                  $Need_new_gene=undef;
                  $overlaping_gene_ft=$gene_feature;
                  #print "CDS Overlap entre $featureL2_id and $featureL2_original_id !\n";
                  if(featuresList_identik(\@cds_feature_list, $new_pred_cds_list)){
                    #print "cds identik !\n";
                    if(featuresList_identik(\@exon_feature_list, $newPred_exon_list)){                 
                      print "mRNA identik BETWEEN $featureL2_id and $featureL2_original_id \n";
                      $Need_new_mRNA=undef;
                      $overlaping_mrna_ft=$featureL2_id;
                      last;
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  return $Need_new_gene, $Need_new_mRNA, $overlaping_gene_ft, $overlaping_mrna_ft;
}

sub shape_exon_extremity{
  #exon_features is a sorted list
  #cds_features is a sorted list

  my ($exon_features,$cds_features)=@_;

   #test between first exon and first cds
   if( (abs($cds_features->[0]->start - $exon_features->[0]->start) < 3) and (abs($cds_features->[0]->start - $exon_features->[0]->start) > 0) ){ #We have to shape the exon start. We don't want a non multiple of 3 inferior to 3

      $exon_features->[0]->start($cds_features->[0]->start);
#      print "start reshaped\n";
   }
   #test between last exon and last cds
   if(abs($exon_features->[$#{ $exon_features }]->end - $cds_features->[$#{ $cds_features }]->end ) < 3){  #We have to shape the exon end
      $exon_features->[$#{ $exon_features }]->end($cds_features->[$#{ $cds_features }]->end);
#      print "end reshaped\n";
   }
}

sub calcul_real_orf_end_and_start{
  #exons_features is sorted
  my ($orf_cds_region, $exons_features)=@_;

  my $realORFstart;
  my $realORFend;

  my $orf_start=$orf_cds_region->[0]; # get start to begin
  my $orf_length=$orf_cds_region->[2]; # get lentgh to map

  my $first="yes";
  my $total_exon_length=0;
  my $total_exon_length_previous_round=0;
  my $mapped_length=0;
  my $mapped_length_total=0;
  my $the_rest_to_map=0; 

  foreach my $exon_feature (@$exons_features){   
    # Allows to follow the path on mRNA
    my $exon_length=($exon_feature->end - $exon_feature->start)+1;
    $total_exon_length_previous_round=$total_exon_length;
    $total_exon_length=$total_exon_length+$exon_length;
    # Allows to follow the path on the CDS
    $mapped_length_total=$mapped_length_total+$mapped_length;
    $the_rest_to_map=$orf_length-$mapped_length_total;
    # exon overlap CDS
    if($total_exon_length >= $orf_start){ #they begin to overlap

      if($first eq "yes"){   
        #  $realORFstart=$exon_feature->start+($orf_start - 1);
        $realORFstart=$exon_feature->start+($orf_start - $total_exon_length_previous_round );
        my $end_part_of_exon=$exon_feature->start- $realORFstart + 1;
        if($end_part_of_exon >= $orf_length){           #exon      ============================================      
           $realORFend=$realORFstart+$orf_length-1;       #cds              =========================       
           last;
         }
        $mapped_length=$exon_feature->end - $realORFstart + 1;
        $first="no";
      }
      else{
        $mapped_length=$exon_feature->end - $exon_feature->start + 1;
      }
    }
    #exon are over the end of cds => we finish at this round
    if($total_exon_length >= ($orf_start+$orf_length) ){        #exon      ============================================  
      if($realORFstart > $exon_feature->start){                 #cds       ========================= 
        $realORFend=$realORFstart+$the_rest_to_map - 1 ;
      last;
      }else{
        $realORFend=$exon_feature->start + $the_rest_to_map - 1 ;
      last;
      }
    }
  }
return $realORFstart, $realORFend;
}

sub change_strand{
  my ($feature)=@_;

  if($feature->strand eq "-" or $feature->strand eq "-1"){
    $feature->strand('+');
  }else{$feature->strand('-');}
}

# The exons containing the original cds keep their parent names. The exon containing the new cds will have a new parent name.
sub create_two_exon_lists {
  # orignalFirst == true if original gene is first on the prediction
  my ($tmpOmniscient, $exons_features, $firstEnd, $secondStart, $orignalFirst, $oppDir)=@_;
  my @list_exon_originalPred;
  my @list_exon_newPred;
  #print "firstEnd $firstEnd, secondStart $secondStart, $orignalFirst, $oppDir\n";
 
  my $value = $exons_features->[0]->_tag_value('Parent');
  my $NewParentName = take_care_mrna_id($tmpOmniscient, $value); 

  my $cptExon=1;
  foreach my $exon_feature (@$exons_features){ #for each exon
    if(two_positions_on_feature($exon_feature,$firstEnd,$secondStart)){  # We have to split the exon_feature
      my $duplicated_exon_feature=clone($exon_feature);#create a copy of the feature

      $exon_feature->end($secondStart-1);
      $duplicated_exon_feature->start($secondStart);

      if($orignalFirst eq "true"){

        push( @list_exon_originalPred, $exon_feature);

        my $value = $duplicated_exon_feature->_tag_value('ID');
        $value = take_care_level3_id($value, $cptExon);                 
        create_or_replace_tag($duplicated_exon_feature,'ID', $value);          
        create_or_replace_tag($duplicated_exon_feature,'Parent', $NewParentName);
        if($oppDir){
          change_strand($duplicated_exon_feature);
        }
        push( @list_exon_newPred, $duplicated_exon_feature);
        next;
      }else{ #original pred after
        $duplicated_exon_feature->start($secondStart-1);
        push( @list_exon_originalPred, $duplicated_exon_feature);

        my $value = $exon_feature->_tag_value('ID');
        $value = take_care_level3_id($value, $cptExon);              
        create_or_replace_tag($exon_feature,'ID', $value);  
              
        create_or_replace_tag($exon_feature,'Parent', $NewParentName);
        if($oppDir){
          change_strand($exon_feature);
        }
        push( @list_exon_newPred, $exon_feature);
        next;
      }
    }
    if(! (($exon_feature->end <=  $secondStart) and ($exon_feature->start >=  $firstEnd))){ # avoid exon between CDSs
      if ($exon_feature->end <=  $secondStart) {
        if ($orignalFirst eq "true"){
          push( @list_exon_originalPred, $exon_feature);
        }else{
          my $duplicated_exon_feature=clone($exon_feature);#create a copy of the feature
          my $value = $duplicated_exon_feature->_tag_value('ID');
          $value = take_care_level3_id($value, $cptExon);                
          create_or_replace_tag($duplicated_exon_feature,'ID', $value);             
          create_or_replace_tag($duplicated_exon_feature,'Parent', $NewParentName);
          if($oppDir){
            change_strand($duplicated_exon_feature);
          }
          push( @list_exon_newPred, $duplicated_exon_feature);
        }
      }
      if ($exon_feature->start >=  $firstEnd) { 
        if($orignalFirst eq "true"){
          my $duplicated_exon_feature=clone($exon_feature);#create a copy of the feature
          my $value = $duplicated_exon_feature->_tag_value('ID');
          $value = take_care_level3_id($value, $cptExon);             
          create_or_replace_tag($duplicated_exon_feature,'ID', $value);                 
          create_or_replace_tag($duplicated_exon_feature,'Parent', $NewParentName);
           if($oppDir){
            change_strand($duplicated_exon_feature);
          }
          push( @list_exon_newPred, $duplicated_exon_feature);
        }
        else{
          push( @list_exon_originalPred, $exon_feature);
        }
      }
    }
    if(($exon_feature->end <=  $secondStart) and ($exon_feature->start >=  $firstEnd)){ # Exon between CDSs
      if ($orignalFirst eq "true"){
        push( @list_exon_originalPred, $exon_feature);
      }else{
        my $duplicated_exon_feature=clone($exon_feature);#create a copy of the feature
        my $value = $duplicated_exon_feature->_tag_value('ID');
        $value = take_care_level3_id($value, $cptExon);                
        create_or_replace_tag($duplicated_exon_feature,'ID', $value);              
        create_or_replace_tag($duplicated_exon_feature,'Parent', $NewParentName);
        if($oppDir){
          change_strand($duplicated_exon_feature);
        }
        push( @list_exon_newPred, $duplicated_exon_feature);
      }
    }
  $cptExon++;
  }
  my @list_exon_originalPred_sorted = sort {$a->start <=> $b->start} @list_exon_originalPred;
  my @list_exon_newPred_sorted = sort {$a->start <=> $b->start} @list_exon_newPred;
  #  print "list1: @list_exon_originalPred_sorted\n";
  #  foreach my $u (@list_exon_originalPred_sorted){
  #    print $u->gff_string."\n";
  #  }
  #  print "list2: @list_exon_newPred_sorted\n";
  #  foreach my $u (@list_exon_newPred_sorted){
  #    print $u->gff_string."\n";
  # }
  return \@list_exon_originalPred_sorted, \@list_exon_newPred_sorted;
}

sub position_on_feature {

  my ($feature,$position)=@_;

  my $isOnSameExon=undef;
  if ( ($position >= $feature->start and $position <= $feature->end)){
    $isOnSameExon="true";
  }
  return $isOnSameExon;
}

sub two_positions_on_feature {

  my ($feature,$position1,$position2)=@_;

  my $areOnSameExon=undef;
  if ( ($position1 >= $feature->start and $position1 <= $feature->end) and ($position2 >= $feature->start and $position2 <= $feature->end) ){
    $areOnSameExon="true";
  }
  return $areOnSameExon;
}

sub translate_JD {
   my ($self,@args) = @_;
     my ($terminator, $unknown, $frame, $codonTableId, $complete,
     $complete_codons, $throw, $codonTable, $orf, $start_codon, $no_start_by_aa, $offset);

   ## new API with named parameters, post 1.5.1
   if ($args[0] && $args[0] =~ /^-[A-Z]+/i) {
         ($terminator, $unknown, $frame, $codonTableId, $complete,
         $complete_codons, $throw,$codonTable, $orf, $start_codon, $no_start_by_aa, $offset) =
       $self->_rearrange([qw(TERMINATOR
                                               UNKNOWN
                                               FRAME
                                               CODONTABLE_ID
                                               COMPLETE
                                               COMPLETE_CODONS
                                               THROW
                                               CODONTABLE
                                               ORF
                                               START
                                               NOSTARTBYAA
                                               OFFSET)], @args);
   ## old API, 1.5.1 and preceding versions
   } else {
     ($terminator, $unknown, $frame, $codonTableId,
      $complete, $throw, $codonTable, $offset) = @args;
   }
    
    ## Initialize termination codon, unknown codon, codon table id, frame
    $terminator = '*'    unless (defined($terminator) and $terminator ne '');
    $unknown = "X"       unless (defined($unknown) and $unknown ne '');
    $frame = 0           unless (defined($frame) and $frame ne '');
    $codonTableId = 1    unless (defined($codonTableId) and $codonTableId ne '');
    $complete_codons ||= $complete || 0;
    
    ## Get a CodonTable, error if custom CodonTable is invalid
    if ($codonTable) {
     $self->throw("Need a Bio::Tools::CodonTable object, not ". $codonTable)
      unless $codonTable->isa('Bio::Tools::CodonTable');
    } else {
        
        # shouldn't this be cached?  Seems wasteful to have a new instance
        # every time...
    $codonTable = Bio::Tools::CodonTable->new( -id => $codonTableId);
   }

    ## Error if alphabet is "protein"
    $self->throw("Can't translate an amino acid sequence.") if
    ($self->alphabet =~ /protein/i);

    ## Error if -start parameter isn't a valid codon
   if ($start_codon) {
     $self->throw("Invalid start codon: $start_codon.") if
      ( $start_codon !~ /^[A-Z]{3}$/i );
   }

   my $seq;

   if ($offset) {
    $self->throw("Offset must be 1, 2, or 3.") if
        ( $offset !~ /^[123]$/ );
    my ($start, $end) = ($offset, $self->length);
    ($seq) = $self->subseq($start, $end);
   } else {
    ($seq) = $self->seq();
   }

         ## ignore frame if an ORF is supposed to be found
   my $orf_region;
   if ( $orf ) {
            ($orf_region) = _find_orfs_nucleotide_JD( $self, $seq, $codonTable, $start_codon, $no_start_by_aa, $orf eq 'longest' ? 0 : 'first_only' );
            $seq = $self->_orf_sequence( $seq, $orf_region );
   } else {
   ## use frame, error if frame is not 0, 1 or 2
     $self->throw("Valid values for frame are 0, 1, or 2, not $frame.")
      unless ($frame == 0 or $frame == 1 or $frame == 2);
     $seq = substr($seq,$frame);
         }

    ## Translate it
    my $output = $codonTable->translate($seq, $complete_codons);
    # Use user-input terminator/unknown
    $output =~ s/\*/$terminator/g;
    $output =~ s/X/$unknown/g;

    ## Only if we are expecting to translate a complete coding region
    if ($complete) {
     my $id = $self->display_id;
     # remove the terminator character
     if( substr($output,-1,1) eq $terminator ) {
       chop $output;
     } else {
       $throw && $self->throw("Seq [$id]: Not using a valid terminator codon!");
       $self->warn("Seq [$id]: Not using a valid terminator codon!");
     }
     # test if there are terminator characters inside the protein sequence!
     if ($output =~ /\Q$terminator\E/) {
             $id ||= '';
       $throw && $self->throw("Seq [$id]: Terminator codon inside CDS!");
       $self->warn("Seq [$id]: Terminator codon inside CDS!");
     }
     # if the initiator codon is not ATG, the amino acid needs to be changed to M
     if ( substr($output,0,1) ne 'M' ) {
       if ($codonTable->is_start_codon(substr($seq, 0, 3)) ) {
         $output = 'M'. substr($output,1);
       }  elsif ($throw) {
         $self->throw("Seq [$id]: Not using a valid initiator codon!");
       } else {
         $self->warn("Seq [$id]: Not using a valid initiator codon!");
       }
     }
    }

    my $seqclass;
    if ($self->can_call_new()) {
     $seqclass = ref($self);
    } else {
     $seqclass = 'Bio::PrimarySeq';
     $self->_attempt_to_load_Seq();
    }
    my $out = $seqclass->new( '-seq' => $output,
                    '-display_id'  => $self->display_id,
                    '-accession_number' => $self->accession_number,
                    # is there anything wrong with retaining the
                    # description?
                    '-desc' => $self->desc(),
                    '-alphabet' => 'protein',
                              '-verbose' => $self->verbose
            );
    return $out, $orf_region;
}

sub concatenate_feature_list{

  my ($feature_list) = @_;

  my $seq = "";
  my $ExtremStart=1000000000000;
  my $ExtremEnd=0;

  foreach my $feature (@$feature_list) { 
#        my @values = $feature->get_tag_values('Parent');                 
#        my $parent = $values[0];
#        my @values = $feature->get_tag_values('Parent');                 
#        my $id = $values[0];
#    print $feature->primary_tag." ".$parent." ".$id."\n";
    my $start=$feature->start();
    my $end=$feature->end();
    my $seqid=$feature->seq_id();   
    $seq .= $db->seq( $seqid, $start, $end );

    if ($start < $ExtremStart){
      $ExtremStart=$start;
    }
    if($end > $ExtremEnd){
              $ExtremEnd=$end;
    }
  }
   return $ExtremStart, $seq, $ExtremEnd;
}

sub _find_orfs_nucleotide_JD {
    my ( $self, $sequence, $codon_table, $start_codon, $no_start_by_aa, $first_only ) = @_;
    $sequence    = uc $sequence;
    $start_codon = uc $start_codon if $start_codon;

    my $is_start = $start_codon
        ? sub { shift eq $start_codon }
        : sub { $codon_table->is_start_codon( shift ) };

    # stores the begin index of the currently-running ORF in each
    # reading frame
    my @current_orf_start = (-1,-1,-1);

    #< stores coordinates of longest observed orf (so far) in each
    #  reading frame
    my @orfs;

    # go through each base of the sequence, and each reading frame for each base
    my $seqlen = CORE::length $sequence;
    for( my $j = 0; $j <= $seqlen-3; $j++ ) {
        my $frame = $j % 3;

        my $this_codon = substr( $sequence, $j, 3 );
        my $AA = $codon_table->translate($this_codon);

        # if in an orf and this is either a stop codon or the last in-frame codon in the string
        if ( $current_orf_start[$frame] >= 0 ) {
            if ( _is_ter_codon_JD( $this_codon ) ||( my $is_last_codon_in_frame = ($j >= $seqlen-5)) ) {
                # record ORF start, end (half-open), length, and frame
                my @this_orf = ( $current_orf_start[$frame], $j+3, undef, $frame );
                my $this_orf_length = $this_orf[2] = ( $this_orf[1] - $this_orf[0] );

                $self->warn( "Translating partial ORF "
                                 .$self->_truncate_seq( $self->_orf_sequence( $sequence,\@ this_orf ))
                                 .' from end of nucleotide sequence'
                            )
                    if $first_only && $is_last_codon_in_frame;

                return\@ this_orf if $first_only;
                push @orfs,\@ this_orf;
                $current_orf_start[$frame] = -1;
            }
        }
        # if this is a start codon
        elsif ($is_start->($this_codon)) {
          if($no_start_by_aa){

            if($AA ne $no_start_by_aa){
              $current_orf_start[$frame] = $j;
            }
          }
          else{
            $current_orf_start[$frame] = $j;
          }
        }
    }

    return sort { $b->[2] <=> $a->[2] } @orfs;
}

# We can be sure it's a stop codon even with IUPAC
sub _is_ter_codon_JD{
  my ($codon) = @_;
  $codon=lc($codon);
  $codon =~ tr/u/t/;
  my $is_ter_codon=undef;

  if( ($codon eq 'tga') or ($codon eq 'taa') or ($codon eq 'tag') or ($codon eq 'tar') or ($codon eq 'tra') ){
    $is_ter_codon="yes";
  }
  return $is_ter_codon;
}

__END__

=head1 NAME

gff3_fixFusion.pl -
The script take a gff3 file as input. -
The script looks for other ORF in UTRs (UTR3 and UTR%) of each gene model described in the gff file.
Several ouput files will be written if you specify an output. One will contain the gene not modified (intact), 
one the gene models fixed.

=head1 SYNOPSIS

    ./gff3_fixLongestORF.pl -gff=infile.gff --fasta genome.fa [ -o outfile ]
    ./gff3_fixLongestORF.pl --help

=head1 OPTIONS

=over 8

=item B<-gff>

Input GFF3 file that will be read (and sorted)

=item B<-fa> or B<--fasta>

Genome fasta file
The name of the fasta file containing the genome to work with.

=item B<-t> or B<--threshold>

This is the minimum length of new protein predicted that will be taken in account. 
By default this value is 100 AA.

=item B<-s> or B<--stranded>

By default we predict protein in UTR3 and UTR5 and in both direction. The fusion assumed can be between gene in same direction and in opposite direction.
If RNAseq data used during the annotation was stranded, only fusion of close genes oriented in same direction are expected. In that case this option should be activated.
When activated, we will try to predict protein in UTR3 and UTR5 only in the same orientation than the gene investigated.

=item B<-o> , B<--output> , B<--out> or B<--outfile>

Output GFF file.  If no output file is specified, the output will be
written to STDOUT.

=item B<-h> or B<--help>

Display this helpful text.

=back

=cut