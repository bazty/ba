#!/usr/bin/perl -w

use strict;
use warnings;
use Switch;
use List::MoreUtils qw{ any };
use Data::Dumper qw{ Dumper };
use IO::Handle;
use Archive::Tar;

# Zeichenweise Ausgabe, statt der standardmäßigen Zeilenweise Ausgabe
STDOUT->autoflush(1);

# Die Ordnerstrukturen der TCGA-Daten muss beibehalten werden. Außerdem sollte 
# der "oberste" Ordner das Kürzel der Krebsart bekommen (z.B. PRAD).
# Überprüfung der Kommandenzeilenparameter und ggf. USAGE-Anweisung
if ($#ARGV<3) {die "\nUSAGE: perl $0 \"START PROJEKT-ID\" \"QUELLPFAD\" ".
			"\"ZIELPFAD\" \"CENTER/PLATTFORM(EN) [Opt. 1-4, mit Leerzeichen ".
			"getrennt]\" \n\t1 - BI: Genome Wide SNP 6 (.nocnv_hg19.seg.txt)\n".#, ".
			# "alternativ .hg19.seg.txt)\n".
			"\t2 - WUSM: Genome Wide SNP 6 (segmented.dat)\n".
			"\t3 - HAIB: HumanHap550 (.seg.txt)\n".
			"\t4 - HAIB: Human1MDuo (.seg.txt)\n"
}
			
# Namensgenerierung, nach Jahr, Monat, Tag und Uhrzeit und Anlegen der LOG- und Error-Datei, bzw. -Ordner
if (!-d "log") {
	mkdir "log" || die "Konnte Log-Ordner nicht anlegen!\n";
	print "log-Ordner angelegt...\n";
}
my @date = gmtime();
my $today = ($date[5]+1900).(sprintf('%02d',($date[4]+1))).(sprintf('%02d',($date[3])));
if (!-d "log/$today") {
	mkdir "log/$today" || die "Konnte Log-Unterordner nicht anlegen!\n";
	print "log-Unterordner angelegt...\n";
}
my $time = (sprintf('%02d',($date[2]))).(sprintf('%02d',($date[1])));
open (LOG, ">log/$today/$today$time"."_cnv.log") || die "Konnte Log-Datei nicht erstellen!\n";
open STDERR, ">log/$today/$today$time"."_cnv.err" || die "Konnte Error-Datei nicht erstellen!\n";

# Variabeln
# %pat = Patienten-Hash; %count = leerer Hash für die spätere Statistik;
# @dir = Array für gesamte Ordnerstruktur, Anfangs nur Quellpfad; @man = Array für Manifest;
# @line = Array von den Zeilen der Quelldatei; @patlist = Array von Patienten-IDs;
# @plat = Array von Center__Plattform; @column = Array von den Spalten der jeweiligen Zeile (Manifest/Quelle)
# @platformid = Array von FO2-Plattform-IDs (s. FO2); @tarfiles = Array von Dateien für das tar-Archiv;
# $newpath = Zielpfad; $projectid = ID des ersten Projekts; $olddir = Quellpfad;
# $dir = Jeweilige Ordnerstruktur aus @dir; $path = Dateipfad; $filepath = Pfad zur Quelldatei;
# $file = Dateiname; $patname = Gekürzte Patienten-ID & Name der Zieldatei;
# $tissue = Tumorentität; $cpl = Center__Plattform; # $kzl = Center-Plattform-Kürzel (s. BA-Tabelle 2.1);
# $redo = Redo-Boolean; $i = Zähler einer for-Schleifen;
my %pat, my %count = ();
my @dir = ($ARGV[1]), my @man, my @line, my @patlist, my @plat, my @column, my @platformid;#, my @tarfiles = ();
my $newpath = $ARGV[2], my $projectid = $ARGV[0], my $olddir = $dir[0];
my $dir, my $path, my $filepath, my $file, my $patname, my $tissue, my $cpl, my $kzl, my $redo, my $i;

# Zielordner wird angelegt
if (!-d $newpath) {
	mkdir $newpath || die "Konnte Ziel-Ordner nicht anlegen!\n";
	print "Ziel-Ordner $newpath angelegt...\n";
}

# Ordner für Dinge die direkt in das FO2-Importer-Verzeichniss kopiert werden sollen 
if (!-d "metadatas") {
	mkdir "metadatas" || die "Konnte Metadata-Ordner nicht anlegen!\n";
	print "Metadata-Ordner angelegt...\n";
}

# Bash-Datei zum Handling der verschiedenen Metadata-Dateien wird incl. Header angelegt
open (SH, ">metadatas/foi_starter.sh") || die "Konnte Shell-Datei nicht erstellen!\n";
# push @tarfiles, "metadatas/foi_starter.sh";
print SH "#!/bin/bash\n\n";
print SH "mysql -u weigel -p --socket /home/fishoracle/mysql/tmp/mysql.sock < fo2db.sql\n";

# SQL-Befehls-Datei wird angelegt
open (SQL, ">metadatas/fo2db.sql") || die "Konnte SQL-Datei nicht erstellen!\n";
# push @tarfiles, "metadatas/fo2db.sql";
print SQL "use fishoracle_pub;\n";

# Umwandlung der Optionszahl in Center und Plattform
@plat = @ARGV[3 .. @ARGV-1];
foreach (@plat){
	s/1/BI__Genome_Wide_SNP_6/;
	s/2/WUSM__Genome_Wide_SNP_6/;
	s/3/HAIB__HumanHap550/;
	s/4/HAIB__Human1MDuo/;
	$count{"$_"."_tcga"} = ();
	$count{"$_"."_focd"} = ();
	$count{"$_"."_doub"} = 0;
}

# Ordner mit Hilfe des dir-Arrays durchgehen
for $dir (@dir){
# Öffnen des jeweiligen Ordners
	if (opendir( DIR, $dir)){
# Lesen des jeweiligen Ornders
		for  (readdir(DIR)){
			next if (/^\./); #|| ($nosearch =~ /\Q$_\E/i); # Verzeichnissausschluss (optional einzukommentieren)
			$path = "$dir$_";
# Alle Unterordner werden dem dir-Array zugeführt
			push @dir ,"$path/" if (-d $path);
# Öffnen der Manifest-Datei, sofern im jeweiligen Ornder vorhanden und Überschreiben des Inhalts in das man-Array
			if ((-f $path) && ($path =~ m/manifest/i)){
				print LOG "$dir ...\n";
				open (MAN, "<$path") || die "Konnte Manifest-Datei nicht öffnen";
				print "Manifestdatei gefunden in $dir\n";
				@man = <MAN>;
				close (MAN);
# Den Patienten-Hash, PlattformID-Array neu anlegen, bzw. leeren, sowie den Redo-Boolean zurücksetzen
				%pat = ();
				@platformid = ();
				$redo = 0;
# Tumorentität aus dem Pfad bekommen
				$tissue = $dir;
				$tissue =~ s/$olddir//;
				chop($tissue);
# Ordner für Tumorentität wird im Zielordner angelegt
				$newpath = "$newpath$tissue";
				if (!-d "$newpath/"){
					mkdir "$newpath/" || die "Konnte Ziel-Ordner nicht anlegen!\n";
					print "Unterordner $tissue wurde im Zielordner erstellt.\n";
				}
# Metadata-Datei wird incl. Header angelegt
				open (META, ">metadatas/$tissue\_metadata.csv") || die "Konnte Meta-Datei nicht erstellen";
				print (META "CREATE_STUDY\tDATA_PATH\tIMPORT_TYPE\tSUB_TYPE\tPROJECT_ID\tASSEMBLY\tDESCRIPTION\tORGAN_ID\tPLATFORM_ID\n");
				print (SH "echo \"Starte den Import von $tissue...\"\nmv $tissue\_metadata.csv metadata.csv\njava -jar fo_importer.jar\n"); 
# Die Manifestdatei wird Zeilenweise durchgegangen
				for (@man){
# Zeile wird in ihre Spalten gesplitet
					@column = split (/\t/,$_);
# Überprüfen, ob die Zeile die richtige Methode (SNP-Arrays), Center + Plattform (aus Plattform-Array) und Dateiendung (-> sel_file) beinhaltet
					next if ($column[0] !~ m/SNP/i);
					next if !(any {$_ eq "$column[1]__$column[2]"} @plat);
					next if !(sel_file($column[6],$column[1],$column[2],$dir));
# Patienten-IDs in ein Array übertragen
					@patlist = split (/\//,$column[5]);
# Patienten-IDs kürzen (Analyte-Plate-Center-Suffix enfernt), Array manipulieren und Center + Plattform dem Patienten-Hash anfügen
#					@patlist = del_wroti(\@patlist);
					next if !(@patlist);
					@patlist = &del_doub(@patlist);
					chomp($column[6]);
					@patlist = sort @patlist;
					@patlist = ($patlist[0]) if ($column[2] =~ m/Genome_Wide_SNP_6/);
					@{$pat{$column[6]}} = @patlist;
					unshift (@{$pat{$column[6]}},$column[1],$column[2]);
					$count{"$column[1]__$column[2]\_focd"}{$tissue} = 0;
					$count{"$column[1]__$column[2]\_tcga"}{$tissue} = 0;
				}
# Dateibearbeitung initiieren
				foreach $file (sort keys %pat){
					$filepath = "$dir"."CNV_SNP_Array/CENTER__PLATFORM/Level_3";
					$filepath =~ s/CENTER/$pat{$file}[0]/;
					$filepath =~ s/PLATFORM/$pat{$file}[1]/;
					$cpl = "$pat{$file}[0]__$pat{$file}[1]";
# Center_Plattform zum PlattformID-Array hinzufügen, wenn noch nicht vorhanden
					push (@platformid,$cpl) unless(grep($_ eq $cpl, @platformid));
					print LOG "\t.. $file >>\n";
# Datei öffnen und Inhalt Zeilenweise in ein Array einlesen
					open (DATA, "<$filepath/$file") || die "Datei \"$file\" nicht gefunden!";
					@line = <DATA>;
					close (DATA);
					$count{"$cpl\_tcga"}{$tissue}++;
					print ":";
# Patienten Arrays des Patienten-Hash durchgehen [Start erst bei [2], da [0] = Center und [1] = Plattform
					for ($i = 2; $i < @{$pat{$file}}; $i++) {
# Redos kennzeichnen
						$patname = substr($pat{$file}[$i],5,-16);
						$kzl = cplkzl($cpl);
						$patname = "RE\_$patname" if ($file =~ m/redo/i);
						if (-e "$newpath/$cpl/$tissue\_$patname\_$kzl.focd"){
							$count{"$cpl\_doub"}++;
							print "!";
							print LOG "\t\t>! $patname vorhanden.\n";
							next;
						}
# Erstellen einer focd-Datei
						if (!-d "$newpath/$cpl/"){
							mkdir "$newpath/$cpl/" || die "Konnte Ziel-Ordner nicht anlegen!\n";
						}
						if ($file =~ m/redo/i){
							if (!-d "$newpath/REDO/"){
								mkdir "$newpath/REDO/" || die "Konnte REDO-Ordner nicht anlegen!\n";
							}
							if (!-d "$newpath/REDO/$cpl/"){
								mkdir "$newpath/REDO/$cpl/" || die "Konnte REDO-Ordner nicht anlegen!\n";
							}
							if (-e "$newpath/REDO/$cpl/$tissue\_$patname\_$kzl.focd"){
								$count{"$cpl\_doub"}++;
								print "!";
								print LOG "\t\t>! $patname vorhanden.\n";
								next;
							}
							print LOG "\t\t>$tissue\_$patname\_$kzl.focd\n";
							open (NEWFILE, ">$newpath/REDO/$cpl/$tissue\_$patname\_$kzl.focd") || die "Konnte focd-Datei (s. letzter Eintrag in der Log-Datei) nicht erstellen.\n";
						} else {
							print LOG "\t\t>$tissue\_$patname\_$kzl.focd\n";
							open (NEWFILE, ">$newpath/$cpl/$tissue\_$patname\_$kzl.focd") || die "Konnte focd-Datei (s. letzter Eintrag in der Log-Datei) nicht erstellen.\n";
						}
						print ".";
# focd-Datei-Header
						shift (@line);
						print NEWFILE "chrom\tloc.start\tloc.end\tnum.mark\tseg.mean\n";
# Quelldateiinhalt Zeilenweise auslesen
						foreach (@line){
# Jede Zeile in die jeweilige focd-Datei des Patienten schreiben, ggf. eine leere Spalte [4/num.mark] hinzufügen
							$_ =~ s/1e\+05/100000/;
							$_ =~ s/1e\+04/10000/;
							$_ =~ s/1e\+03/1000/;
							$_ =~ s/1e\+02/100/;
							@column = split(/\t/,$_);
							if (@column == 5) {
								if (@{$pat{$file}} > 3){
									print NEWFILE "$column[1]\t$column[2]\t$column[3]\t0\t$column[4]" if $column[0] =~ m/$patname/;
								} else {
									print NEWFILE "$column[1]\t$column[2]\t$column[3]\t0\t$column[4]";
								}
							} elsif (@column == 6) {
								if (@{$pat{$file}} > 3){
									print NEWFILE "$column[1]\t$column[2]\t$column[3]\t$column[4]\t$column[5]" if $column[0] =~ m/$patname/;
								} else {
									print NEWFILE "$column[1]\t$column[2]\t$column[3]\t$column[4]\t$column[5]";
								}
							} else {print "Falsches Dateiformatierung!\n";}
						}
						if (close (NEWFILE)){
							$count{"$cpl\_focd"}{$tissue}++;
						}
					}
				}
# Metadata-Datei wird mit den jeweiligen erstellten Zielunterordnern und den zugehörigen Informationen für FO2 befüllt
# SQL-Befehle zur Erstellung der Datenbankeinträge werden in die fo2db.sql geschrieben, passend zur Metadata
				foreach (@platformid){
					print META "TRUE\tdata/tcga_pub/CNV/$tissue/$_\tSegments\tcnv_intensity\t$projectid\tGrCh37\t\t".
							organid("$tissue")."\t".platformid("$_")."\n";
					print SQL "insert project VALUES ($projectid, \"$tissue (".cplkzl($_).")\", \"".cancer($tissue)."\");\n";
					$projectid++;
					if (-d "$newpath/REDO/$_/"){
						print META "TRUE\tdata/tcga_pub/CNV/$tissue/REDO/$_\tSegments\tcnv_intensity\t$projectid\tGrCh37\t\t".
								organid("$tissue")."\t".platformid("$_")."\n";
						print SQL "insert project VALUES ($projectid, \"$tissue (".cplkzl($_)." - redo)\", \"REDOs\");\n";
						$redo = 1;
						$projectid++;
					}
				}
				$newpath = $ARGV[2];
				print "fertig";
				print " (REDOs vorhanden, extra REDO-Ordner ggf. angelegt)" if ($redo == 1);
				print "\n";
				print "\tmetadata.csv angelegt.\n" if close(META);
				print "\n";
			}
		}
	close(DIR);
	}else{
		print "Fehler in $dir  $!\n";
	}
}

# Diese Funktion prüft nach der richtigen Dateiendung
sub sel_file {
	my $filename = shift;
	my $center = shift;
	my $platform = shift;
	my $fdir = shift;
	my $sel = 0;
	switch ($platform){
		case "Genome_Wide_SNP_6" {
			switch ($center){
				case "BI" {
					if ($filename =~ m/\.nocnv_hg19\.seg\.txt/) {$sel = 1;} 
					# } elsif ($filename =~ m/\.hg19\.seg\.txt/) {
					# 	$sel = 1;
					# 	$filename =~ s/\.hg19\.seg\.txt/\.nocnv_hg19\.seg\.txt/;
					# 	$filename = "$fdir"."CNV_SNP_Array/$center"."__$platform/Level_3/$filename";
					# 	chomp($filename);
					# 	$sel = 0 if (-e $filename);
					# }
				}
				case "WUSM" {
					if ($filename =~ m/\.segmented\.dat/) {$sel = 1;}
				}
			}
		}
		case "HumanHap550" {
			if ($filename =~ m/\.seg\.txt/) {$sel = 1;}
		}
		case "Human1MDuo" {
			if ($filename =~ m/\.seg\.txt/) {$sel = 1;}
		}
	}
	return $sel;
}

# Bildung des Center-Plattform-Kürzel
sub cplkzl {
	my $cplkzl = shift;
	$cplkzl =~ s/BI__Genome_Wide_SNP_6/BGW6/;
	$cplkzl =~ s/HAIB__HumanHap550/HHH5/;
	$cplkzl =~ s/HAIB__Human1MDuo/HH1M/;
	$cplkzl =~ s/WUSM__Genome_Wide_SNP_6/WGW6/;
	return "$cplkzl";
}

# Ermittlung und Übergabe der FO2-Plattform-ID
sub platformid {
	my $pfid = shift;
	$pfid =~ s/BI__Genome_Wide_SNP_6/7/;
	$pfid =~ s/HAIB__HumanHap550/8/;
	$pfid =~ s/HAIB__Human1MDuo/9/;
	$pfid =~ s/WUSM__Genome_Wide_SNP_6/10/;
	return "$pfid";
}

# Ermittlung und Übergabe der FO2-Organ-ID
sub organid {
	my $organ = shift;
	$organ =~ s/PRAD/1/;	# Prostate adenocarcinoma
	$organ =~ s/KICH/3/;	# Kidney Chromophobe
	$organ =~ s/KIRP/3/;	# Kidney renal papillary cell carcinoma [?]
	$organ =~ s/KIRC/3/;	# Kidney renal clear cell carcinoma
	$organ =~ s/ESCA/5/;	# Esophageal carcinoma
	$organ =~ s/PAAD/7/;	# Pancreatic adenocarcinoma
	$organ =~ s/LUAD/9/;	# Lung adenocarcinoma
	$organ =~ s/LUSC/9/;	# Lung squamous cell carcinoma
	$organ =~ s/COAD/11/;	# Colon adenocarcinoma
	$organ =~ s/BRCA/13/;	# Breast invasive carcinoma
	$organ =~ s/UCEC/19/;	# Uterine Corpus Endometrial Carcinoma
	$organ =~ s/DLBC/23/;	# Lymphoid Neoplasm Diffuse Large B Cell Carcinoma
	$organ =~ s/BLCA/25/;	# Bladder Urothelial Carcinoma
	$organ =~ s/LIHC/27/;	# Liver hepatocellular carcinoma
	$organ =~ s/LAML/29/;	# Acute Myeloid Leukemia
	$organ =~ s/ACC/31/;	# Adrenocortical carcinoma
	$organ =~ s/CESC/19/;	# Cervical squamous cell carcinoma and endocervical adenocarcinoma
	$organ =~ s/CHOL/33/;	# Cholangiocarcinoma
	$organ =~ s/GBM/35/;	# Glioblastoma multiforme
	$organ =~ s/LGG/35/;	# Brain Lower Grade Glioma
	$organ =~ s/HNSC/37/;	# Head and Neck squamous cell carcinoma
	$organ =~ s/MESO/39/;	# Mesothelioma
	$organ =~ s/OV/41/;		# Serous cystadenocarcinoma
	$organ =~ s/PCPG/31/;	# Pheochromocytoma and Paraganglioma
	$organ =~ s/SARC/43/;	# Sarcoma
	$organ =~ s/READ/45/;	# Rectum adenocarcinoma
	$organ =~ s/STAD/45/;	# Stomach adenocarcinoma
	$organ =~ s/THCA/47/;	# Thyroid carcinoma
	$organ =~ s/UCS/19/;	# Uterine Carcinosarcoma
	$organ =~ s/UVM/51/;	# Uveal Melanoma
	$organ =~ s/SKCM/49/;	# Skin Cutaneous Melanoma
	return "$organ";
}

# Ermittlung und Übergabe der Tumorentität (Beschreibung für das Projekt)
sub cancer {
	my $cancer = shift;
	$cancer =~ s/READ/Rectum adenocarcinoma - Darmkrebs/;
	$cancer =~ s/THCA/Thyroid carcinoma - Schilddrüsenkrebs/;
	$cancer =~ s/BLCA/Bladder Urothelial Carcinoma - Harnblasenkrebs/;
	$cancer =~ s/COAD/Colon adenocarcinoma - Darmkrebs/;
	$cancer =~ s/LUSC/Lung squamous cell carcinoma - Lungenkrebs/;
	$cancer =~ s/OV/Ovarian serous cystadenocarcinoma - Eierstockkrebs/;
	$cancer =~ s/PRAD/Prostate adenocarcinoma - Prostatakrebs/;
	$cancer =~ s/ESCA/Esophageal carcinoma - Speiseröhrenkrebs/;
	$cancer =~ s/HNSC/Head and neck squamous cell carcinoma - Kopf-Hals-Karzinom/;
	$cancer =~ s/KIRC/Kidney renal clear cell carcinoma - Nierenkrebs/;
	$cancer =~ s/SKCM/Skin Cutaneous Melanoma - Hautkrebs/;
	$cancer =~ s/SARC/Sarcoma - Sarkom (Binde-\/Stütz-\/Muskelgewebe)/;
	$cancer =~ s/UCS/Uterine Carcinosarcoma - Müllerscher Mischtumor/;
	$cancer =~ s/STAD/Stomach adenocarcinoma - Magenkrebs/;
	$cancer =~ s/KICH/Kidney Chromophobe - Nierenkrebs/;
	$cancer =~ s/KIRP/Kidney renal papillary cell carcinoma - Nierenkrebs/;
	$cancer =~ s/LGG/Brain Lower Grade Glioma - Gliom (Hirntumor)/;
	$cancer =~ s/UCEC/Uterine Corpus Endometrial Carcinoma - Gebärmutterhalskrebs/;
	$cancer =~ s/PAAD/Pancreatic adenocarcinoma - Pankreaskrebs/;
	$cancer =~ s/CESC/Cervical squamous cell carcinoma ans endocervical adenocarcinoma - Plattenepithel- und Gebärmutterhalskrebs/;
	$cancer =~ s/DLBC/Lymphoid Neoplasm Diffuse Large B-cell Lymphoma - Lymphdrüsenkrebs/;
	$cancer =~ s/GBM/Glioblastoma multiforme - Glioblastom (Hirntumor)/;
	$cancer =~ s/LUAD/Lung adenocarcinoma - Lunkenkrebs/;
	$cancer =~ s/MESO/Mesothelioma - Mesotheliom (unlokalisiert)/;
	$cancer =~ s/PCPG/Pheochromocytoma and Paraganglioma - Nebennierenkrebs/;
	$cancer =~ s/BRCA/Breast invasive carcinoma - Brustkrebs/;
	$cancer =~ s/ACC/Adrenocortical carcinoma - Nebennierenrindenkarzinom/;
	$cancer =~ s/LAML/Acute Myeloid Leukemia - Leukämie/;
	$cancer =~ s/UVM/Uveal Melanoma/;
	$cancer =~ s/CHOL/Cholangiocarcinoma/;
	$cancer =~ s/LIHC/Liver hepatocellular carcinoma/;
	return "$cancer";
}

# Falsche Probensorte löschen
sub del_wroti {
	my $array = shift;
	my @all = @{$array};
	my @new = ();
	foreach (@all){
		$_ =~ m/\w{4}-(\d{1})\d[A-Z]-/;
		push (@new, $_) if ($1 eq "0");
	}
	return @new;
}


# Doppelte eines Array löschen
sub del_doub {
	my %all;
	grep {$all{$_}=0} @_;
	return (keys %all);
}

# Endoperationen: Zählstatistik ausgeben & Log- und Error-Datei abspeichern
$Data::Dumper::Sortkeys = 1;
close(SH);
print "\tfoi_starter.sh erstellt.\n";
close(SQL);
print "\tfo2db.sql erstellt.\n";
#Archive::Tar->create_archive( $ARGV[2]."metadatas.tar.gz", 9, @tarfiles ) || die("Konnte Archiv nicht erstellen\n");
#Archive::Tar->create_archive( 'CNV.tar.gz', 9, "$ARGV[2]") || die("Konnte Archiv nicht erstellen\n");
#print "\tCNV-Archiv erstellt.\n";
print (LOG Dumper(\%count));
print LOG "---\n";
close(LOG);
print "\t$today"."_cnv.log erstellt.\n";
print STDERR "---\n";
close(STDERR);
print "\t$today"."_cnv.err erstellt.\n";
print "[FERTIG]\n\n";
