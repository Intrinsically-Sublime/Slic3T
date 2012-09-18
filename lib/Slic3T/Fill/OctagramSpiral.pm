package Slic3T::Fill::OctagramSpiral;
use Moo;

extends 'Slic3T::Fill::PlanePath';
use Math::PlanePath::OctagramSpiral;

sub multiplier () { sqrt(2) }

1;
