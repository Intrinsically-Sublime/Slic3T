package Slic3T::Polyline;
use strict;
use warnings;

use Math::Clipper qw();
use Slic3T::Geometry qw(A B polyline_remove_parallel_continuous_edges polyline_remove_acute_vertices
    move_points same_point);

# the constructor accepts an array(ref) of points
sub new {
    my $class = shift;
    my $self;
    if (@_ == 1) {
        $self = [ @{$_[0]} ];
    } else {
        $self = [ @_ ];
    }
    
    bless $self, $class;
    bless $_, 'Slic3T::Point' for @$self;
    $self;
}

sub id {
    my $self = shift;
    return join ' - ', sort map $_->id, @$self;
}

sub lines {
    my $self = shift;
    my @lines = ();
    my $previous_point;
    foreach my $point (@$self) {
        if ($previous_point) {
            push @lines, Slic3T::Line->new($previous_point, $point);
        }
        $previous_point = $point;
    }
    return @lines;
}

sub boost_linestring {
    my $self = shift;
    return Boost::Geometry::Utils::linestring($self);
}

sub merge_continuous_lines {
    my $self = shift;
    
    polyline_remove_parallel_continuous_edges($self);
    bless $_, 'Slic3T::Point' for @$self;
}

sub remove_acute_vertices {
    my $self = shift;
    polyline_remove_acute_vertices($self);
    bless $_, 'Slic3T::Point' for @$self;
}

sub simplify {
    my $self = shift;
    my $tolerance = shift || 10;
    
    @$self = @{ Slic3T::Geometry::douglas_peucker($self, $tolerance) };
    bless $_, 'Slic3T::Point' for @$self;
}

sub reverse {
    my $self = shift;
    @$self = CORE::reverse @$self;
}

sub nearest_point_to {
    my $self = shift;
    my ($point) = @_;
    
    $point = Slic3T::Geometry::nearest_point($point, $self);
    return Slic3T::Point->new($point);
}

sub has_segment {
    my $self = shift;
    my ($line) = @_;
    
    for ($self->lines) {
        return 1 if $_->has_segment($line);
    }
    return 0;
}

sub clip_with_polygon {
    my $self = shift;
    my ($polygon) = @_;
    
    return $self->clip_with_expolygon(Slic3T::ExPolygon->new($polygon));
}

sub clip_with_expolygon {
    my $self = shift;
    my ($expolygon) = @_;
    
    my $result = Boost::Geometry::Utils::polygon_linestring_intersection(
        $expolygon->boost_polygon,
        $self->boost_linestring,
    );
    bless $_, 'Slic3T::Polyline' for @$result;
    bless $_, 'Slic3T::Point' for map @$_, @$result;
    return @$result;
}

sub bounding_box {
    my $self = shift;
    return Slic3T::Geometry::bounding_box($self);
}

sub rotate {
    my $self = shift;
    my ($angle, $center) = @_;
    @$self = Slic3T::Geometry::rotate_points($angle, $center, @$self);
}

sub translate {
    my $self = shift;
    my ($x, $y) = @_;
    @$self = Slic3T::Geometry::move_points([$x, $y], @$self);
}

1;
