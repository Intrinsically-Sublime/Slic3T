#!/usr/bin/perl
# This script reads a file and outputs information about it

use strict;
use warnings;

BEGIN {
    use FindBin;
    use lib "$FindBin::Bin/../lib";
}

use File::Basename qw(basename);
use Getopt::Long qw(:config no_auto_abbrev);
use Slic3T;
$|++;

my %opt = ();
{
    my %options = (
        'help'                  => sub { usage() },
    );
    GetOptions(%options) or usage(1);
    $ARGV[0] or usage(1);
}

{
    my $input_file = $ARGV[0];
    my $mesh;
    $mesh = Slic3T::Format::STL->read_file($input_file) if $input_file =~ /\.stl$/i;
    die "This script doesn't support AMF yet\n" if $input_file =~ /\.amf$/i;
    die "Unable to read file\n" if !$mesh;
    
    printf "Info about %s:\n", basename($input_file);
    $mesh->check_manifoldness;
    printf "  number of facets: %d\n", scalar @{$mesh->facets};
    printf "  size: x=%s y=%s z=%s\n", $mesh->size;
}


sub usage {
    my ($exit_code) = @_;
    
    print <<"EOF";
Usage: file_info.pl [ OPTIONS ] file.stl

    --help              Output this usage screen and exit
    
EOF
    exit ($exit_code || 0);
}

__END__
