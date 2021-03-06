package Slic3T::Fill::PlanePath;
use Moo;

extends 'Slic3T::Fill::Base';

use Slic3T::Geometry qw(scale bounding_box X1 Y1 X2 Y2);

sub multiplier () { 1 }

sub get_n {
    my $self = shift;
    my ($path, $bounding_box) = @_;
    
    my ($n_lo, $n_hi) = $path->rect_to_n_range(@$bounding_box);
    return ($n_lo .. $n_hi);
}

sub process_polyline {}

sub fill_surface {
    my $self = shift;
    my ($surface, %params) = @_;
    
    # rotate polygons
    my $expolygon = $surface->expolygon->clone;
    my $rotate_vector = $self->infill_direction($surface);
    $self->rotate_points($expolygon, $rotate_vector);
    
    my $distance_between_lines = scale $params{flow_spacing} / $params{density} * $self->multiplier;
    my $bounding_box = [ bounding_box(map @$_, $expolygon) ];
    my $bounding_box_polygon = Slic3T::Polygon->new([
        [ $bounding_box->[X1], $bounding_box->[Y1] ],
        [ $bounding_box->[X2], $bounding_box->[Y1] ],
        [ $bounding_box->[X2], $bounding_box->[Y2] ],
        [ $bounding_box->[X1], $bounding_box->[Y2] ],
    ]);
    
    (ref $self) =~ /::([^:]+)$/;
    my $path = "Math::PlanePath::$1"->new;
    my @n = $self->get_n($path, [map +($_ / $distance_between_lines), @$bounding_box]);
    
    my $polyline = Slic3T::Polyline->new([
        map [ map {$_*$distance_between_lines} $path->n_to_xy($_) ], @n,
    ]);
    return {} if !@$polyline;
    
    $self->process_polyline($polyline, $bounding_box);
    
    my @paths = map $_->clip_with_expolygon($expolygon),
        $polyline->clip_with_polygon($bounding_box_polygon);
    
    if (0) {
        require "Slic3T/SVG.pm";
        Slic3T::SVG::output(undef, "fill.svg",
            polygons => $expolygon,
            polylines => [map $_->p, @paths],
        );
    }
    
    # paths must be rotated back
    $self->rotate_points_back(\@paths, $rotate_vector);
    
    return {}, @paths;
}

1;
