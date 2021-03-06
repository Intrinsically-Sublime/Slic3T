package Slic3T::ExtrusionLoop;
use Moo;


# the underlying Slic3T::Polygon objects holds the geometry
has 'polygon' => (
    is          => 'ro',
    required    => 1,
    handles     => [qw(is_printable nearest_point_to)],
);

# perimeter/fill/solid-fill/bridge/skirt
has 'role'         => (is => 'rw', required => 1);

sub BUILD {
    my $self = shift;
    bless $self->polygon, 'Slic3T::Polygon';
}

sub split_at {
    my $self = shift;
    my ($point) = @_;
    
    $point = Slic3T::Point->new($point);
    
    # find index of point
    my $i = -1;
    for (my $n = 0; $n <= $#{$self->polygon}; $n++) {
        if ($point->id eq $self->polygon->[$n]->id) {
            $i = $n;
            last;
        }
    }
    die "Point not found" if $i == -1;
    
    my @new_points = ();
    push @new_points, @{$self->polygon}[$i .. $#{$self->polygon}];
    push @new_points, @{$self->polygon}[0 .. $i];
    
    return Slic3T::ExtrusionPath->new(
        polyline    => Slic3T::Polyline->new(\@new_points),
        role        => $self->role,
    );
}

sub split_at_first_point {
    my $self = shift;
    return $self->split_at($self->polygon->[0]);
}

1;
