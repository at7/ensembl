#
# EnsEMBL module for Bio::EnsEMBL::DBSQL::CoordSystemAdaptor
#
#

=head1 NAME

Bio::EnsEMBL::DBSQL::CoordSystemAdaptor

=head1 SYNOPSIS

  my $db = Bio::EnsEMBL::DBSQL::DBAdaptor->new(...);

  my $csa = $db->get_CoordSystemAdaptor();

  #
  # Get all coord systems in the database:
  #
  foreach my $cs (@{$csa->fetch_all()}) {
    print $cs->name, ' ',  $cs->version, "\n";
  }

  #
  # Fetching by name:
  #

  #use the default version of coord_system 'chromosome' (e.g. NCBI33):
  $cs = $csa->fetch_by_name('chromosome');

  #get an explicit version of coord_system 'chromosome':
  $cs = $csa->fetch_by_name('chromsome', 'NCBI34');

  #get all coord_systems of name 'chromosome':
  foreach $cs (@{$csa->fetch_all_by_name('chromosome')}) {
     print $cs->name, ' ', $cs->version, "\n";
  }

  #
  # Fetching by rank:
  #
  $cs = $csa->fetch_by_rank(2);

  #
  # Fetching the pseudo coord system 'toplevel'
  #

  #Get the default top_level coord system:
  $cs = $csa->fetch_top_level();

  #can also use an alias in fetch_by_name:
  $cs = $csa->fetch_by_name('toplevel');

  #can also request toplevel using rank=0
  $cs = $csa->fetch_by_rank(0);

  #
  # Fetching by sequence level:
  #

  #Get the coord system which is used to store sequence:
  $cs = $csa->fetch_sequence_level();

  #can also use an alias in fetch_by_name:
  $cs = $csa->fetch_by_name('seqlevel');

  #
  # Fetching by id
  #
  $cs = $csa->fetch_by_dbID(1);


=head1 DESCRIPTION

This adaptor allows the querying of information from the coordinate system
adaptor.

Note that many coordinate systems do not have a concept of a version
for the entire coordinate system (though they may have a per-sequence version).
The 'chromosome' coordinate system usually has a version (i.e. the
assembly version) but the clonal coordinate system does not (despite having
individual sequence versions).  In the case where a coordinate system does
not have a version an empty string ('') is used instead.

=head1 AUTHOR - Graham McVicker

=head1 CONTACT

Post questions to the EnsEMBL development list ensembl-dev@ebi.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::DBSQL::CoordSystemAdaptor;

use Bio::EnsEMBL::DBSQL::BaseAdaptor;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::CoordSystem;

use vars qw(@ISA);

@ISA = qw(Bio::EnsEMBL::DBSQL::BaseAdaptor);


=head2 new

  Arg [1]    : See BaseAdaptor for arguments (none specific to this
               subclass)
  Example    : $cs = $db->get_CoordSystemAdaptor(); #better than new()
  Description: Creates a new CoordSystem adaptor and caches the contents
               of the coord_system table in memory.
  Returntype : Bio::EnsEMBL::DBSQL::CoordSystemAdaptor
  Exceptions : none
  Caller     :

=cut

sub new {
  my $caller = shift;

  my $class = ref($caller) || $caller;

  my $self = $class->SUPER::new(@_);

  #
  # Cache the entire contents of the coord_system table cross-referenced
  # by dbID and name
  #

  #keyed on name, list of coord_system value
  $self->{'_name_cache'} = {};

  #keyed on id, coord_system value
  $self->{'_dbID_cache'} = {};

  #keyed on rank
  $self->{'_rank_cache'} = {};

  #keyed on id, 1/undef values
  $self->{'_is_sequence_level'} = {};
  $self->{'_is_default_version'} = {};

  my $sth = $self->prepare(
    'SELECT coord_system_id, name, rank, version, attrib ' .
    'FROM coord_system');
  $sth->execute();

  my ($dbID, $name, $rank, $version, $attrib);
  $sth->bind_columns(\$dbID, \$name, \$rank, \$version, \$attrib);

  while($sth->fetch()) {
    my $seq_lvl = 0;
    my $default = 0;
    if($attrib) {
      foreach my $attrib (split(',', $attrib)) {
        $self->{"_is_$attrib"}->{$dbID} = 1;
        if($attrib eq 'sequence_level') {
          $seq_lvl = 1;
        } elsif($attrib eq 'default_version') {
          $default = 1;
        }
      }
    }

    my $cs = Bio::EnsEMBL::CoordSystem->new
      (-DBID           => $dbID,
       -ADAPTOR        => $self,
       -NAME           => $name,
       -VERSION        => $version,
       -RANK           => $rank,
       -SEQUENCE_LEVEL => $seq_lvl,
       -DEFAULT        => $default);

    $self->{'_dbID_cache'}->{$dbID} = $cs;

    $self->{'_name_cache'}->{lc($name)} ||= [];
    $self->{'_rank_cache'}->{$rank} = $cs;
    push @{$self->{'_name_cache'}->{lc($name)}}, $cs;
  }
  $sth->finish();

  #
  # Retrieve the list of the coordinate systems that features are stored in
  # and cache them
  #
  $sth = $self->prepare('SELECT table_name, coord_system_id FROM meta_coord');
  $sth->execute();
  while(my ($table_name, $dbID) = $sth->fetchrow_array()) {
    $self->{'_feature_cache'}->{lc($table_name)} ||= [];
    my $cs = $self->{'_dbID_cache'}->{$dbID};
    if(!$cs) {
      throw("meta_coord table refers to non-existant coord_system id=[$dbID]");
    }
    push @{$self->{'_feature_cache'}->{lc($table_name)}}, $cs;
  }
  $sth->finish();

  #
  # Retrieve a list of available mappings from the meta table.
  # this may eventually be moved a table of its own if this proves too
  # cumbersome
  #

  my %mappings;
  my $mc = $self->db()->get_MetaContainer();
  foreach my $map_pair (@{$mc->list_value_by_key('assembly.mapping')}) {
    my ($asm,$cmp) = split(/\|/, $map_pair);
    if(!$cmp || !$cmp) {
      throw('incorrectly formatted assembly.mapping values in meta table');
    }
    my($asm_name, $asm_version) = split(/:/, $asm);
    my($cmp_name, $cmp_version) = split(/:/, $cmp);

    my $cmp_cs = $self->fetch_by_name($cmp_name,$cmp_version);
    my $asm_cs = $self->fetch_by_name($asm_name,$asm_version);

    $mappings{$asm_cs->dbID} ||= {};
    $mappings{$asm_cs->dbID}->{$cmp_cs->dbID} = 1;
  }

  #
  # Create the pseudo coord system 'toplevel' and cache it so that
  # only one of these is created for each db...
  #
  my $toplevel = Bio::EnsEMBL::CoordSystem->new(-TOP_LEVEL => 1,
                                                -NAME      => 'toplevel',
                                                -ADAPTOR   => $self);
  $self->{'_top_level'} = $toplevel;

  $self->{'_mapping_paths'} = \%mappings;

  return $self;
}



=head2 fetch_all

  Arg [1]    : none
  Example    : foreach my $cs (@{$csa->fetch_all()}) {
                 print $cs->name(), ' ', $cs->version(), "\n";
               }
  Description: Retrieves every coordinate system defined in the DB.
               These will be returned in ascending order of rank. I.e.
               The highest coordinate system with rank=1 would be first in the
               array.
  Returntype : listref of Bio::EnsEMBL::CoordSystems
  Exceptions : none
  Caller     : general

=cut

sub fetch_all {
  my $self = shift;

  my @coord_systems;

  #order the array by rank in ascending order
  foreach my $rank (sort {$a <=> $b} keys %{$self->{'_rank_cache'}}) {
    push @coord_systems, $self->{'_rank_cache'}->{$rank};
  }

  return \@coord_systems;
}



=head2 fetch_by_rank

  Arg [1]    : int $rank
  Example    : my $cs = $coord_sys_adaptor->fetch_by_rank(1);
  Description: Retrieves a CoordinateSystem via its rank. 0 is a special
               rank reserved for the pseudo coordinate system 'toplevel'.
               undef is returned if no coordinate system of the specified rank
               exists.
  Returntype : Bio::EnsEMBL::CoordSystem
  Exceptions : none
  Caller     : general

=cut

sub fetch_by_rank {
  my $self = shift;
  my $rank = shift;

  throw("Rank argument must be defined.") if(!defined($rank));
  throw("Rank argument must be a non-negative integer.") if($rank !~ /^\d+$/);

  if($rank == 0) {
    return $self->fetch_top_level();
  }

  return $self->{'_rank_cache'}->{$rank};
}


=head2 fetch_by_name

  Arg [1]    : string $name
               The name of the coordinate system to retrieve.  Alternatively
               this may be an alias for a real coordinate system.  Valid
               aliases are 'toplevel' and 'seqlevel'.
  Arg [2]    : string $version (optional)
               The version of the coordinate system to retrieve.  If not
               specified the default version will be used.
  Example    : $coord_sys = $csa->fetch_by_name('clone');
               $coord_sys = $csa->fetch_by_name('chromosome', 'NCBI33');
               # toplevel is an pseudo coord system representing the highest
               # coord system in a given region
               # such as the chromosome coordinate system
               $coord_sys = $csa->fetch_by_name('toplevel');
               #seqlevel is an alias for the sequence level coordinate system
               #such as the clone or contig coordinate system
               $coord_sys = $csa->fetch_by_name('seqlevel');
  Description: Retrieves a coordinate system by its name
  Returntype : Bio::EnsEMBL::CoordSystem
  Exceptions : throw if no name argument provided
               warning if no version provided and default does not exist
  Caller     : general

=cut

sub fetch_by_name {
  my $self = shift;
  my $name = lc(shift); #case insensitve matching
  my $version = shift;

  throw('Name argument is required.') if(!$name);

  $version = lc($version) if($version);


  if($name eq 'seqlevel') {
    return $self->fetch_sequence_level();
  } elsif($name eq 'toplevel') {
    return $self->fetch_top_level($version);
  }

  if(!exists($self->{'_name_cache'}->{$name})) {
    if($name =~ /top/) {
      warning("Did you mean 'toplevel' coord system instead of '$name'?");
    } elsif($name =~ /seq/) {
      warning("Did you mean 'seqlevel' coord system instead of '$name'?");
    }
    return undef;
  }

  my @coord_systems = @{$self->{'_name_cache'}->{$name}};

  foreach my $cs (@coord_systems) {
    if($version) {
      return $cs if(lc($cs->version()) eq $version);
    } elsif($self->{'_is_default_version'}->{$cs->dbID()}) {
      return $cs;
    }
  }

  if($version) {
    #the specific version we were looking for was not found
    return undef;
  }

  #didn't find a default, just take first one
  my $cs =  shift @coord_systems;
  my $v = $cs->version();
  warning("No default version for coord_system [$name] exists. " .
      "Using version [$v] arbitrarily");

  return $cs;
}


=head2 fetch_all_by_name

  Arg [1]    : string $name
               The name of the coordinate system to retrieve.  This can be
               the name of an actual coordinate system or an alias for a
               coordinate system.  Valid aliases are 'toplevel' and 'seqlevel'.
  Example    : foreach my $cs (@{$csa->fetch_all_by_name('chromosome')}){
                 print $cs->name(), ' ', $cs->version();
               }
  Description: Retrieves all coordinate systems of a particular name
  Returntype : listref of Bio::EnsEMBL::CoordSystem objects
  Exceptions : throw if no name argument provided
  Caller     : general

=cut

sub fetch_all_by_name {
  my $self = shift;
  my $name = lc(shift); #case insensitive matching

  throw('Name argument is required') if(!$name);

  if($name eq 'seqlevel') {
    return [$self->fetch_sequence_level()];
  } elsif($name eq 'toplevel') {
    return [$self->fetch_top_level()];
  }

  return $self->{'_name_cache'}->{$name} || [];
}




=head2 fetch_all_by_feature_table

  Arg [1]    : string $table - the name of the table to retrieve coord systems
               for
  Example    : my @coord_systems = $csa->fetch_by_feature_table('gene')
  Description: This retrieves the list of coordinate systems that features
               in a particular table are stored.  It is used internally by
               the API to perform queries to these tables and to ensure that
               features are only stored in appropriate coordinate systems.
  Returntype : listref of Bio::EnsEMBL::CoordSystem objects
  Exceptions : none
  Caller     : BaseFeatureAdaptor

=cut

sub fetch_all_by_feature_table {
  my $self = shift;
  my $table = lc(shift); #case insensitive matching

  throw('Name argument is required') unless $table;

  my $result = $self->{'_feature_cache'}->{$table};

  if(!$result) {
    throw("Feature table [$table] does not have a defined coordinate system" .
          " in the meta_coord table");
  }

  return $result;
}


=head2 add_feature_table

  Arg [1]    : Bio::EnsEMBL::CoordSystem $cs
               The coordinate system to associate with a feature table
  Arg [2]    : string $table - the name of the table in which features of
               a given coordinate system will be stored in
  Example    : $csa->add_feature_table($chr_coord_system, 'gene');
  Description: This function tells the coordinate system adaptor that
               features from a specified table will be stored in a certain
               coordinate system.  If this information is not already stored
               in the database it will be added.
  Returntype : none
  Exceptions : none
  Caller     : BaseFeatureAdaptor

=cut


sub add_feature_table {
  my $self = shift;
  my $cs   = shift;
  my $table = lc(shift);

  if(!ref($cs) || !$cs->isa('Bio::EnsEMBL::CoordSystem')) {
    throw('CoordSystem argument is required.');
  }

  if(!$table) {
    throw('Table argument is required.');
  }

  my $coord_systems = $self->{'_feature_cache'}->{$table};

  my ($exists) = grep {$_->equals($cs)} @$coord_systems;

  #do not do anything if this feature table is already associated with the
  #coord system
  return if($exists);

  #make sure to use a coord system stored in this database so that we
  #do not use the wrong coord_system_id
  if(!$cs->is_stored($self->db())) {
    $cs = $self->fetch_by_name($cs->name(), $cs->version);
    throw("CoordSystem not found in database.");
  }

  #store the new tablename -> coord system relationship in the db
  #ignore failures b/c during the pipeline multiple processes may try
  #to update this table and only the first will be successful
  my $sth = $self->prepare('INSERT IGNORE INTO meta_coord ' .
                              'SET coord_system_id = ?, ' .
                                  'table_name = ?');

  $sth->execute($cs->dbID, $table);

  #update the internal cache
  $self->{'_feature_cache'}->{$table} ||= [];
  push @{$self->{'_feature_cache'}->{$table}}, $cs;

  return;
}



=head2 fetch_by_dbID

  Arg [1]    : int dbID
  Example    : $cs = $csa->fetch_by_dbID(4);
  Description: Retrieves a coord_system via its internal
               identifier, or undef if no coordinate system with the provided
               id exists.
  Returntype : Bio::EnsEMBL::CoordSystem or undef
  Exceptions : thrown if no coord_system exists for specified dbID
  Caller     : general

=cut

sub fetch_by_dbID {
  my $self = shift;
  my $dbID = shift;

  throw('dbID argument is required') if(!$dbID);

  my $cs = $self->{'_dbID_cache'}->{$dbID};

  return undef if(!$cs);

  return $cs;
}



=head2 fetch_top_level

  Arg [1]    : none
  Example    : $cs = $csa->fetch_top_level();
  Description: Retrieves the toplevel pseudo coordinate system.
  Returntype : a Bio::EnsEMBL::CoordSystem object
  Exceptions : none
  Caller     : general

=cut

sub fetch_top_level {
  my $self = shift;

  return $self->{'_top_level'};
}


=head2 fetch_sequence_level

  Arg [1]    : none
  Example    : ($id, $name, $version) = $csa->fetch_sequence_level();
  Description: Retrieves the coordinate system at which sequence
               is stored at.
  Returntype : Bio::EnsEMBL::CoordSystem
  Exceptions : throw if no sequence_level coord system exists at all
               throw if multiple sequence_level coord systems exists
  Caller     : general

=cut

sub fetch_sequence_level {
  my $self = shift;

  my @dbIDs = keys %{$self->{'_is_sequence_level'}};

  throw('No sequence_level coord_system is defined') if(!@dbIDs);

  if(@dbIDs > 1) {
    throw('Multiple sequence_level coord_systems are defined.' .
          'Only one is currently supported');
  }

  return $self->{'_dbID_cache'}->{$dbIDs[0]};
}




=head2 get_mapping_path

  Arg [1]    : Bio::EnsEMBL::CoordSystem $cs1
  Arg [2]    : Bio::EnsEMBL::CoordSystem $cs2
  Example    : foreach my $cs @{$csa->get_mapping_path($cs1,$cs2);
  Description: Given two coordinate systems this will return a mapping path
               between them.  The path is formatted as a list of coordinate
               systems starting with the assembled coord systems and
               descending through component systems.  For example, if the
               following mappings were defined in the meta table:
               chromosome -> clone
               clone -> contig

               And the contig and chromosome coordinate systems where
               provided as arguments like so:
               $csa->get_mapping_path($chr_cs,$ctg_cs);

               The return values would be:
               [$chr_cs, $clone_cs, $contig_cs]

               The return value would be the same even if the order of
               arguments was reversed.

	       This becomes a bit more problematic when the relationship is
               something like:
               chromosome -> contig
               clone      -> contig

               In this case the contig coordinate system is the component
               coordinate system for both mappings and for the following
               request:
               $csa->get_mappging_path($chr_cs, $cln_cs);

	       Either of the following mapping paths would be valid:
               [$chr_cs, $contig_cs, $clone_cs]
               or
               [$clone_cs, $contig_cs, $chr_cs]

	       Also note that the ordering of the above is not
               assembled to component but rather
               assembled -> component -> assembled.

               If no mapping path exists, an reference to an empty list is
               returned.

  Returntype : listref of coord_sytem ids ordered from assembled to smaller
               component coord_systems
  Exceptions : none
  Caller     : general

=cut

sub get_mapping_path {
  my $self = shift;
  my $cs1 = shift;
  my $cs2 = shift;
  my $seen = shift || {};

  $self->{'_shortest_path'} ||= {};

  if(!ref($cs1) || !$cs1->isa('Bio::EnsEMBL::CoordSystem')) {
    throw("CoordSystem argument expected.");
  }
  if(!ref($cs2) || !$cs2->isa('Bio::EnsEMBL::CoordSystem')) {
    throw("CoordSystem argument expected.");
  }

  my $cs1_id = $cs1->dbID();
  my $cs2_id = $cs2->dbID();

  # if this method has already been called with the same arguments
  # return the cached result
  if($self->{'_shortest_path'}->{"$cs1_id:$cs2_id"}) {
    return $self->{'_shortest_path'}->{"$cs1_id:$cs2_id"};
  }

  #if we have already seen this pair then there is some circular logic
  #encoded in the mappings.  This is not good.
  if($seen->{"$cs1_id:$cs2_id"}) {
    throw("Circular logic detected in defined assembly mappings");
  }

  #if there is a direct mapping between this coord system and other one
  #then path between cannot be shorter, just return the one step path
  if($self->{'_mapping_paths'}->{$cs1_id}->{$cs2_id}) {
    $self->{'_shortest_path'}->{"$cs1_id:$cs2_id"} = [$cs1,$cs2];
    $self->{'_shortest_path'}->{"$cs2_id:$cs1_id"} = [$cs1,$cs2];
    return [$cs1,$cs2];
  }
  if($self->{'_mapping_paths'}->{$cs2_id}->{$cs1_id}) {
    $self->{'_shortest_path'}->{"$cs1_id:$cs2_id"} = [$cs2,$cs1];
    $self->{'_shortest_path'}->{"$cs2_id:$cs1_id"} = [$cs2,$cs1];
    return [$cs2,$cs1];
  }

  $seen->{"$cs1_id:$cs2_id"} = 1;
  $seen->{"$cs2_id:$cs1_id"} = 1;

  # There is no direct mapping available, but there may be an indirect
  # path.  Call this method recursively on the components of both paths.
  my $shortest;

  #need to try both as assembled since we do not know which is the assembled
  #coord_system and which is the component
  foreach my $pair ([$cs1,$cs2], [$cs2,$cs1]) {
    my ($asm_cs, $target_cs) = @$pair;
    my $asm_cs_id = $asm_cs->dbID();

    foreach my $cmp_cs_id (keys %{$self->{'_mapping_paths'}->{$asm_cs_id}}) {
      my $cmp_cs = $self->fetch_by_dbID($cmp_cs_id);
      my $path = $self->get_mapping_path($cmp_cs, $target_cs, $seen);
      my $len = @$path;
      my $shortest;

      next if($len == 0);

      #Check whether the component was used as an assembled
      #or component in the next part of the path:
      if($cmp_cs_id == $path->[0]->dbID) {
        $path = [$asm_cs, @$path];
      } else {
        $path = [@$path, $asm_cs];
      }

      #shortest possible indirect, add to path so far and return
      if($len == 2) {
        $self->{'_shortest_path'}->{"$cs1_id:$cs2_id"} = $path;
        $self->{'_shortest_path'}->{"$cs2_id:$cs1_id"} = $path;
        return $path;
      } elsif(!defined($shortest) || $len+1 < @$shortest) {
        #keep track of the shortest path found so far,
        #there may yet be shorter..
        $shortest = $path;
      }
    }
    #use the shortest path found so far,
    #if no path was found continue, using the the other id as assembled
    if(defined($shortest)) {
      $self->{'_shortest_path'}->{"$cs1_id:$cs2_id"} = $shortest;
      $self->{'_shortest_path'}->{"$cs2_id:$cs1_id"} = $shortest;
      return $shortest;
    }
  }

  #did not find any possible path
  $self->{'_shortest_path'}->{"$cs1_id:$cs2_id"} = [];
  $self->{'_shortest_path'}->{"$cs2_id:$cs1_id"} = [];
  return [];
}



sub _fetch_by_attrib {
  my $self = shift;
  my $attrib = shift;
  my $version = shift;

  $version = lc($version) if($version);

  my @dbIDs = keys %{$self->{"_is_$attrib"}};

  throw("No $attrib coordinate system defined") if(!@dbIDs);

  foreach my $dbID (@dbIDs) {
    my $cs = $self->{'_dbID_cache'}->{$dbID};
    if($version) {
      return $cs if(lc($version) eq $cs->version());
    } elsif($self->{'_is_default_version'}->{$dbID}) {
      return $cs;
    }
  }

  #specifically requested attrib system was not found
  if($version) {
    throw("$attrib coord_system with version [$version] does not exist");
  }

  #coordsystem with attrib exists but no default is defined:
  my $dbID = shift @dbIDs;
  my $cs = $self->{'_dbID_cache'}->{$dbID};
  my $v = $cs->version();
  warning("No default version for $attrib coord_system exists. " .
          "Using version [$v] arbitrarily");

  return $cs;
}


sub _fetch_all_by_attrib {
  my $self = shift;
  my $attrib = shift;

  my @coord_systems = ();
  foreach my $dbID (keys %{$self->{"_is_$attrib"}}) {
    push @coord_systems, $self->{"_dbID_cache"}->{$dbID};
  }

  return \@coord_systems;
}


#
# Called during db destruction to clean up internal cache structures etc.
#
sub deleteObj {
  my $self = shift;

  #break circular adaptor <-> db references
  $self->SUPER::deleteObj();

  #breack circular object <-> adaptor references
  delete $self->{'_feature_cache'};
  delete $self->{'_name_cache'};
  delete $self->{'_dbID_cache'};
  delete $self->{'_mapping_paths'};
  delete $self->{'_shortest_paths'};
  delete $self->{'_top_level'};
}


=head2 store

  Arg [1]    : Bio::EnsEMBL::CoordSystem
  Example    : $csa->store($coord_system);
  Description: Stores a CoordSystem object in the database.
  Returntype : none
  Exceptions : Warning if CoordSystem is already stored in this database.
  Caller     : none

=cut

sub store {
  my $self = shift;
  my $cs = shift;

  if(!$cs || !ref($cs) || !$cs->isa('Bio::EnsEMBL::CoordSystem')) {
    throw('CoordSystem argument expected.');
  }

  my $db = $self->db();
  my $name = $cs->name();
  my $version = $cs->version();
  my $rank    = $cs->rank();

  my $seqlevel = $cs->is_sequence_level();
  my $default  = $cs->is_default();

  my $toplevel = $cs->is_top_level();

  if($toplevel) {
    throw("The toplevel CoordSystem cannot be stored");
  }

  #
  # Do lots of sanity checking to prevent bad data from being entered
  #

  if($cs->is_stored($db)) {
    warning("CoordSystem $name $version is already in db.\n");
    return;
  }

  if($name eq 'toplevel' || $name eq 'seqlevel' || !$name) {
    throw("[$name] is not a valid name for a CoordSystem.");
  }

  if($seqlevel && keys(%{$self->{'_is_sequence_level'}})) {
    throw("There can only be one sequence level CoordSystem.");
  }

  if(exists $self->{'_name_cache'}->{lc($name)}) {
    my @coord_systems = @{$self->{'_name_cache'}->{lc($name)}};
    foreach my $c (@coord_systems) {
      if(lc($c->version()) eq lc($version)) {
        warning("CoordSystem $name $version is already in db.\n");
        return;
      }
      if($default && $self->{'_is_default_version'}->{$c->dbID()}) {
        throw("There can only be one default version of CoordSystem $name");
      }
    }
  }

  if($rank !~ /^\d+$/) {
    throw("Rank attribute must be a positive integer not [$rank]");
  }
  if($rank == 0) {
    throw("Only toplevel CoordSystem may have rank of 0.");
  }

  if(defined($self->{'_rank_cache'}->{$rank})) {
    throw("CoordSystem with rank [$rank] already exists.");
  }

  my @attrib;

  push @attrib, 'default_version' if($default);
  push @attrib, 'sequence_level' if($seqlevel);

  my $attrib_str = (@attrib) ? join(',', @attrib) : undef;

  #
  # store the coordinate system in the database
  #

  my $sth = $db->prepare('INSERT INTO coord_system ' .
                         'SET name    = ?, ' .
                             'version = ?, ' .
                             'attrib  = ?,' .
                             'rank    = ?');

  $sth->execute($name, $version, $attrib_str, $rank);
  my $dbID = $sth->{'mysql_insertid'};
  $sth->finish();

  if(!$dbID) {
    throw("Did not get dbID from store of CoordSystem.");
  }

  $cs->dbID($dbID);
  $cs->adaptor($self);

  #
  # update the internal caches that are used for fetching
  #
  $self->{'_is_default_version'}->{$dbID} = 1 if($default);
  $self->{'_is_sequence_level'}->{$dbID} = 1 if($seqlevel);

  $self->{'_name_cache'}->{lc($name)} ||= [];
  push @{$self->{'_name_cache'}->{lc($name)}}, $cs;

  $self->{'_dbID_cache'}->{$dbID} = $cs;
  $self->{'_rank_cache'}->{$rank} = $cs;

  return $cs;
}




1;




