use lib 't';
use strict;

BEGIN { $| = 1;
	use Test ;
	plan tests => 8
}

use MultiTestDB;
use Bio::EnsEMBL::Attribute;
use Bio::EnsEMBL::MiscFeature;
use Bio::EnsEMBL::MiscSet;
use TestUtils qw(debug test_getter_setter);

our $verbose = 0; #set to 1 to turn on debug printouts


#test constructor
my $mf = Bio::EnsEMBL::MiscFeature->new(-START => 10,
                                        -END   => 100);

ok($mf->start() == 10 && $mf->end() == 100);



#
# Test add_set, get_set, get_set_codes
#
my $ms1 = Bio::EnsEMBL::MiscSet->new(3, undef,
                                     '1mbcloneset',
                                     '1mb Clone Set',
                                     'This is a 1MB cloneset',
                                     1e7);

my $ms2 = Bio::EnsEMBL::MiscSet->new(4, undef,
                                     'tilepath',
                                     'Tiling Path',
                                     'NCBI33 Tiling Path',
                                     1e6);



$mf->add_MiscSet($ms1);
$mf->add_MiscSet($ms2);


my $ms3 = $mf->get_all_MiscSets($ms1->code)->[0];
my $ms4 = $mf->get_all_MiscSets($ms2->code)->[0];

ok( $ms3 == $ms1);
ok( $ms4 == $ms2);


#
# Test add_attribute, get_attribute_types, get_attribute
#

my $name1 = Bio::EnsEMBL::Attribute->new
  ( -CODE => 'name',
    -VALUE => 'test name'
  );

my $name2 = Bio::EnsEMBL::Attribute->new
  ( -CODE => 'name',
    -VALUE => 'AL4231124.1'
  );


$mf->add_Attribute( $name1 );

ok($mf->display_id eq "test name");

$mf->add_Attribute( $name2 );

my $vers1 = Bio::EnsEMBL::Attribute->new
  ( -CODE => 'version',
    -VALUE => 4
  );

$mf->add_Attribute( $vers1 );


my @attribs = @{$mf->get_all_Attributes('name')};

ok(@attribs == 2);

@attribs = grep {$_ eq $name1 || $_ eq $name2} @attribs;

ok(@attribs == 2);

@attribs = @{$mf->get_all_Attributes('version')};
ok(@attribs == 1 && $attribs[0]->value() eq '4');

@attribs = @{$mf->get_all_Attributes()};
ok( @attribs == 3 );
