package Slic3T::Print;
use Moo;

use Config;
use Math::ConvexHull 1.0.4 qw(convex_hull);
use Slic3T::Geometry qw(X Y Z PI MIN MAX scale unscale move_points);
use Slic3T::Geometry::Clipper qw(explode_expolygons safety_offset diff_ex intersection_ex
    union_ex offset JT_ROUND JT_MITER);

has 'x_length'          => (is => 'ro', required => 1);
has 'y_length'          => (is => 'ro', required => 1);
has 'total_x_length'    => (is => 'rw'); # including duplicates
has 'total_y_length'    => (is => 'rw'); # including duplicates
has 'copies'            => (is => 'rw', default => sub {[]});

has 'layers' => (
    traits  => ['Array'],
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3T::Layer]',
    default => sub { [] },
);

has 'total_extrusion_length' => (is => 'rw');

sub new_from_mesh {
    my $class = shift;
    my ($mesh) = @_;
    
    $mesh->rotate($Slic3T::rotate);
    $mesh->scale($Slic3T::scale / $Slic3T::scaling_factor);
    $mesh->align_to_origin;
    
    # initialize print job
    my @size = $mesh->size;
    my $print = $class->new(
        x_length => $size[X],
        y_length => $size[Y],
    );
    
    # process facets
    {
        my $apply_lines = sub {
            my $lines = shift;
            foreach my $layer_id (keys %$lines) {
                my $layer = $print->layer($layer_id);
                $layer->add_line($_) for @{ $lines->{$layer_id} };
            }
        };
        Slic3T::parallelize(
            disable => ($#{$mesh->facets} < 500),  # don't parallelize when too few facets
            items => [ 0..$#{$mesh->facets} ],
            thread_cb => sub {
                my $q = shift;
                my $result_lines = {};
                while (defined (my $facet_id = $q->dequeue)) {
                    my $lines = $mesh->slice_facet($print, $facet_id);
                    foreach my $layer_id (keys %$lines) {
                        $result_lines->{$layer_id} ||= [];
                        push @{ $result_lines->{$layer_id} }, @{ $lines->{$layer_id} };
                    }
                }
                return $result_lines;
            },
            collect_cb => sub {
                $apply_lines->($_[0]);
            },
            no_threads_cb => sub {
                for (0..$#{$mesh->facets}) {
                    my $lines = $mesh->slice_facet($print, $_);
                    $apply_lines->($lines);
                }
            },
        );
    }
    die "Invalid input file\n" if !@{$print->layers};
    
    # remove last layer if empty
    # (we might have created it because of the $max_layer = ... + 1 code below)
    pop @{$print->layers} if !@{$print->layers->[-1]->surfaces} && !@{$print->layers->[-1]->lines};
    
    foreach my $layer (@{ $print->layers }) {
        Slic3T::debugf "Making surfaces for layer %d (slice z = %f):\n",
            $layer->id, unscale $layer->slice_z if $Slic3T::debug;
        
        # layer currently has many lines representing intersections of
        # model facets with the layer plane. there may also be lines
        # that we need to ignore (for example, when two non-horizontal
        # facets share a common edge on our plane, we get a single line;
        # however that line has no meaning for our layer as it's enclosed
        # inside a closed polyline)
        
        # build surfaces from sparse lines
        $layer->make_surfaces($mesh->make_loops($layer));
        
        # free memory
        $layer->lines(undef);
    }
    
    # detect slicing errors
    my $warning_thrown = 0;
    for (my $i = 0; $i <= $#{$print->layers}; $i++) {
        my $layer = $print->layers->[$i];
        next unless $layer->slicing_errors;
        if (!$warning_thrown) {
            warn "The model has overlapping or self-intersecting facets. I tried to repair it, "
                . "however you might want to check the results or repair the input file and retry.\n";
            $warning_thrown = 1;
        }
        
        # try to repair the layer surfaces by merging all contours and all holes from
        # neighbor layers
        Slic3T::debugf "Attempting to repair layer %d\n", $i;
        
        my (@upper_surfaces, @lower_surfaces);
        for (my $j = $i+1; $j <= $#{$print->layers}; $j++) {
            if (!$print->layers->[$j]->slicing_errors) {
                @upper_surfaces = @{$print->layers->[$j]->slices};
                last;
            }
        }
        for (my $j = $i-1; $j >= 0; $j--) {
            if (!$print->layers->[$j]->slicing_errors) {
                @lower_surfaces = @{$print->layers->[$j]->slices};
                last;
            }
        }
        
        my $union = union_ex([
            map $_->expolygon->contour, @upper_surfaces, @lower_surfaces,
        ]);
        my $diff = diff_ex(
            [ map @$_, @$union ],
            [ map $_->expolygon->holes, @upper_surfaces, @lower_surfaces, ],
        );
        
        @{$layer->slices} = map Slic3T::Surface->new
            (expolygon => $_, surface_type => 'internal'),
            @$diff;
    }
    
    # remove empty layers from bottom
    while (@{$print->layers} && !@{$print->layers->[0]->slices} && !@{$print->layers->[0]->thin_walls}) {
        shift @{$print->layers};
        for (my $i = 0; $i <= $#{$print->layers}; $i++) {
            $print->layers->[$i]->id($i);
        }
    }
    
    warn "No layers were detected. You might want to repair your STL file and retry.\n"
        if !@{$print->layers};
    
    return $print;
}

sub BUILD {
    my $self = shift;
    
    my $dist = scale $Slic3T::duplicate_distance;

    if ($Slic3T::duplicate_grid->[X] > 1 || $Slic3T::duplicate_grid->[Y] > 1) {
        $self->total_x_length($self->x_length * $Slic3T::duplicate_grid->[X] + $dist * ($Slic3T::duplicate_grid->[X] - 1));
        $self->total_y_length($self->y_length * $Slic3T::duplicate_grid->[Y] + $dist * ($Slic3T::duplicate_grid->[Y] - 1));
        
        # generate offsets for copies
        for my $x_copy (1..$Slic3T::duplicate_grid->[X]) {
            for my $y_copy (1..$Slic3T::duplicate_grid->[Y]) {
                push @{$self->copies}, [
                    ($self->x_length + $dist) * ($x_copy-1),
                    ($self->y_length + $dist) * ($y_copy-1),
                ];
            }
        }
    } elsif ($Slic3T::duplicate > 1) {
        my $linint = sub {
            my ($value, $oldmin, $oldmax, $newmin, $newmax) = @_;
            return ($value - $oldmin) * ($newmax - $newmin) / ($oldmax - $oldmin) + $newmin;
        };

        # use actual part size plus separation distance (half on each side) in spacing algorithm
        my $partx = unscale($self->x_length) + $Slic3T::duplicate_distance;
        my $party = unscale($self->y_length) + $Slic3T::duplicate_distance;

        # margin needed for the skirt
        my $skirt_margin;		
        if ($Slic3T::skirts > 0) {
            $skirt_margin = ($Slic3T::flow_spacing * $Slic3T::skirts + $Slic3T::skirt_distance) * 2;
        } else {
            $skirt_margin = 0;		
        }

        # this is how many cells we have available into which to put parts
        my $cellw = int(($Slic3T::bed_size->[X] - $skirt_margin + $Slic3T::duplicate_distance) / $partx);
        my $cellh = int(($Slic3T::bed_size->[Y] - $skirt_margin + $Slic3T::duplicate_distance) / $party);

        die "$Slic3T::duplicate parts won't fit in your print area!\n" if $Slic3T::duplicate > ($cellw * $cellh);

        # width and height of space used by cells
        my $w = $cellw * $partx;
        my $h = $cellh * $party;

        # left and right border positions of space used by cells
        my $l = ($Slic3T::bed_size->[X] - $w) / 2;
        my $r = $l + $w;

        # top and bottom border positions
        my $t = ($Slic3T::bed_size->[Y] - $h) / 2;
        my $b = $t + $h;

        # list of cells, sorted by distance from center
        my @cellsorder;

        # work out distance for all cells, sort into list
        for my $i (0..$cellw-1) {
            for my $j (0..$cellh-1) {
                my $cx = $linint->($i + 0.5, 0, $cellw, $l, $r);
                my $cy = $linint->($j + 0.5, 0, $cellh, $t, $b);

                my $xd = abs(($Slic3T::bed_size->[X] / 2) - $cx);
                my $yd = abs(($Slic3T::bed_size->[Y] / 2) - $cy);

                my $c = {
                    location => [$cx, $cy],
                    index => [$i, $j],
                    distance => $xd * $xd + $yd * $yd - abs(($cellw / 2) - ($i + 0.5)),
                };

                BINARYINSERTIONSORT: {
                    my $index = $c->{distance};
                    my $low = 0;
                    my $high = @cellsorder;
                    while ($low < $high) {
                        my $mid = ($low + (($high - $low) / 2)) | 0;
                        my $midval = $cellsorder[$mid]->[0];
        
                        if ($midval < $index) {
                            $low = $mid + 1;
                        } elsif ($midval > $index) {
                            $high = $mid;
                        } else {
                            splice @cellsorder, $mid, 0, [$index, $c];
                            last BINARYINSERTIONSORT;
                        }
                    }
                    splice @cellsorder, $low, 0, [$index, $c];
                }
            }
        }

        # the extents of cells actually used by objects
        my ($lx, $ty, $rx, $by) = (0, 0, 0, 0);

        # now find cells actually used by objects, map out the extents so we can position correctly
        for my $i (1..$Slic3T::duplicate) {
            my $c = $cellsorder[$i - 1];
            my $cx = $c->[1]->{index}->[0];
            my $cy = $c->[1]->{index}->[1];
            if ($i == 1) {
                $lx = $rx = $cx;
                $ty = $by = $cy;
            } else {
                $rx = $cx if $cx > $rx;
                $lx = $cx if $cx < $lx;
                $by = $cy if $cy > $by;
                $ty = $cy if $cy < $ty;
            }
        }
        # now we actually place objects into cells, positioned such that the left and bottom borders are at 0
        for my $i (1..$Slic3T::duplicate) {
            my $c = shift @cellsorder;
            my $cx = $c->[1]->{index}->[0] - $lx;
            my $cy = $c->[1]->{index}->[1] - $ty;

            push @{$self->copies}, [scale($cx * $partx), scale($cy * $party)];
        }

        # save size of area used
        $self->total_x_length(scale(($rx - $lx + 1) * $partx - $Slic3T::duplicate_distance));
        $self->total_y_length(scale(($by - $ty + 1) * $party - $Slic3T::duplicate_distance));
    } else {
        $self->total_x_length($self->x_length);
        $self->total_y_length($self->y_length);
        push @{$self->copies}, [0, 0];
    }
}

sub layer_count {
    my $self = shift;
    return scalar @{ $self->layers };
}

sub max_length {
    my $self = shift;
    return ($self->x_length > $self->y_length) ? $self->x_length : $self->y_length;
}

sub layer {
    my $self = shift;
    my ($layer_id) = @_;
    
    # extend our print by creating all necessary layers
    
    if ($self->layer_count < $layer_id + 1) {
        for (my $i = $self->layer_count; $i <= $layer_id; $i++) {
            push @{ $self->layers }, Slic3T::Layer->new(id => $i);
        }
    }
    
    return $self->layers->[$layer_id];
}

sub detect_surfaces_type {
    my $self = shift;
    Slic3T::debugf "Detecting solid surfaces...\n";
    
    # prepare a reusable subroutine to make surface differences
    my $surface_difference = sub {
        my ($subject_surfaces, $clip_surfaces, $result_type) = @_;
        my $expolygons = diff_ex(
            [ map { ref $_ eq 'ARRAY' ? $_ : ref $_ eq 'Slic3T::ExPolygon' ? @$_ : $_->p } @$subject_surfaces ],
            [ map { ref $_ eq 'ARRAY' ? $_ : ref $_ eq 'Slic3T::ExPolygon' ? @$_ : $_->p } @$clip_surfaces ],
            1,
        );
        return grep $_->contour->is_printable,
            map Slic3T::Surface->new(expolygon => $_, surface_type => $result_type), 
            @$expolygons;
    };
    
    for (my $i = 0; $i < $self->layer_count; $i++) {
        my $layer = $self->layers->[$i];
        my $upper_layer = $self->layers->[$i+1];
        my $lower_layer = $i > 0 ? $self->layers->[$i-1] : undef;
        
        my (@bottom, @top, @internal) = ();
        
        # find top surfaces (difference between current surfaces
        # of current layer and upper one)
        if ($upper_layer) {
            @top = $surface_difference->($layer->slices, $upper_layer->slices, 'top');
        } else {
            # if no upper layer, all surfaces of this one are solid
            @top = @{$layer->slices};
            $_->surface_type('top') for @top;
        }
        
        # find bottom surfaces (difference between current surfaces
        # of current layer and lower one)
        if ($lower_layer) {
            @bottom = $surface_difference->($layer->slices, $lower_layer->slices, 'bottom');
        } else {
            # if no lower layer, all surfaces of this one are solid
            @bottom = @{$layer->slices};
            $_->surface_type('bottom') for @bottom;
        }
        
        # now, if the object contained a thin membrane, we could have overlapping bottom
        # and top surfaces; let's do an intersection to discover them and consider them
        # as bottom surfaces (to allow for bridge detection)
        if (@top && @bottom) {
            my $overlapping = intersection_ex([ map $_->p, @top ], [ map $_->p, @bottom ]);
            Slic3T::debugf "  layer %d contains %d membrane(s)\n", $layer->id, scalar(@$overlapping);
            @top = $surface_difference->([@top], $overlapping, 'top');
        }
        
        # find internal surfaces (difference between top/bottom surfaces and others)
        @internal = $surface_difference->($layer->slices, [@top, @bottom], 'internal');
        
        # save surfaces to layer
        @{$layer->slices} = (@bottom, @top, @internal);
        
        Slic3T::debugf "  layer %d has %d bottom, %d top and %d internal surfaces\n",
            $layer->id, scalar(@bottom), scalar(@top), scalar(@internal);
    }
    
    # clip surfaces to the fill boundaries
    foreach my $layer (@{$self->layers}) {
        @{$layer->surfaces} = ();
        foreach my $surface (@{$layer->slices}) {
            my $intersection = intersection_ex(
                [ $surface->p ],
                [ map @$_, @{$layer->fill_boundaries} ],
            );
            push @{$layer->surfaces}, map Slic3T::Surface->new
                (expolygon => $_, surface_type => $surface->surface_type),
                @$intersection;
        }
        
        # free memory
        @{$layer->fill_boundaries} = ();
    }
    
}

sub discover_horizontal_shells {
    my $self = shift;
    
    Slic3T::debugf "==> DISCOVERING HORIZONTAL SHELLS\n";
    
    for (my $i = 0; $i < $self->layer_count; $i++) {
        my $layer = $self->layers->[$i];
        foreach my $type (qw(top bottom)) {
            # find surfaces of current type for current layer
            # and offset them to take perimeters into account
            my @surfaces = map $_->offset($Slic3T::perimeters * scale $Slic3T::flow_width),
                grep $_->surface_type eq $type, @{$layer->fill_surfaces} or next;
            my $surfaces_p = [ map $_->p, @surfaces ];
            Slic3T::debugf "Layer %d has %d surfaces of type '%s'\n",
                $i, scalar(@surfaces), $type;
            
            for (my $n = $type eq 'top' ? $i-1 : $i+1; 
                    abs($n - $i) <= $Slic3T::solid_layers-1; 
                    $type eq 'top' ? $n-- : $n++) {
                
                next if $n < 0 || $n >= $self->layer_count;
                Slic3T::debugf "  looking for neighbors on layer %d...\n", $n;
                
                my @neighbor_surfaces = @{$self->layers->[$n]->surfaces};
                my @neighbor_fill_surfaces = @{$self->layers->[$n]->fill_surfaces};
                
                # find intersection between neighbor and current layer's surfaces
                # intersections have contours and holes
                my $new_internal_solid = intersection_ex(
                    $surfaces_p,
                    [ map $_->p, grep $_->surface_type =~ /internal/, @neighbor_surfaces ],
                    undef, 1,
                );
                next if !@$new_internal_solid;
                
                # internal-solid are the union of the existing internal-solid surfaces
                # and new ones
                my $internal_solid = union_ex([
                    ( map $_->p, grep $_->surface_type eq 'internal-solid', @neighbor_fill_surfaces ),
                    ( map @$_, @$new_internal_solid ),
                ]);
                
                # subtract intersections from layer surfaces to get resulting inner surfaces
                my $internal = diff_ex(
                    [ map $_->p, grep $_->surface_type eq 'internal', @neighbor_fill_surfaces ],
                    [ map @$_, @$internal_solid ],
                );
                Slic3T::debugf "    %d internal-solid and %d internal surfaces found\n",
                    scalar(@$internal_solid), scalar(@$internal);
                
                # Note: due to floating point math we're going to get some very small
                # polygons as $internal; they will be removed by removed_small_features()
                
                # assign resulting inner surfaces to layer
                my $neighbor_fill_surfaces = $self->layers->[$n]->fill_surfaces;
                @$neighbor_fill_surfaces = ();
                push @$neighbor_fill_surfaces, Slic3T::Surface->new
                    (expolygon => $_, surface_type => 'internal')
                    for @$internal;
                
                # assign new internal-solid surfaces to layer
                push @$neighbor_fill_surfaces, Slic3T::Surface->new
                    (expolygon => $_, surface_type => 'internal-solid')
                    for @$internal_solid;
                
                # assign top and bottom surfaces to layer
                foreach my $s (Slic3T::Surface->group(grep $_->surface_type =~ /top|bottom/, @neighbor_fill_surfaces)) {
                    my $solid_surfaces = diff_ex(
                        [ map $_->p, @$s ],
                        [ map @$_, @$internal_solid, @$internal ],
                    );
                    push @$neighbor_fill_surfaces, Slic3T::Surface->new
                        (expolygon => $_, surface_type => $s->[0]->surface_type, bridge_angle => $s->[0]->bridge_angle)
                        for @$solid_surfaces;
                }
            }
        }
    }
}

sub extrude_skirt {
    my $self = shift;
    return unless $Slic3T::skirts > 0;
    
    # collect points from all layers contained in skirt height
    my $skirt_height = $Slic3T::skirt_height;
    $skirt_height = $self->layer_count if $skirt_height > $self->layer_count;
    my @layers = map $self->layer($_), 0..($skirt_height-1);
    my @points = (
        (map @$_, map @{$_->expolygon}, map @{$_->slices}, @layers),
        (map @$_, map @{$_->thin_walls}, @layers),
        (map @{$_->polyline}, map @{$_->support_fills->paths}, grep $_->support_fills, @layers),
    );
    return if @points < 3;  # at least three points required for a convex hull
    
    # duplicate points to take copies into account
    my @all_points = map move_points($_, @points), @{$self->copies};
    
    # find out convex hull
    my $convex_hull = convex_hull(\@all_points);
    
    # draw outlines from outside to inside
    my @skirts = ();
    for (my $i = $Slic3T::skirts - 1; $i >= 0; $i--) {
        my $distance = scale ($Slic3T::skirt_distance + ($Slic3T::flow_spacing * $i));
        my $outline = offset([$convex_hull], $distance, $Slic3T::scaling_factor * 100, JT_ROUND);
        push @skirts, Slic3T::ExtrusionLoop->new(
            polygon => Slic3T::Polygon->new(@{$outline->[0]}),
            role => 'skirt',
        );
    }
    
    # apply skirts to all layers
    push @{$_->skirts}, @skirts for @layers;
}

# combine fill surfaces across layers
sub infill_every_layers {
    my $self = shift;
    return unless $Slic3T::infill_every_layers > 1 && $Slic3T::fill_density > 0;
    
    # start from bottom, skip first layer
    for (my $i = 1; $i < $self->layer_count; $i++) {
        my $layer = $self->layer($i);
        
        # skip layer if no internal fill surfaces
        next if !grep $_->surface_type eq 'internal', @{$layer->fill_surfaces};
        
        # for each possible depth, look for intersections with the lower layer
        # we do this from the greater depth to the smaller
        for (my $d = $Slic3T::infill_every_layers - 1; $d >= 1; $d--) {
            next if ($i - $d) < 0;
            my $lower_layer = $self->layer($i - 1);
            
            # select surfaces of the lower layer having the depth we're looking for
            my @lower_surfaces = grep $_->depth_layers == $d && $_->surface_type eq 'internal',
                @{$lower_layer->fill_surfaces};
            next if !@lower_surfaces;
            
            # calculate intersection between our surfaces and theirs
            my $intersection = intersection_ex(
                [ map $_->p, grep $_->depth_layers <= $d, @lower_surfaces ],
                [ map $_->p, grep $_->surface_type eq 'internal', @{$layer->fill_surfaces} ],
            );
            next if !@$intersection;
            
            # new fill surfaces of the current layer are:
            # - any non-internal surface
            # - intersections found (with a $d + 1 depth)
            # - any internal surface not belonging to the intersection (with its original depth)
            {
                my @new_surfaces = ();
                push @new_surfaces, grep $_->surface_type ne 'internal', @{$layer->fill_surfaces};
                push @new_surfaces, map Slic3T::Surface->new
                    (expolygon => $_, surface_type => 'internal', depth_layers => $d + 1), @$intersection;
                
                foreach my $depth (reverse $d..$Slic3T::infill_every_layers) {
                    push @new_surfaces, map Slic3T::Surface->new
                        (expolygon => $_, surface_type => 'internal', depth_layers => $depth),
                        
                        # difference between our internal layers with depth == $depth
                        # and the intersection found
                        @{diff_ex(
                            [
                                map $_->p, grep $_->surface_type eq 'internal' && $_->depth_layers == $depth, 
                                    @{$layer->fill_surfaces},
                            ],
                            [ map @$_, @$intersection ],
                            1,
                        )};
                }
                @{$layer->fill_surfaces} = @new_surfaces;
            }
            
            # now we remove the intersections from lower layer
            {
                my @new_surfaces = ();
                push @new_surfaces, grep $_->surface_type ne 'internal', @{$lower_layer->fill_surfaces};
                foreach my $depth (1..$Slic3T::infill_every_layers) {
                    push @new_surfaces, map Slic3T::Surface->new
                        (expolygon => $_, surface_type => 'internal', depth_layers => $depth),
                        
                        # difference between internal layers with depth == $depth
                        # and the intersection found
                        @{diff_ex(
                            [
                                map $_->p, grep $_->surface_type eq 'internal' && $_->depth_layers == $depth, 
                                    @{$lower_layer->fill_surfaces},
                            ],
                            [ map @$_, @$intersection ],
                            1,
                        )};
                }
                @{$lower_layer->fill_surfaces} = @new_surfaces;
            }
        }
    }
}

sub generate_support_material {
    my $self = shift;
    
    # determine unsupported surfaces
    my %layers = ();
    my @unsupported_expolygons = ();
    {
        my (@a, @b) = ();
        for my $i (reverse 0 .. $#{$self->layers}) {
            my $layer = $self->layers->[$i];
            my @c = ();
            if (@b) {
                @c = @{diff_ex(
                    [ map @$_, @b ],
                    [ map @$_, map $_->expolygon->offset_ex(scale $Slic3T::flow_width), @{$layer->slices} ],
                )};
                $layers{$i} = [@c];
            }
            @b = @{union_ex([ map @$_, @c, @a ])};
            
            # get unsupported surfaces for current layer as all bottom slices
            # minus the bridges offsetted to cover their perimeters.
            # actually, we are marking as bridges more than we should be, so 
            # better build support material for bridges too rather than ignoring
            # those parts. a visibility check algorithm is needed.
            # @a = @{diff_ex(
            #     [ map $_->p, grep $_->surface_type eq 'bottom', @{$layer->slices} ],
            #     [ map @$_, map $_->expolygon->offset_ex(scale $Slic3T::flow_spacing * $Slic3T::perimeters),
            #         grep $_->surface_type eq 'bottom' && defined $_->bridge_angle,
            #         @{$layer->fill_surfaces} ],
            # )};
            @a = map $_->expolygon->clone, grep $_->surface_type eq 'bottom', @{$layer->slices};
            
            $_->simplify(scale $Slic3T::flow_spacing * 3) for @a;
            push @unsupported_expolygons, @a;
        }
    }
    return if !@unsupported_expolygons;
    
    # generate paths for the pattern that we're going to use
    my $support_patterns = [];
    {
        my @support_material_areas = map $_->offset_ex(scale 5),
            @{union_ex([ map @$_, @unsupported_expolygons ])};
        
        my $fill = Slic3T::Fill->new(print => $self);
        foreach my $angle (0, 90) {
            my @patterns = ();
            foreach my $expolygon (@support_material_areas) {
                my @paths = $fill->fillers->{rectilinear}->fill_surface(
                    Slic3T::Surface->new(
                        expolygon       => $expolygon,
                        bridge_angle    => $Slic3T::fill_angle + 45 + $angle,
                    ),
                    density         => 0.20,
                    flow_spacing    => $Slic3T::flow_spacing,
                );
                my $params = shift @paths;
                
                push @patterns,
                    map Slic3T::ExtrusionPath->new(
                        polyline        => Slic3T::Polyline->new(@$_),
                        role            => 'support-material',
                        depth_layers    => 1,
                        flow_spacing    => $params->{flow_spacing},
                    ), @paths;
            }
            push @$support_patterns, [@patterns];
        }
    }
    
    if (0) {
        require "Slic3T/SVG.pm";
        Slic3T::SVG::output(undef, "support.svg",
            polylines        => [ map $_->polyline, map @$_, @$support_patterns ],
        );
    }
    
    # apply the pattern to layers
    {
        my $clip_pattern = sub {
            my ($layer_id, $expolygons) = @_;
            my @paths = ();
            foreach my $expolygon (@$expolygons) {
                push @paths, map $_->clip_with_expolygon($expolygon),
                    map $_->clip_with_polygon($expolygon->bounding_box_polygon),
                    @{$support_patterns->[ $layer_id % 2 ]};
            };
            return @paths;
        };
        my %layer_paths = ();
        Slic3T::parallelize(
            items => [ keys %layers ],
            thread_cb => sub {
                my $q = shift;
                my $paths = {};
                while (defined (my $layer_id = $q->dequeue)) {
                    $paths->{$layer_id} = [ $clip_pattern->($layer_id, $layers{$layer_id}) ];
                }
                return $paths;
            },
            collect_cb => sub {
                my $paths = shift;
                $layer_paths{$_} = $paths->{$_} for keys %$paths;
            },
            no_threads_cb => sub {
                $layer_paths{$_} = [ $clip_pattern->($_, $layers{$_}) ] for keys %layers;
            },
        );
        
        foreach my $layer_id (keys %layer_paths) {
            my $layer = $self->layers->[$layer_id];
            $layer->support_fills(Slic3T::ExtrusionPath::Collection->new);
            push @{$layer->support_fills->paths}, @{$layer_paths{$layer_id}};
        }
    }
}

sub export_gcode {
    my $self = shift;
    my ($file) = @_;
    
    # open output gcode file
    open my $fh, ">", $file
        or die "Failed to open $file for writing\n";
    
    # write some information
    my @lt = localtime;
    printf $fh "; generated by Slic3T $Slic3T::VERSION on %02d-%02d-%02d at %02d:%02d:%02d\n\n",
        $lt[5] + 1900, $lt[4]+1, $lt[3], $lt[2], $lt[1], $lt[0];

    print $fh "; $_\n" foreach split /\R/, $Slic3T::notes;
    print $fh "\n" if $Slic3T::notes;
    
    for (qw(layer_height perimeters solid_layers fill_density nozzle_diameter filament_diameter
        extrusion_multiplier perimeter_speed infill_speed travel_speed scale)) {
        printf $fh "; %s = %s\n", $_, Slic3T::Config->get($_);
    }
    printf $fh "; single wall width = %.2fmm\n", $Slic3T::flow_width;
    print  $fh "\n";
    
    # write start commands to file
    printf $fh "M%s %s%d ; set bed temperature\n",
        ($Slic3T::gcode_flavor eq 'makerbot' ? '109' : '190'),
        ($Slic3T::gcode_flavor eq 'mach3' ? 'P' : 'S'), $Slic3T::first_layer_bed_temperature
            if $Slic3T::first_layer_bed_temperature && $Slic3T::start_gcode !~ /M190/i;
    printf $fh "M104 %s%d ; set temperature\n",
        ($Slic3T::gcode_flavor eq 'mach3' ? 'P' : 'S'), $Slic3T::first_layer_temperature
            if $Slic3T::first_layer_temperature;
    printf $fh "%s\n", Slic3T::Config->replace_options($Slic3T::start_gcode);
    printf $fh "M109 %s%d ; wait for temperature to be reached\n", 
        ($Slic3T::gcode_flavor eq 'mach3' ? 'P' : 'S'), $Slic3T::first_layer_temperature
            if $Slic3T::first_layer_temperature && $Slic3T::gcode_flavor ne 'makerbot'
                && $Slic3T::start_gcode !~ /M109/i;
    print  $fh "G90 ; use absolute coordinates\n";
    print  $fh "G21 ; set units to millimeters\n";
    if ($Slic3T::gcode_flavor =~ /^(?:reprap|teacup)$/) {
        printf $fh "G92 %s0 ; reset extrusion distance\n", $Slic3T::extrusion_axis if $Slic3T::extrusion_axis;
        if ($Slic3T::gcode_flavor =~ /^(?:reprap|makerbot)$/) {
            if ($Slic3T::use_relative_e_distances) {
                print $fh "M83 ; use relative distances for extrusion\n";
            } else {
                print $fh "M82 ; use absolute distances for extrusion\n";
            }
        }
    }
    
    # calculate X,Y shift to center print around specified origin
    my @shift = (
        $Slic3T::print_center->[X] - (unscale $self->total_x_length / 2),
        $Slic3T::print_center->[Y] - (unscale $self->total_y_length / 2),
    );
    
    # set up our extruder object
    my $extruder = Slic3T::Extruder->new;
    my $min_print_speed = 60 * $Slic3T::min_print_speed;
    my $dec = $extruder->dec;
    if ($Slic3T::support_material && $Slic3T::support_material_tool > 0) {
        print $fh $extruder->set_tool(0);
    }
    print $fh $extruder->set_fan(0, 1) if $Slic3T::cooling && $Slic3T::disable_fan_first_layers;
    
    # write gcode commands layer by layer
    foreach my $layer (@{ $self->layers }) {
        if ($layer->id == 1) {
            printf $fh "M104 %s%d ; set temperature\n",
                ($Slic3T::gcode_flavor eq 'mach3' ? 'P' : 'S'), $Slic3T::temperature
                if $Slic3T::temperature && $Slic3T::temperature != $Slic3T::first_layer_temperature;
            printf $fh "M140 %s%d ; set bed temperature\n",
                ($Slic3T::gcode_flavor eq 'mach3' ? 'P' : 'S'), $Slic3T::bed_temperature
                if $Slic3T::bed_temperature && $Slic3T::bed_temperature != $Slic3T::first_layer_bed_temperature;
        }
        
        # go to layer
        my $layer_gcode = $extruder->change_layer($layer);
        $extruder->elapsed_time(0);
        
        # extrude skirts
        $extruder->shift_x($shift[X]);
        $extruder->shift_y($shift[Y]);
        $layer_gcode .= $extruder->set_acceleration($Slic3T::perimeter_acceleration);
        $layer_gcode .= $extruder->extrude_loop($_, 'skirt') for @{ $layer->skirts };
        
        for (my $i = 0; $i <= $#{$self->copies}; $i++) {
            my $copy = $self->copies->[$i];
            
            # retract explicitely because changing the shift_[xy] properties below
            # won't always trigger the automatic retraction
            $layer_gcode .= $extruder->retract;
            
            $extruder->shift_x($shift[X] + unscale $copy->[X]);
            $extruder->shift_y($shift[Y] + unscale $copy->[Y]);
            
            # extrude perimeters
            $layer_gcode .= $extruder->extrude($_, 'perimeter') for @{ $layer->perimeters };
            
            # extrude fills
            $layer_gcode .= $extruder->set_acceleration($Slic3T::infill_acceleration);
            for my $fill (@{ $layer->fills }) {
                $layer_gcode .= $extruder->extrude_path($_, 'fill') 
                    for $fill->shortest_path($extruder->last_pos);
            }
            
            # extrude support material
            if ($layer->support_fills) {
                $layer_gcode .= $extruder->set_tool($Slic3T::support_material_tool)
                    if $Slic3T::support_material_tool > 0;
                $layer_gcode .= $extruder->extrude_path($_, 'support material') 
                    for $layer->support_fills->shortest_path($extruder->last_pos);
                $layer_gcode .= $extruder->set_tool(0)
                    if $Slic3T::support_material_tool > 0;
            }
        }
        last if !$layer_gcode;
        
        my $fan_speed = $Slic3T::fan_always_on ? $Slic3T::min_fan_speed : 0;
        my $speed_factor = 1;
        if ($Slic3T::cooling) {
            my $layer_time = $extruder->elapsed_time;
            Slic3T::debugf "Layer %d estimated printing time: %d seconds\n", $layer->id, $layer_time;
            if ($layer_time < $Slic3T::slowdown_below_layer_time) {
                $fan_speed = $Slic3T::max_fan_speed;
                $speed_factor = $layer_time / $Slic3T::slowdown_below_layer_time;
            } elsif ($layer_time < $Slic3T::fan_below_layer_time) {
                $fan_speed = $Slic3T::max_fan_speed - ($Slic3T::max_fan_speed - $Slic3T::min_fan_speed)
                    * ($layer_time - $Slic3T::slowdown_below_layer_time)
                    / ($Slic3T::fan_below_layer_time - $Slic3T::slowdown_below_layer_time); #/
            }
            Slic3T::debugf "  fan = %d%%, speed = %d%%\n", $fan_speed, $speed_factor * 100;
            
            if ($speed_factor < 1) {
                $layer_gcode =~ s/^(?=.*? [XY])(?=.*? E)(G1 .*?F)(\d+(?:\.\d+)?)/
                    my $new_speed = $2 * $speed_factor;
                    $1 . sprintf("%.${dec}f", $new_speed < $min_print_speed ? $min_print_speed : $new_speed)
                    /gexm;
            }
            $fan_speed = 0 if $layer->id < $Slic3T::disable_fan_first_layers;
        }
        $layer_gcode = $extruder->set_fan($fan_speed) . $layer_gcode;
        
        # bridge fan speed
        if (!$Slic3T::cooling || $Slic3T::bridge_fan_speed == 0 || $layer->id < $Slic3T::disable_fan_first_layers) {
            $layer_gcode =~ s/^;_BRIDGE_FAN_(?:START|END)\n//gm;
        } else {
            $layer_gcode =~ s/^;_BRIDGE_FAN_START\n/ $extruder->set_fan($Slic3T::bridge_fan_speed, 1) /gmex;
            $layer_gcode =~ s/^;_BRIDGE_FAN_END\n/ $extruder->set_fan($fan_speed, 1) /gmex;
        }
        
        print $fh $layer_gcode;
    }
    
    # save statistic data
    $self->total_extrusion_length($extruder->total_extrusion_length);
    
    # write end commands to file
    print $fh $extruder->retract;
    print $fh $extruder->set_fan(0);
    print $fh "M501 ; reset acceleration\n" if $Slic3T::acceleration;
    printf $fh "%s\n", Slic3T::Config->replace_options($Slic3T::end_gcode);
    
    printf $fh "; filament used = %.1fmm (%.1fcm3)\n",
        $self->total_extrusion_length, $self->total_extrusion_volume;
    
    # close our gcode file
    close $fh;
}

sub total_extrusion_volume {
    my $self = shift;
    return $self->total_extrusion_length * ($Slic3T::filament_diameter**2) * PI/4 / 1000;
}

1;
