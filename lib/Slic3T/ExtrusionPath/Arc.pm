package Slic3T::ExtrusionPath::Arc;
use Moo;

extends 'Slic3T::ExtrusionPath';

has 'center' => (is => 'ro', required => 1);
has 'radius' => (is => 'ro', required => 1);
has 'orientation' => (is => 'ro', required => 1);  # cw/ccw

use Slic3T::Geometry qw(PI angle3points);

sub angle {
    my $self = shift;
    return angle3points($self->center, @{$self->points});
}

sub length {
    my $self = shift;
    
    if($self->orientation eq 'ccw') {
        return $self->radius * $self->angle;
    } else {
        return $self->radius * (2*PI() - $self->angle);
    }
}

1;
